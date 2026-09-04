#!/usr/bin/env bash
# InitBox configuration convergence helper.
#
# Repo-controlled post-sync/maintenance step. It applies safe runtime
# configuration corrections that cannot be fixed by copying files alone.
# It is intentionally conservative: it does not enable ISI/sniff/FMS roles,
# does not install packages, and does not run apt-get.

set -euo pipefail

ACTION="${1:-apply}"
OWNER="${OWNER:-initbox}"
LOG_DIR="${INITBOX_LOG_DIR:-/var/log/initbox}"
LOG_FILE="${INITBOX_APPLY_LOG:-${LOG_DIR}/apply-config.log}"
STATE_FILE="${INITBOX_STATE_FILE:-/etc/initbox/install-state.env}"
ROLE_FILE="${ROLE_FILE:-/etc/pi_roles.conf}"
HOTSPOT_IFACE="${HOTSPOT_IFACE:-wlan0}"
DNSMASQ_DROPIN_DIR="${DNSMASQ_DROPIN_DIR:-/etc/dnsmasq.d}"
DNSMASQ_CONF="${DNSMASQ_CONF:-${DNSMASQ_DROPIN_DIR}/initbox-hotspot.conf}"
PORTAL_TARGET_HELPER="${PORTAL_TARGET_HELPER:-/usr/local/sbin/initbox-portal-target}"
VALIDATOR="${INITBOX_VALIDATOR:-/usr/local/bin/initbox-validate.sh}"
RUN_VALIDATION="${INITBOX_APPLY_VALIDATE:-1}"
PROFILE_ID=""
HOTSPOT_IP=""
HOTSPOT_PREFIX=""
CONFIG_CHANGED="0"
HOTSPOT_RESTART_NEEDED="0"

usage() {
  cat <<'EOF_USAGE'
Usage:
  sudo initbox-apply-config.sh [apply|validate|--help]

Actions:
  apply      Apply safe repo-controlled runtime configuration convergence.
  validate   Run the InitBox validator only.

What apply does:
  - removes legacy /home/*/pi_logs directories
  - restores Pi-full hotspot dnsmasq captive DNS config if missing/drifted
  - asserts the hotspot IP on wlan0 and waits before validation
  - restarts dnsmasq/hostapd when hotspot DNS or IP state is repaired
  - keeps portal target sane when Dashboard is absent
  - removes stale bridge NetworkManager policy when no ISI/sniff role is active
  - runs initbox-validate.sh at the end, if installed

It does not enable runtime roles and does not run apt-get.
EOF_USAGE
}

log() {
  printf '[apply] %s\n' "$*"
  printf '[apply] %s\n' "$*" >>"$LOG_FILE" 2>/dev/null || true
}

warn() {
  printf '[apply] [WARN] %s\n' "$*" >&2
  printf '[apply] [WARN] %s\n' "$*" >>"$LOG_FILE" 2>/dev/null || true
}

fail() {
  printf '[apply] [ERR] %s\n' "$*" >&2
  printf '[apply] [ERR] %s\n' "$*" >>"$LOG_FILE" 2>/dev/null || true
  exit 1
}

require_root() {
  if [ "$(id -u)" -ne 0 ]; then
    fail "this command must run as root"
  fi
}

prepare_log() {
  install -d -m 0755 "$LOG_DIR"
  touch "$LOG_FILE"
  chmod 0644 "$LOG_FILE" 2>/dev/null || true
}

state_value() {
  local key="$1"
  local value=""

  if [ ! -r "$STATE_FILE" ]; then
    return 1
  fi

  value="$(sed -n "s/^${key}=//p" "$STATE_FILE" | tail -n 1 || true)"
  value="${value%\"}"
  value="${value#\"}"
  [ -n "$value" ] || return 1
  printf '%s\n' "$value"
}

load_state() {
  PROFILE_ID="$(state_value PROFILE_ID 2>/dev/null || true)"
  HOTSPOT_IP="$(state_value HOTSPOT_GATEWAY 2>/dev/null || true)"

  if [ -z "$PROFILE_ID" ]; then
    PROFILE_ID="${INITBOX_PROFILE_ID:-}"
  fi

  if [ -z "$HOTSPOT_IP" ]; then
    case "$PROFILE_ID" in
      pi-zero2w)
        HOTSPOT_IP="192.168.20.1"
        ;;
      *)
        HOTSPOT_IP="192.168.30.1"
        ;;
    esac
  fi

  HOTSPOT_PREFIX="${HOTSPOT_IP%.*}"
}

current_roles() {
  local roles=""

  if [ -r "$ROLE_FILE" ]; then
    # shellcheck disable=SC1090
    . "$ROLE_FILE" 2>/dev/null || true
    roles="${ROLES:-${roles:-}}"
    roles="${roles,,}"
  fi

  printf '%s\n' "$roles"
}

remove_legacy_logs() {
  local path=""

  for path in /home/*/pi_logs /home/pi_logs; do
    [ -e "$path" ] || continue
    log "Removing legacy log directory: $path"
    rm -rf "$path"
    CONFIG_CHANGED="1"
  done
}

write_pi_full_dnsmasq_config() {
  local tmp_file=""

  [ "$PROFILE_ID" = "pi-full" ] || return 0

  install -d -m 0755 "$DNSMASQ_DROPIN_DIR"
  tmp_file="$(mktemp)"

  cat >"$tmp_file" <<DNSMASQ_EOF
# initbox-hotspot - managed by module-hotspot.sh / initbox-apply-config.sh
# Clients need only reach the Pi (SSH + dashboard/terminal). No internet forwarding.
interface=${HOTSPOT_IFACE}
listen-address=${HOTSPOT_IP}
bind-dynamic
no-resolv
local-service

dhcp-range=${HOTSPOT_PREFIX}.10,${HOTSPOT_PREFIX}.20,24h
dhcp-option=3,${HOTSPOT_IP}
dhcp-option=6,${HOTSPOT_IP}
domain=${HOTSPOT_IFACE}

# Local dashboard/terminal hostname
address=/initbox.wlan/${HOTSPOT_IP}

# Captive portal catch-all for hotspot clients.
# local-service prevents this hotspot DNS from answering non-hotspot-side queries.
address=/#/${HOTSPOT_IP}

# Android
address=/connectivitycheck.gstatic.com/${HOTSPOT_IP}
address=/clients3.google.com/${HOTSPOT_IP}

# Apple
address=/captive.apple.com/${HOTSPOT_IP}
address=/www.apple.com/${HOTSPOT_IP}

# Windows
address=/msftconnecttest.com/${HOTSPOT_IP}
address=/www.msftconnecttest.com/${HOTSPOT_IP}
address=/msftncsi.com/${HOTSPOT_IP}
address=/www.msftncsi.com/${HOTSPOT_IP}
address=/dns.msftncsi.com/${HOTSPOT_IP}

# Firefox
address=/detectportal.firefox.com/${HOTSPOT_IP}

# Generic
address=/neverssl.com/${HOTSPOT_IP}
address=/www.neverssl.com/${HOTSPOT_IP}
DNSMASQ_EOF

  if [ ! -f "$DNSMASQ_CONF" ] || ! cmp -s "$tmp_file" "$DNSMASQ_CONF"; then
    log "Writing hotspot dnsmasq config: $DNSMASQ_CONF"
    install -m 0644 -o root -g root "$tmp_file" "$DNSMASQ_CONF"
    CONFIG_CHANGED="1"
    HOTSPOT_RESTART_NEEDED="1"
  else
    log "Hotspot dnsmasq config is already converged: $DNSMASQ_CONF"
  fi

  rm -f "$tmp_file"
}

ensure_portal_target() {
  if [ ! -x "$PORTAL_TARGET_HELPER" ]; then
    return 0
  fi

  if systemctl cat initbox-dashboard.service >/dev/null 2>&1; then
    return 0
  fi

  log "Ensuring portal target is Web Terminal because Dashboard is absent"
  "$PORTAL_TARGET_HELPER" terminal >/dev/null 2>&1 || warn "failed to set portal target to terminal"
}

remove_stale_bridge_policy_if_roles_inactive() {
  local roles=""
  local bridge_policy="/etc/NetworkManager/conf.d/99-initbox-bridge-unmanaged.conf"

  [ "$PROFILE_ID" = "pi-full" ] || return 0
  roles="$(current_roles)"

  case " $roles " in
    *" isi "*|*" sniff "*|*" wireshark "*|*" sniffer "*|*" sniffer-bridge "*)
      log "ISI/sniff role active; preserving bridge policy"
      return 0
      ;;
  esac

  if [ -f "$bridge_policy" ]; then
    log "Removing stale bridge NetworkManager policy while ISI/sniff roles are inactive"
    rm -f "$bridge_policy"
    CONFIG_CHANGED="1"
    if command -v nmcli >/dev/null 2>&1; then
      nmcli general reload >/dev/null 2>&1 || true
      nmcli device set eth0 managed yes >/dev/null 2>&1 || true
      nmcli device connect eth0 >/dev/null 2>&1 || true
    fi
  fi
}

assert_hotspot_ip() {
  local current=""

  if ! ip link show "$HOTSPOT_IFACE" >/dev/null 2>&1; then
    warn "hotspot interface is missing: $HOTSPOT_IFACE"
    return 0
  fi

  current="$(ip -4 -o addr show dev "$HOTSPOT_IFACE" 2>/dev/null | awk '{print $4}' | head -n 1 || true)"
  if [ "$current" = "${HOTSPOT_IP}/24" ]; then
    log "Hotspot IP already present on ${HOTSPOT_IFACE}: ${HOTSPOT_IP}/24"
    return 0
  fi

  log "Applying hotspot IP on ${HOTSPOT_IFACE}: ${HOTSPOT_IP}/24"
  ip link set "$HOTSPOT_IFACE" up >/dev/null 2>&1 || true
  ip addr replace "${HOTSPOT_IP}/24" dev "$HOTSPOT_IFACE" >/dev/null 2>&1 || true
  HOTSPOT_RESTART_NEEDED="1"
  CONFIG_CHANGED="1"
}

restart_hotspot_services_if_needed() {
  if [ "$HOTSPOT_RESTART_NEEDED" != "1" ]; then
    return 0
  fi

  log "Restarting hotspot DNS/AP services after convergence"
  systemctl daemon-reload >/dev/null 2>&1 || true

  if command -v dnsmasq >/dev/null 2>&1; then
    if dnsmasq --test >/dev/null 2>&1; then
      log "dnsmasq configuration test passed"
    else
      warn "dnsmasq configuration test failed"
    fi
  fi

  systemctl restart dnsmasq.service >/dev/null 2>&1 || warn "failed to restart dnsmasq.service"
  systemctl restart hostapd.service >/dev/null 2>&1 || warn "failed to restart hostapd.service"
}

wait_for_hotspot_ip() {
  local attempt=0
  local current=""

  if ! ip link show "$HOTSPOT_IFACE" >/dev/null 2>&1; then
    return 0
  fi

  while [ "$attempt" -lt 20 ]; do
    current="$(ip -4 -o addr show dev "$HOTSPOT_IFACE" 2>/dev/null | awk '{print $4}' | head -n 1 || true)"
    if [ "$current" = "${HOTSPOT_IP}/24" ]; then
      log "Confirmed ${HOTSPOT_IFACE} hotspot IP: ${HOTSPOT_IP}/24"
      return 0
    fi

    ip addr replace "${HOTSPOT_IP}/24" dev "$HOTSPOT_IFACE" >/dev/null 2>&1 || true
    attempt=$((attempt + 1))
    sleep 1
  done

  current="$(ip -4 -o addr show dev "$HOTSPOT_IFACE" 2>/dev/null | awk '{print $4}' | head -n 1 || true)"
  warn "${HOTSPOT_IFACE} did not settle on ${HOTSPOT_IP}/24 before validation; current=${current:-none}"
}

run_validator() {
  if [ "$RUN_VALIDATION" != "1" ]; then
    log "Validation skipped by INITBOX_APPLY_VALIDATE=0"
    return 0
  fi

  if [ ! -x "$VALIDATOR" ]; then
    warn "Validator is not installed: $VALIDATOR"
    return 0
  fi

  log "Running InitBox validator"
  if "$VALIDATOR"; then
    log "Validation completed without failures"
  else
    warn "Validation reported failures. See ${LOG_DIR}/validate-latest.log"
    return 1
  fi
}

apply_config() {
  log "Applying InitBox runtime convergence"
  load_state
  log "Profile: ${PROFILE_ID:-unknown}"
  log "Hotspot IP: $HOTSPOT_IP"

  remove_legacy_logs
  write_pi_full_dnsmasq_config
  ensure_portal_target
  remove_stale_bridge_policy_if_roles_inactive
  assert_hotspot_ip
  restart_hotspot_services_if_needed
  wait_for_hotspot_ip
  run_validator
}

main() {
  case "$ACTION" in
    apply)
      ;;
    validate)
      require_root
      prepare_log
      load_state
      run_validator
      exit $?
      ;;
    -h|--help|help)
      usage
      exit 0
      ;;
    *)
      usage >&2
      fail "unknown action: $ACTION"
      ;;
  esac

  require_root
  prepare_log
  apply_config
}

main "$@"
