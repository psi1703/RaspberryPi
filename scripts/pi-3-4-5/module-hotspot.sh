#!/usr/bin/env bash

# InitBox Raspberry Pi 3 / 4 / 5 hotspot module
#
# Installs:
#   - hostapd hotspot on wlan0
#   - dnsmasq DHCP/DNS for hotspot clients
#   - dhcpcd static wlan0 address
#   - captive-portal-friendly DNS responses
#
# Package model:
#   - Uses scripts/lib/packages.sh
#   - With Internet: installs through apt-get and keeps packages cached
#   - Without Internet: installs from local package cache only
#
# Actions:
#   install    Install/update hotspot configuration
#   uninstall  Disable/remove hotspot configuration created by this module
#   purge      Compatibility alias for uninstall; packages are not purged

set -euo pipefail

ACTION="${1:-install}"

: "${OWNER:=initbox}"
: "${HOTSPOT_PASS:=TomatoH34d}"

SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_PATH")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PACKAGES_HELPER="$REPO_ROOT/scripts/lib/packages.sh"

LOG_DIR="/home/${OWNER}/pi_logs"
LOGFILE="${LOGFILE:-${LOG_DIR}/initbox-install.log}"

BOXNO_FILE="${BOXNO_FILE:-/etc/pi-boxno}"
WLAN_IFACE="${WLAN_IFACE:-wlan0}"
COUNTRY_CODE="${COUNTRY_CODE:-AE}"
HOSTAPD_CONF="/etc/hostapd/hostapd.conf"
HOSTAPD_DEFAULT="/etc/default/hostapd"
DNSMASQ_DROPIN_DIR="/etc/dnsmasq.d"
DNSMASQ_CONF="${DNSMASQ_DROPIN_DIR}/initbox-hotspot.conf"
DHCPCD_CONF="/etc/dhcpcd.conf"

ts() {
  date +"%Y-%m-%d %H:%M:%S"
}

log() {
  echo "[HOTSPOT $(ts)] $*" | tee -a "$LOGFILE"
}

ok() {
  echo "[HOTSPOT $(ts)] [OK] $*" | tee -a "$LOGFILE"
}

warn() {
  echo "[HOTSPOT $(ts)] [WARN] $*" | tee -a "$LOGFILE" >&2
}

err() {
  echo "[HOTSPOT $(ts)] [ERR] $*" | tee -a "$LOGFILE" >&2
}

require_root() {
  if [ "$(id -u)" -ne 0 ]; then
    err "This module must be run as root."
    echo "Run with:"
    echo "  sudo ./scripts/pi-3-4-5/module-hotspot.sh ${ACTION}"
    exit 1
  fi
}

prepare_log() {
  mkdir -p "$LOG_DIR"
  touch "$LOGFILE"

  if id "$OWNER" >/dev/null 2>&1; then
    chown -R "$OWNER:$OWNER" "$LOG_DIR" || true
  fi
}

require_package_helper() {
  if [ ! -f "$PACKAGES_HELPER" ]; then
    err "Package helper not found: $PACKAGES_HELPER"
    err "Expected file: scripts/lib/packages.sh"
    exit 1
  fi

  chmod 755 "$PACKAGES_HELPER" 2>/dev/null || true
}

install_packages() {
  log "Installing hotspot dependencies through InitBox package cache helper."

  require_package_helper

  if ! bash "$PACKAGES_HELPER" install \
    dnsmasq \
    hostapd \
    dhcpcd5 \
    iproute2 \
    iptables \
    rfkill 2>&1 | tee -a "$LOGFILE"; then
    err "Hotspot dependency installation failed."
    err "If this Pi is offline, prepare the package cache first with:"
    err "  sudo ./scripts/initbox-installer.sh pi-3-4-5 p"
    exit 1
  fi
}

ask() {
  local prompt="$1"
  local default="$2"
  local reply=""

  if [ -e /dev/tty ]; then
    read -r -p "${prompt} [${default}]: " reply </dev/tty || reply=""
    printf '%s\n' "${reply:-$default}"
  elif [ -t 0 ]; then
    read -r -p "${prompt} [${default}]: " reply || reply=""
    printf '%s\n' "${reply:-$default}"
  else
    printf '%s\n' "$default"
  fi
}

calc_hotspot_subnet() {
  local model=""

  model="$(tr -d '\0' </proc/device-tree/model 2>/dev/null || echo "")"

  case "$model" in
    *"Raspberry Pi 3"*)
      echo "192.168.30"
      ;;
    *"Raspberry Pi 4"*)
      echo "192.168.40"
      ;;
    *"Raspberry Pi 5"*)
      echo "192.168.50"
      ;;
    *)
      echo "192.168.30"
      ;;
  esac
}

read_default_boxno() {
  if [ -r "$BOXNO_FILE" ]; then
    cat "$BOXNO_FILE" 2>/dev/null || echo 1
  else
    echo 1
  fi
}

validate_boxno() {
  local boxno="$1"

  case "$boxno" in
    ''|*[!0-9]*)
      return 1
      ;;
    *)
      [ "$boxno" -ge 1 ] && [ "$boxno" -le 254 ]
      ;;
  esac
}

get_boxno() {
  local default_boxno=""
  local selected_boxno=""

  default_boxno="$(read_default_boxno)"
  selected_boxno="$(ask "Enter BOX number, last octet 1-254" "$default_boxno")"

  if ! validate_boxno "$selected_boxno"; then
    warn "Invalid BOX number '${selected_boxno}', using default '${default_boxno}'."
    selected_boxno="$default_boxno"
  fi

  if ! validate_boxno "$selected_boxno"; then
    warn "Default BOX number '${selected_boxno}' is invalid, using 1."
    selected_boxno="1"
  fi

  printf '%s\n' "$selected_boxno"
}

write_hostapd_conf() {
  local ssid="$1"

  log "Writing ${HOSTAPD_CONF}."

  install -d -m 0755 /etc/hostapd

  cat >"$HOSTAPD_CONF" <<EOF
# initbox-hotspot
country_code=${COUNTRY_CODE}
interface=${WLAN_IFACE}
driver=nl80211
ssid=${ssid}
hw_mode=g
channel=7
wmm_enabled=0
macaddr_acl=0
auth_algs=1
ignore_broadcast_ssid=0
wpa=2
wpa_passphrase=${HOTSPOT_PASS}
wpa_key_mgmt=WPA-PSK
rsn_pairwise=CCMP
EOF

  chown root:root "$HOSTAPD_CONF"
  chmod 600 "$HOSTAPD_CONF"

  if [ -f "$HOSTAPD_DEFAULT" ]; then
    sed -i 's|^#\?DAEMON_CONF=.*|DAEMON_CONF="/etc/hostapd/hostapd.conf"|' "$HOSTAPD_DEFAULT" 2>/dev/null || true
  else
    printf '%s\n' 'DAEMON_CONF="/etc/hostapd/hostapd.conf"' >"$HOSTAPD_DEFAULT"
  fi
}

write_dnsmasq_conf() {
  local hotspot_ip="$1"
  local dhcp_range="$2"

  log "Writing ${DNSMASQ_CONF}."

  install -d -m 0755 "$DNSMASQ_DROPIN_DIR"

  cat >"$DNSMASQ_CONF" <<EOF
# initbox-hotspot
interface=${WLAN_IFACE}
bind-interfaces
dhcp-range=${dhcp_range}
domain=${WLAN_IFACE}

# Local dashboard name and captive portal fallback
address=/#/${hotspot_ip}

# Android captive portal checks
address=/connectivitycheck.gstatic.com/${hotspot_ip}
address=/clients3.google.com/${hotspot_ip}

# Apple captive portal checks
address=/captive.apple.com/${hotspot_ip}
address=/www.apple.com/${hotspot_ip}

# Windows captive portal checks
address=/msftconnecttest.com/${hotspot_ip}
address=/msftncsi.com/${hotspot_ip}

# Firefox captive portal checks
address=/detectportal.firefox.com/${hotspot_ip}
EOF

  chmod 644 "$DNSMASQ_CONF"
  chown root:root "$DNSMASQ_CONF" || true
}

remove_managed_dhcpcd_block() {
  local tmp_file=""

  if [ ! -f "$DHCPCD_CONF" ]; then
    return 0
  fi

  tmp_file="$(mktemp)"

  awk '
    BEGIN { skip = 0 }
    /^# START INITBOX-HOTSPOT$/ { skip = 1; next }
    /^# END INITBOX-HOTSPOT$/ { skip = 0; next }
    skip == 0 { print }
  ' "$DHCPCD_CONF" >"$tmp_file"

  install -m 0644 "$tmp_file" "$DHCPCD_CONF"
  rm -f "$tmp_file"
}

write_dhcpcd_conf() {
  local hotspot_ip="$1"

  log "Updating ${DHCPCD_CONF} with managed wlan0 block."

  touch "$DHCPCD_CONF"
  remove_managed_dhcpcd_block

  cat >>"$DHCPCD_CONF" <<EOF

# START INITBOX-HOTSPOT
interface ${WLAN_IFACE}
    static ip_address=${hotspot_ip}/24
    nohook wpa_supplicant
# END INITBOX-HOTSPOT
EOF
}

start_hotspot_stack() {
  log "Unmasking and enabling hotspot stack."

  systemctl unmask hostapd 2>/dev/null || true
  rfkill unblock wifi 2>/dev/null || rfkill unblock all 2>/dev/null || true

  systemctl daemon-reload
  systemctl enable dhcpcd dnsmasq hostapd 2>/dev/null || true

  systemctl restart dhcpcd 2>/dev/null || systemctl start dhcpcd 2>/dev/null || true
  systemctl restart dnsmasq 2>/dev/null || systemctl start dnsmasq 2>/dev/null || true
  systemctl restart hostapd 2>/dev/null || systemctl start hostapd 2>/dev/null || true
}

install_module() {
  local boxno=""
  local ssid=""
  local base_ip=""
  local hotspot_ip=""
  local dhcp_range=""

  require_root
  prepare_log

  log "Starting hotspot module installation."

  install_packages

  boxno="$(get_boxno)"
  printf '%s\n' "$boxno" >"$BOXNO_FILE"
  chmod 644 "$BOXNO_FILE"

  ssid="initbox_${boxno}"
  base_ip="$(calc_hotspot_subnet)"
  hotspot_ip="${base_ip}.${boxno}"
  dhcp_range="${base_ip}.10,${base_ip}.20,24h"

  log "Hotspot SSID=${ssid}, IP=${hotspot_ip}, range=${dhcp_range}"
  log "HOTSPOT_PASS is set but not logged."

  write_hostapd_conf "$ssid"
  write_dnsmasq_conf "$hotspot_ip" "$dhcp_range"
  write_dhcpcd_conf "$hotspot_ip"
  start_hotspot_stack

  ok "Hotspot module installed."
  ok "Connect to SSID '${ssid}'."
  ok "Dashboard captive portal target: http://initbox.wlan/"
}

uninstall_module() {
  require_root
  prepare_log

  log "Uninstalling hotspot module."

  systemctl stop hostapd 2>/dev/null || true
  systemctl disable hostapd 2>/dev/null || true

  systemctl stop dnsmasq 2>/dev/null || true
  systemctl disable dnsmasq 2>/dev/null || true

  rm -f "$DNSMASQ_CONF"
  rm -f "$HOSTAPD_CONF"

  remove_managed_dhcpcd_block

  systemctl daemon-reload

  systemctl restart dhcpcd 2>/dev/null || true

  ok "Hotspot configuration removed."
  warn "Installed packages were left in place intentionally."
  warn "BOX number file was left in place intentionally: ${BOXNO_FILE}"
}

usage() {
  cat <<EOF
Usage:
  sudo ./scripts/pi-3-4-5/module-hotspot.sh [install|uninstall|purge]

Actions:
  install    Install/update hotspot configuration
  uninstall  Disable/remove hotspot configuration created by this module
  purge      Compatibility alias for uninstall; packages are not purged

Package cache:
  This module uses:
    scripts/lib/packages.sh

  To prepare package cache in the lab:
    sudo ./scripts/initbox-installer.sh pi-3-4-5 p

Environment:
  HOTSPOT_PASS   WPA2 password. Default is set by this script.
  WLAN_IFACE     Wireless interface. Default: wlan0
  COUNTRY_CODE   Wi-Fi country code. Default: AE
EOF
}

case "$ACTION" in
  install)
    install_module
    ;;
  uninstall|remove)
    uninstall_module
    ;;
  purge)
    warn "purge is treated as uninstall; packages are not removed."
    uninstall_module
    ;;
  -h|--help|help)
    usage
    ;;
  *)
    err "Unknown action: ${ACTION}"
    usage
    exit 1
    ;;
esac
