#!/usr/bin/env bash
# InitBox configuration convergence helper.
#
# Repo-controlled post-sync/maintenance step. It applies safe runtime
# configuration corrections that cannot be fixed by copying files alone.
# Default apply mode does not enable ISI/sniff/FMS roles and does not run apt-get.
# Dashboard mode intentionally invokes the Dashboard module when requested.

set -euo pipefail

ACTION="${1:-apply}"
OWNER="${OWNER:-initbox}"
LOG_DIR="${INITBOX_LOG_DIR:-/var/log/initbox}"
LOG_FILE="${INITBOX_APPLY_LOG:-${LOG_DIR}/apply-config.log}"
STATE_FILE="${INITBOX_STATE_FILE:-/etc/initbox/install-state.env}"
ROLE_FILE="${ROLE_FILE:-/etc/pi_roles.conf}"
MODS_FILE="${MODS_FILE:-/etc/initbox/dashboard-modules.env}"
DASHBOARD_REQUEST_FILE="${DASHBOARD_REQUEST_FILE:-/etc/initbox/dashboard-requested.env}"
HOTSPOT_IFACE="${HOTSPOT_IFACE:-wlan0}"
DNSMASQ_DROPIN_DIR="${DNSMASQ_DROPIN_DIR:-/etc/dnsmasq.d}"
DNSMASQ_CONF="${DNSMASQ_CONF:-${DNSMASQ_DROPIN_DIR}/initbox-hotspot.conf}"
PORTAL_TARGET_HELPER="${PORTAL_TARGET_HELPER:-/usr/local/sbin/initbox-portal-target}"
VALIDATOR="${INITBOX_VALIDATOR:-/usr/local/bin/initbox-validate.sh}"
MODULE_RUNNER="${INITBOX_MODULE_RUNNER:-/usr/local/bin/initbox-module-runner.sh}"
RUN_VALIDATION="${INITBOX_APPLY_VALIDATE:-1}"
INSTALL_DASHBOARD_REQUEST="${INITBOX_APPLY_DASHBOARD:-}"
PROFILE_ID=""
HOTSPOT_IP=""
HOTSPOT_PREFIX=""
CONFIG_CHANGED="0"
HOTSPOT_RESTART_NEEDED="0"
DASHBOARD_INSTALL_ATTEMPTED="0"

usage() {
  cat <<'EOF_USAGE'
Usage:
  sudo initbox-apply-config.sh [apply|dashboard|validate|--help]

Actions:
  apply       Apply safe repo-controlled runtime configuration convergence.
  dashboard   Apply convergence, install/repair Dashboard, and validate.
  validate    Run the InitBox validator only.

Environment:
  INITBOX_APPLY_DASHBOARD=yes   During apply, also install/repair Dashboard.

What apply does:
  - removes legacy /home/*/pi_logs directories
  - restores Pi-full hotspot dnsmasq captive DNS config if missing/drifted
  - asserts the hotspot IP on wlan0 and waits before validation
  - keeps lab Ethernet managed while ISI/sniff roles are inactive
  - restarts dnsmasq/hostapd when hotspot DNS or IP state is repaired
  - keeps portal target sane when Dashboard is absent/present
  - removes stale bridge NetworkManager policy when no ISI/sniff role is active
  - runs initbox-validate.sh at the end, if installed

It does not enable ISI/sniff/FMS roles.
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
  local line=""
  local value=""

  [ -r "$STATE_FILE" ] || return 1
  line="$(grep -m 1 "^${key}=" "$STATE_FILE" 2>/dev/null || true)"
  [ -n "$line" ] || return 1
  value="${line#*=}"
  value="${value%\"}"
  value="${value#\"}"
  printf '%s\n' "$value"
}

file_value() {
  local file_path="$1"
  local key="$2"
  local line=""
  local value=""

  [ -r "$file_path" ] || return 1
  line="$(grep -m 1 "^${key}=" "$file_path" 2>/dev/null || true)"
  [ -n "$line" ] || return 1
  value="${line#*=}"
  value="${value%\"}"
  value="${value#\"}"
  printf '%s\n' "$value"
}

read_pi_model() {
  local model=""
  if [ -r /proc/device-tree/model ]; then
    model="$(tr -d '\000' </proc/device-tree/model 2>/dev/null || true)"
  fi
  printf '%s\n' "$model"
}

detect_profile() {
  local model=""

  PROFILE_ID="$(state_value PROFILE_ID 2>/dev/null || true)"
  if [ -z "$PROFILE_ID" ]; then
    model="$(read_pi_model)"
    case "$model" in
      *"Raspberry Pi Zero 2 W"*|*"Raspberry Pi Zero W"*) PROFILE_ID="pi-zero2w" ;;
      *"Raspberry Pi 3"*|*"Raspberry Pi 4"*|*"Raspberry Pi 5"*|*"Compute Module 4"*|*"Compute Module 5"*) PROFILE_ID="pi-full" ;;
      *) fail "could not determine InitBox profile" ;;
    esac
  fi

  case "$PROFILE_ID" in
    pi-full)
      HOTSPOT_IP="$(state_value HOTSPOT_GATEWAY 2>/dev/null || true)"
      [ -n "$HOTSPOT_IP" ] || HOTSPOT_IP="192.168.30.1"
      ;;
    pi-zero2w)
      HOTSPOT_IP="$(state_value HOTSPOT_GATEWAY 2>/dev/null || true)"
      [ -n "$HOTSPOT_IP" ] || HOTSPOT_IP="192.168.20.1"
      ;;
    *) fail "unsupported InitBox profile: $PROFILE_ID" ;;
  esac

  HOTSPOT_PREFIX="${HOTSPOT_IP%.*}"
}

remove_legacy_logs() {
  local candidate=""
  for candidate in /home/*/pi_logs /home/pi_logs; do
    if [ -d "$candidate" ]; then
      log "Removing legacy log directory: $candidate"
      rm -rf "$candidate"
      CONFIG_CHANGED="1"
    fi
  done
}

write_pi_full_dnsmasq_config() {
  local tmp_file=""

  if [ "$PROFILE_ID" != "pi-full" ]; then
    return 0
  fi

  install -d -m 0755 "$DNSMASQ_DROPIN_DIR"
  tmp_file="$(mktemp "${DNSMASQ_DROPIN_DIR}/.initbox-hotspot.XXXXXX")"

  cat >"$tmp_file" <<DNSMASQ_EOF
# initbox-hotspot - managed by module-hotspot.sh / initbox-apply-config.sh
# Clients need only reach the Pi (SSH + dashboard/Web Terminal). No internet forwarding.
interface=${HOTSPOT_IFACE}
listen-address=${HOTSPOT_IP}
bind-dynamic
no-resolv
local-service

dhcp-range=${HOTSPOT_PREFIX}.10,${HOTSPOT_PREFIX}.20,24h
dhcp-option=3,${HOTSPOT_IP}
dhcp-option=6,${HOTSPOT_IP}
domain=${HOTSPOT_IFACE}

# Local dashboard/Web Terminal hostname
address=/initbox.wlan/${HOTSPOT_IP}

# Captive portal catch-all for hotspot clients.
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

  chmod 0644 "$tmp_file"
  chown root:root "$tmp_file" 2>/dev/null || true

  if [ ! -f "$DNSMASQ_CONF" ] || ! cmp -s "$tmp_file" "$DNSMASQ_CONF"; then
    log "Writing hotspot dnsmasq config: $DNSMASQ_CONF"
    mv -f "$tmp_file" "$DNSMASQ_CONF"
    CONFIG_CHANGED="1"
    HOTSPOT_RESTART_NEEDED="1"
  else
    rm -f "$tmp_file"
  fi
}

assert_hotspot_ip() {
  local current_ip=""
  local attempt=""

  if ! ip link show "$HOTSPOT_IFACE" >/dev/null 2>&1; then
    warn "Hotspot interface missing: $HOTSPOT_IFACE"
    return 0
  fi

  current_ip="$(ip -4 addr show dev "$HOTSPOT_IFACE" 2>/dev/null | awk '/inet / {print $2}' | head -n 1 || true)"
  if [ "$current_ip" != "${HOTSPOT_IP}/24" ]; then
    log "Asserting hotspot IP ${HOTSPOT_IP}/24 on ${HOTSPOT_IFACE}; current=${current_ip:-none}"
    ip link set "$HOTSPOT_IFACE" up 2>/dev/null || true
    ip addr replace "${HOTSPOT_IP}/24" dev "$HOTSPOT_IFACE" 2>/dev/null || true
    HOTSPOT_RESTART_NEEDED="1"
    CONFIG_CHANGED="1"
  fi

  for attempt in 1 2 3 4 5 6 7 8 9 10; do
    current_ip="$(ip -4 addr show dev "$HOTSPOT_IFACE" 2>/dev/null | awk '/inet / {print $2}' | head -n 1 || true)"
    if [ "$current_ip" = "${HOTSPOT_IP}/24" ]; then
      log "Hotspot IP present on ${HOTSPOT_IFACE}: ${HOTSPOT_IP}/24"
      return 0
    fi
    sleep 1
  done

  warn "Hotspot IP did not appear on ${HOTSPOT_IFACE}; current=${current_ip:-none}"
}

restart_hotspot_services_if_needed() {
  if [ "$HOTSPOT_RESTART_NEEDED" != "1" ]; then
    return 0
  fi

  if command -v dnsmasq >/dev/null 2>&1; then
    dnsmasq --test >/dev/null || fail "dnsmasq configuration test failed"
  fi

  systemctl daemon-reload >/dev/null 2>&1 || true

  if systemctl cat hostapd.service >/dev/null 2>&1; then
    log "Restarting hostapd.service after hotspot convergence"
    systemctl restart hostapd.service || warn "failed to restart hostapd.service"
  fi

  if systemctl cat dnsmasq.service >/dev/null 2>&1; then
    log "Restarting dnsmasq.service after hotspot convergence"
    systemctl restart dnsmasq.service || warn "failed to restart dnsmasq.service"
  fi

  assert_hotspot_ip
}

active_roles_text() {
  local role_text=""

  if [ -r "$ROLE_FILE" ]; then
    # shellcheck disable=SC1090
    . "$ROLE_FILE" || true
    role_text="${ROLES:-${roles:-}}"
    role_text="${role_text,,}"
  fi

  printf '%s\n' "$role_text"
}

roles_include_bridge_runtime() {
  local role_text=""

  role_text="$(active_roles_text)"
  case " $role_text " in
    *" isi "*|*" sniff "*|*" wireshark "*|*" sniffer "*|*" sniffer-bridge "*) return 0 ;;
  esac

  return 1
}

remove_stale_bridge_policy_if_safe() {
  local nm_bridge_file="/etc/NetworkManager/conf.d/99-initbox-bridge-unmanaged.conf"

  if roles_include_bridge_runtime; then
    return 0
  fi

  if [ -f "$nm_bridge_file" ]; then
    log "Removing stale bridge NetworkManager policy while ISI/sniff roles are inactive"
    rm -f "$nm_bridge_file"
    CONFIG_CHANGED="1"
  fi
}

restore_lab_uplink_if_safe() {
  if [ "$PROFILE_ID" != "pi-full" ]; then
    return 0
  fi

  if roles_include_bridge_runtime; then
    log "ISI/sniff role active; lab Ethernet restoration skipped"
    return 0
  fi

  log "Ensuring lab Ethernet remains managed while field roles are inactive"

  systemctl stop isirunall.service wireshark-autostart.service fms.service >/dev/null 2>&1 || true
  systemctl disable isirunall.service wireshark-autostart.service fms.service >/dev/null 2>&1 || true

  ip link set eth0 nomaster >/dev/null 2>&1 || true
  ip link set eth1 nomaster >/dev/null 2>&1 || true

  if ip link show br0 >/dev/null 2>&1; then
    log "Removing inactive bridge br0"
    ip link set br0 down >/dev/null 2>&1 || true
    ip link delete br0 type bridge >/dev/null 2>&1 || true
    CONFIG_CHANGED="1"
  fi

  if command -v nmcli >/dev/null 2>&1; then
    nmcli general reload >/dev/null 2>&1 || true
    nmcli device set eth0 managed yes >/dev/null 2>&1 || true
    if ! ip route show default 2>/dev/null | grep -q '^default '; then
      log "No default route detected; asking NetworkManager to reconnect eth0"
      nmcli device connect eth0 >/dev/null 2>&1 || true
      sleep 3
    fi
  fi
}

dashboard_flag_is_enabled() {
  [ -r "$MODS_FILE" ] && grep -Eq '^DASHBOARD=1$' "$MODS_FILE" 2>/dev/null
}

dashboard_service_is_active() {
  systemctl is-active --quiet initbox-dashboard.service 2>/dev/null
}

dashboard_requested() {
  case "$ACTION" in
    dashboard|install-dashboard|enable-dashboard) return 0 ;;
  esac

  case "$INSTALL_DASHBOARD_REQUEST" in
    1|yes|YES|true|TRUE|dashboard) return 0 ;;
  esac

  if [ "$(file_value "$DASHBOARD_REQUEST_FILE" DASHBOARD_REQUESTED 2>/dev/null || true)" = "yes" ]; then
    return 0
  fi

  if [ "$(state_value DASHBOARD_SELECTED 2>/dev/null || true)" = "yes" ]; then
    return 0
  fi

  return 1
}

record_dashboard_request() {
  local requested="$1"
  local source="${2:-apply-config}"

  install -d -m 0755 "$(dirname "$DASHBOARD_REQUEST_FILE")"
  cat >"$DASHBOARD_REQUEST_FILE" <<EOF_REQUEST
# InitBox dashboard request. Managed by install-initbox.sh / initbox-apply-config.sh.
DASHBOARD_REQUESTED="${requested}"
DASHBOARD_REQUEST_SOURCE="${source}"
DASHBOARD_REQUEST_RECORDED_AT="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
EOF_REQUEST
  chmod 0644 "$DASHBOARD_REQUEST_FILE"
  chown root:root "$DASHBOARD_REQUEST_FILE" 2>/dev/null || true
}

install_dashboard_if_requested() {
  if ! dashboard_requested; then
    return 0
  fi

  if [ "$PROFILE_ID" != "pi-full" ]; then
    warn "Dashboard request ignored because profile is not pi-full: $PROFILE_ID"
    return 0
  fi

  record_dashboard_request yes "apply-config"

  if dashboard_service_is_active && dashboard_flag_is_enabled; then
    log "Dashboard already active"
    return 0
  fi

  if [ ! -x "$MODULE_RUNNER" ]; then
    fail "module runner is missing: $MODULE_RUNNER"
  fi

  log "Installing/repairing Dashboard through module runner"
  DASHBOARD_INSTALL_ATTEMPTED="1"
  INITBOX_LOG_DIR="$LOG_DIR" LOGFILE="${LOG_DIR}/module-dashboard.log" "$MODULE_RUNNER" install dashboard
}

ensure_portal_target() {
  if [ ! -x "$PORTAL_TARGET_HELPER" ]; then
    return 0
  fi

  if dashboard_service_is_active && dashboard_flag_is_enabled; then
    log "Setting portal target to Dashboard"
    "$PORTAL_TARGET_HELPER" dashboard >/dev/null || warn "failed to set portal target to dashboard"
  else
    log "Setting portal target to Web Terminal"
    "$PORTAL_TARGET_HELPER" terminal >/dev/null || warn "failed to set portal target to terminal"
  fi
}

run_validator() {
  if [ "$RUN_VALIDATION" != "1" ]; then
    return 0
  fi

  if [ ! -x "$VALIDATOR" ]; then
    warn "Validator is not installed: $VALIDATOR"
    return 0
  fi

  log "Running InitBox validator"
  if "$VALIDATOR"; then
    log "Validation passed"
  else
    warn "Validation reported failures. See ${LOG_DIR}/validate-latest.log"
    return 1
  fi
}

apply_config() {
  log "Applying InitBox runtime convergence"
  log "Profile: $PROFILE_ID"
  log "Hotspot IP: $HOTSPOT_IP"

  remove_legacy_logs
  write_pi_full_dnsmasq_config
  assert_hotspot_ip
  restart_hotspot_services_if_needed
  remove_stale_bridge_policy_if_safe
  restore_lab_uplink_if_safe
  install_dashboard_if_requested
  ensure_portal_target

  if [ "$DASHBOARD_INSTALL_ATTEMPTED" = "1" ]; then
    CONFIG_CHANGED="1"
  fi

  if [ "$CONFIG_CHANGED" = "0" ]; then
    log "Runtime configuration already converged"
  fi
}

main() {
  case "$ACTION" in
    apply|dashboard|install-dashboard|enable-dashboard|validate) ;;
    -h|--help|help) usage; exit 0 ;;
    *) usage >&2; fail "unknown action: $ACTION" ;;
  esac

  require_root
  prepare_log
  detect_profile

  if [ "$ACTION" = "validate" ]; then
    run_validator
    exit $?
  fi

  apply_config
  run_validator
}

main "$@"
