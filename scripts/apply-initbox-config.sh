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
  - restarts dnsmasq/hostapd when hotspot DNS config is repaired
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

read_pi_model() {
  if [ -r /proc/device-tree/model ]; then
    tr -d '\000' </proc/device-tree/model 2>/dev/null || true
  fi
}

detect_profile() {
  local model=""

  PROFILE_ID="$(state_value PROFILE_ID 2>/dev/null || true)"
  HOTSPOT_IP="$(state_value HOTSPOT_GATEWAY 2>/dev/null || true)"

  if [ -n "$PROFILE_ID" ] && [ -n "$HOTSPOT_IP" ]; then
    return 0
  fi

  model="$(read_pi_model)"
  case "$model" in
    *"Raspberry Pi Zero 2 W"*|*"Raspberry Pi Zero W"*)
      PROFILE_ID="pi-zero2w"
      HOTSPOT_IP="192.168.20.1"
      ;;
    *"Raspberry Pi 3"*)
      PROFILE_ID="pi-full"
      HOTSPOT_IP="192.168.30.1"
      ;;
    *"Raspberry Pi 4"*|*"Compute Module 4"*)
      PROFILE_ID="pi-full"
      HOTSPOT_IP="192.168.40.1"
      ;;
    *"Raspberry Pi 5"*|*"Compute Module 5"*)
      PROFILE_ID="pi-full"
      HOTSPOT_IP="192.168.50.1"
      ;;
    *)
      fail "could not determine profile/hotspot IP from state or hardware"
      ;;
  esac
}

remove_legacy_logs() {
  local path=""

  for path in /home/*/pi_logs /home/pi_logs; do
    [ -e "$path" ] || continue
    log "Removing legacy log directory: $path"
    rm -rf "$path"
  done
}

prefix_from_hotspot_ip() {
  HOTSPOT_PREFIX="${HOTSPOT_IP%.*}"
  if [ "$HOTSPOT_PREFIX" = "$HOTSPOT_IP" ] || [ -z "$HOTSPOT_PREFIX" ]; then
    fail "invalid hotspot IP: $HOTSPOT_IP"
  fi
}

write_pi_full_dnsmasq_conf_if_needed() {
  local tmp_file=""
  local dhcp_range=""

  [ "$PROFILE_ID" = "pi-full" ] || return 0
  prefix_from_hotspot_ip
  dhcp_range="${HOTSPOT_PREFIX}.10,${HOTSPOT_PREFIX}.20,24h"

  tmp_file="$(mktemp)"
  cat >"$tmp_file" <<EOF_DNSMASQ
# initbox-hotspot - managed by module-hotspot.sh / initbox-apply-config.sh
# Clients need only reach the Pi (SSH + dashboard/terminal). No internet forwarding.
interface=${HOTSPOT_IFACE}
listen-address=${HOTSPOT_IP}
bind-dynamic
no-resolv
local-service

dhcp-range=${dhcp_range}
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
EOF_DNSMASQ

  install -d -m 0755 "$DNSMASQ_DROPIN_DIR"

  if [ -f "$DNSMASQ_CONF" ] && cmp -s "$tmp_file" "$DNSMASQ_CONF"; then
    rm -f "$tmp_file"
    log "Hotspot dnsmasq config already converged: $DNSMASQ_CONF"
    return 0
  fi

  log "Writing hotspot dnsmasq config: $DNSMASQ_CONF"
  install -m 0644 -o root -g root "$tmp_file" "$DNSMASQ_CONF"
  rm -f "$tmp_file"

  if command -v dnsmasq >/dev/null 2>&1; then
    dnsmasq --test >>"$LOG_FILE" 2>&1 || fail "dnsmasq config test failed after writing $DNSMASQ_CONF"
  fi

  systemctl restart dnsmasq.service >/dev/null 2>&1 || warn "failed to restart dnsmasq.service"
}

ensure_hotspot_services() {
  if systemctl cat hostapd.service >/dev/null 2>&1; then
    systemctl enable hostapd.service >/dev/null 2>&1 || true
    systemctl restart hostapd.service >/dev/null 2>&1 || warn "failed to restart hostapd.service"
  fi

  if systemctl cat dnsmasq.service >/dev/null 2>&1; then
    systemctl enable dnsmasq.service >/dev/null 2>&1 || true
    systemctl restart dnsmasq.service >/dev/null 2>&1 || warn "failed to restart dnsmasq.service"
  fi
}

portal_target_is_dashboard() {
  [ -r /etc/initbox/portal-target.env ] && grep -q '^INITBOX_PORTAL_TARGET_NAME=dashboard$' /etc/initbox/portal-target.env
}

ensure_sane_portal_target() {
  if [ ! -x "$PORTAL_TARGET_HELPER" ]; then
    warn "portal target helper not installed: $PORTAL_TARGET_HELPER"
    return 0
  fi

  if portal_target_is_dashboard && ! systemctl cat initbox-dashboard.service >/dev/null 2>&1; then
    log "Dashboard portal target selected but Dashboard is absent; switching portal to terminal"
    "$PORTAL_TARGET_HELPER" terminal >>"$LOG_FILE" 2>&1 || warn "failed to switch portal target to terminal"
  fi
}

roles_text() {
  local role_text=""
  if [ -r "$ROLE_FILE" ]; then
    # shellcheck disable=SC1090
    . "$ROLE_FILE" || true
    role_text="${ROLES:-${roles:-}}"
  fi
  printf '%s\n' "$role_text" | xargs 2>/dev/null || true
}

bridge_role_active() {
  local role=""
  for role in $(roles_text); do
    case "$role" in
      isi|sniff|wireshark|sniffer|sniffer-bridge|ethsniffer)
        return 0
        ;;
    esac
  done
  return 1
}

cleanup_inactive_bridge_policy() {
  [ "$PROFILE_ID" = "pi-full" ] || return 0

  if bridge_role_active; then
    log "ISI/sniff role active; bridge policy left unchanged"
    return 0
  fi

  if [ -f /etc/NetworkManager/conf.d/99-initbox-bridge-unmanaged.conf ]; then
    log "Removing stale bridge NetworkManager unmanaged policy while no ISI/sniff role is active"
    rm -f /etc/NetworkManager/conf.d/99-initbox-bridge-unmanaged.conf
    command -v nmcli >/dev/null 2>&1 && nmcli general reload >/dev/null 2>&1 || true
  fi

  if ip link show br0 >/dev/null 2>&1; then
    log "Removing stale br0 while no ISI/sniff role is active"
    ip link set br0 down >/dev/null 2>&1 || true
    ip link delete br0 type bridge >/dev/null 2>&1 || true
  fi
}

run_validation() {
  if [ "$RUN_VALIDATION" != "1" ]; then
    return 0
  fi

  if [ ! -x "$VALIDATOR" ]; then
    warn "validator not installed: $VALIDATOR"
    return 0
  fi

  log "Running InitBox validator"
  if "$VALIDATOR"; then
    log "Validation passed"
  else
    warn "Validation reported failures. See /var/log/initbox/validate-latest.log"
    return 1
  fi
}

apply_config() {
  require_root
  prepare_log
  detect_profile

  log "Applying InitBox runtime convergence"
  log "Profile: $PROFILE_ID"
  log "Hotspot IP: $HOTSPOT_IP"

  remove_legacy_logs
  write_pi_full_dnsmasq_conf_if_needed
  ensure_hotspot_services
  ensure_sane_portal_target
  cleanup_inactive_bridge_policy
  run_validation
}

case "$ACTION" in
  apply|--from-sync)
    apply_config
    ;;
  validate)
    require_root
    prepare_log
    run_validation
    ;;
  -h|--help|help)
    usage
    ;;
  *)
    usage >&2
    fail "unknown action: $ACTION"
    ;;
esac
