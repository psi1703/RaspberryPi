#!/usr/bin/env bash
# InitBox Pi Zero W / Zero 2W Hotspot module
#
# Actions:
#   install    Install and enable InitBox hotspot.
#   uninstall  Remove services/config created by this module, but keep packages.
#   remove     Alias for uninstall.
#   purge      Compatibility alias for uninstall. It does not purge packages.
#
# Pi Zero policy:
#   - stable hotspot gateway: 192.168.20.1/24
#   - BOX number affects SSID only, for example initbox_3
#   - original config files are used directly; no dnsmasq.d or systemd drop-ins
#   - package install uses the local InitBox package cache helper

set -euo pipefail

ACTION="${1:-install}"

: "${OWNER:=initbox}"
: "${HOTSPOT_PASS:=TomatoH34d}"
: "${HOTSPOT_INTERFACE:=wlan0}"
: "${HOTSPOT_COUNTRY:=AE}"
: "${HOTSPOT_CHANNEL:=1}"
: "${HOTSPOT_GATEWAY:=192.168.20.1}"
: "${HOTSPOT_DHCP_START:=192.168.20.10}"
: "${HOTSPOT_DHCP_END:=192.168.20.20}"
: "${HOTSPOT_DHCP_LEASE:=24h}"
: "${LOGFILE:=/home/${OWNER}/pi_logs/initbox-install.log}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${INITBOX_REPO_ROOT:-$(cd "$SCRIPT_DIR/../.." && pwd)}"

INITBOX_PACKAGES_FILE="${INITBOX_PACKAGES_FILE:-$REPO_ROOT/scripts/packages.txt}"
INITBOX_PACKAGE_CACHE_DIR="${INITBOX_PACKAGE_CACHE_DIR:-/opt/initbox/packages}"
PACKAGES_LIB_FILE="$REPO_ROOT/scripts/lib/packages.sh"

HOSTAPD_CONF="/etc/hostapd/hostapd.conf"
HOSTAPD_DEFAULT="/etc/default/hostapd"

DNSMASQ_CONF="/etc/dnsmasq.conf"
DNSMASQ_BACKUP="${DNSMASQ_CONF}.initbox.bak"
DNSMASQ_DIR="/etc/dnsmasq.d"

DHCPCD_CONF="/etc/dhcpcd.conf"
NETWORKMANAGER_UNMANAGED_FILE="/etc/NetworkManager/conf.d/initbox-unmanaged-wlan0.conf"
BOXNO_FILE="/etc/pi-boxno"

ts() {
  date '+%Y-%m-%d %H:%M:%S'
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

die() {
  err "$*"
  exit 1
}

ask() {
  local prompt="$1"
  local default="$2"
  local reply=""

  if [ -t 0 ]; then
    read -r -p "$prompt [$default]: " reply
    printf '%s\n' "${reply:-$default}"
  else
    printf '%s\n' "$default"
  fi
}

require_root() {
  if [ "$(id -u)" -ne 0 ]; then
    die "this module must be run as root"
  fi
}

ensure_log_dir() {
  install -d -m 0755 "$(dirname "$LOGFILE")"
  touch "$LOGFILE"
  chown "$OWNER:$OWNER" "$LOGFILE" 2>/dev/null || true
}

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

load_package_helper() {
  if [ ! -f "$PACKAGES_LIB_FILE" ]; then
    die "package helper missing: $PACKAGES_LIB_FILE"
  fi

  # shellcheck disable=SC1090
  . "$PACKAGES_LIB_FILE"

  if ! declare -F initbox_packages_install >/dev/null 2>&1; then
    die "package helper does not define initbox_packages_install"
  fi
}

install_dependencies() {
  log "Installing hotspot dependencies from InitBox package cache"
  log "packages file: $INITBOX_PACKAGES_FILE"
  log "cache dir:     $INITBOX_PACKAGE_CACHE_DIR"

  load_package_helper

  initbox_packages_install \
    "$INITBOX_PACKAGES_FILE" \
    "$INITBOX_PACKAGE_CACHE_DIR" \
    dnsmasq \
    hostapd \
    dhcpcd5 \
    iproute2 \
    iptables \
    rfkill
}

validate_hotspot_values() {
  case "$HOTSPOT_GATEWAY" in
    192.168.20.*)
      ;;
    *)
      die "HOTSPOT_GATEWAY must stay inside 192.168.20.0/24 for pi-zero2w. Current: $HOTSPOT_GATEWAY"
      ;;
  esac

  if [ "${#HOTSPOT_PASS}" -lt 8 ] || [ "${#HOTSPOT_PASS}" -gt 63 ]; then
    die "HOTSPOT_PASS must be 8-63 characters for WPA2."
  fi

  case "$HOTSPOT_CHANNEL" in
    ''|*[!0-9]*)
      die "HOTSPOT_CHANNEL must be numeric."
      ;;
  esac

  if [ "$HOTSPOT_CHANNEL" -lt 1 ] || [ "$HOTSPOT_CHANNEL" -gt 13 ]; then
    die "HOTSPOT_CHANNEL must be between 1 and 13."
  fi
}

get_box_number() {
  local boxno=""

  if [ -r "$BOXNO_FILE" ]; then
    boxno="$(cat "$BOXNO_FILE" 2>/dev/null || printf '1')"
  else
    boxno="$(ask 'Enter BOX number, used in SSID initbox_<number>' '1')"
    printf '%s\n' "$boxno" >"$BOXNO_FILE"
  fi

  if ! printf '%s\n' "$boxno" | grep -Eq '^[0-9]+$'; then
    warn "invalid BOX number '$boxno'; using 1"
    boxno="1"
    printf '%s\n' "$boxno" >"$BOXNO_FILE"
  fi

  if [ "$boxno" -lt 1 ] || [ "$boxno" -gt 254 ]; then
    warn "BOX number '$boxno' outside valid range 1-254; using 1"
    boxno="1"
    printf '%s\n' "$boxno" >"$BOXNO_FILE"
  fi

  printf '%s\n' "$boxno"
}

stop_conflicting_wifi_clients() {
  log "Disabling interface-specific client Wi-Fi services for ${HOTSPOT_INTERFACE}"

  systemctl stop "wpa_supplicant@${HOTSPOT_INTERFACE}.service" 2>/dev/null || true
  systemctl disable "wpa_supplicant@${HOTSPOT_INTERFACE}.service" 2>/dev/null || true

  if systemctl list-unit-files NetworkManager.service >/dev/null 2>&1; then
    warn "NetworkManager exists; marking ${HOTSPOT_INTERFACE} unmanaged"
    install -d -m 0755 /etc/NetworkManager/conf.d

    cat >"$NETWORKMANAGER_UNMANAGED_FILE" <<EOF
[keyfile]
unmanaged-devices=interface-name:${HOTSPOT_INTERFACE}
EOF

    systemctl reload NetworkManager.service 2>/dev/null || systemctl restart NetworkManager.service 2>/dev/null || true
  fi
}

write_hostapd_conf() {
  local ssid="$1"

  log "Writing ${HOSTAPD_CONF}"

  install -d -m 0755 /etc/hostapd

  cat >"$HOSTAPD_CONF" <<EOF
# initbox-hotspot
country_code=${HOTSPOT_COUNTRY}
interface=${HOTSPOT_INTERFACE}
driver=nl80211
ssid=${ssid}
hw_mode=g
channel=${HOTSPOT_CHANNEL}
wmm_enabled=1
ieee80211n=1
macaddr_acl=0
auth_algs=1
ignore_broadcast_ssid=0
wpa=2
wpa_passphrase=${HOTSPOT_PASS}
wpa_key_mgmt=WPA-PSK
rsn_pairwise=CCMP
EOF

  chown root:root "$HOSTAPD_CONF"
  chmod 0600 "$HOSTAPD_CONF"

  cat >"$HOSTAPD_DEFAULT" <<EOF
DAEMON_CONF="${HOSTAPD_CONF}"
DAEMON_OPTS=""
EOF
}

remove_legacy_dnsmasq_dropins() {
  log "Removing old InitBox dnsmasq drop-ins, if present"

  rm -f "${DNSMASQ_DIR}/initbox-wlan.conf"
  rm -f "${DNSMASQ_DIR}/initbox-captive-portal.conf"
  rm -f "${DNSMASQ_DIR}/initbox-hotspot.conf"
}

backup_dnsmasq_conf_if_needed() {
  if [ -f "$DNSMASQ_CONF" ] && ! grep -q '^# initbox-hotspot' "$DNSMASQ_CONF"; then
    if [ ! -f "$DNSMASQ_BACKUP" ]; then
      log "Backing up existing dnsmasq config to ${DNSMASQ_BACKUP}"
      cp "$DNSMASQ_CONF" "$DNSMASQ_BACKUP"
    else
      log "Existing dnsmasq backup already present: ${DNSMASQ_BACKUP}"
    fi
  fi
}

write_dnsmasq_conf() {
  log "Writing ${DNSMASQ_CONF}"

  backup_dnsmasq_conf_if_needed
  remove_legacy_dnsmasq_dropins

  cat >"$DNSMASQ_CONF" <<EOF
# initbox-hotspot
interface=${HOTSPOT_INTERFACE}
bind-dynamic
dhcp-authoritative

dhcp-range=${HOTSPOT_DHCP_START},${HOTSPOT_DHCP_END},${HOTSPOT_DHCP_LEASE}
dhcp-option=3,${HOTSPOT_GATEWAY}
dhcp-option=6,${HOTSPOT_GATEWAY}

domain=initbox.wlan
local=/initbox.wlan/

# Local InitBox names
address=/initbox.wlan/${HOTSPOT_GATEWAY}
address=/initbox.local/${HOTSPOT_GATEWAY}

# Field captive mode:
# Resolve all DNS names to the InitBox hotspot IP.
address=/#/${HOTSPOT_GATEWAY}

# Android captive portal checks
address=/connectivitycheck.gstatic.com/${HOTSPOT_GATEWAY}
address=/connectivitycheck.android.com/${HOTSPOT_GATEWAY}
address=/clients3.google.com/${HOTSPOT_GATEWAY}
address=/www.gstatic.com/${HOTSPOT_GATEWAY}
address=/www.google.com/${HOTSPOT_GATEWAY}

# Apple captive portal checks
address=/captive.apple.com/${HOTSPOT_GATEWAY}
address=/www.apple.com/${HOTSPOT_GATEWAY}
address=/www.appleiphonecell.com/${HOTSPOT_GATEWAY}

# Windows captive portal checks
address=/msftconnecttest.com/${HOTSPOT_GATEWAY}
address=/www.msftconnecttest.com/${HOTSPOT_GATEWAY}
address=/ipv6.msftconnecttest.com/${HOTSPOT_GATEWAY}
address=/msftncsi.com/${HOTSPOT_GATEWAY}
address=/www.msftncsi.com/${HOTSPOT_GATEWAY}
address=/dns.msftncsi.com/${HOTSPOT_GATEWAY}

# Firefox captive portal check
address=/detectportal.firefox.com/${HOTSPOT_GATEWAY}
EOF
}

write_dhcpcd_conf() {
  log "Ensuring static IP for ${HOTSPOT_INTERFACE} in ${DHCPCD_CONF}"

  touch "$DHCPCD_CONF"

  if grep -q '^# initbox-hotspot$' "$DHCPCD_CONF"; then
    sed -i '/^# initbox-hotspot$/,/^$/d' "$DHCPCD_CONF"
  fi

  cat >>"$DHCPCD_CONF" <<EOF

# initbox-hotspot
interface ${HOTSPOT_INTERFACE}
    static ip_address=${HOTSPOT_GATEWAY}/24
    nohook wpa_supplicant

EOF
}

validate_configs() {
  log "Validating dnsmasq configuration"

  dnsmasq --test 2>&1 | tee -a "$LOGFILE"

  if [ ! -s "$HOSTAPD_CONF" ]; then
    die "hostapd config is missing or empty: $HOSTAPD_CONF"
  fi

  if ! grep -q "^interface=${HOTSPOT_INTERFACE}$" "$HOSTAPD_CONF"; then
    die "hostapd config does not target ${HOTSPOT_INTERFACE}"
  fi

  if [ ! -s "$DNSMASQ_CONF" ]; then
    die "dnsmasq config is missing or empty: $DNSMASQ_CONF"
  fi

  if ! grep -q "^interface=${HOTSPOT_INTERFACE}$" "$DNSMASQ_CONF"; then
    die "dnsmasq config does not target ${HOTSPOT_INTERFACE}"
  fi

  if ! grep -q "^address=/#/${HOTSPOT_GATEWAY}$" "$DNSMASQ_CONF"; then
    die "dnsmasq wildcard captive DNS rule is missing"
  fi
}

restart_hotspot_stack() {
  log "Unmasking and enabling hotspot stack"

  systemctl unmask hostapd 2>/dev/null || true
  rfkill unblock wifi 2>/dev/null || rfkill unblock all 2>/dev/null || true

  systemctl daemon-reload

  systemctl enable dhcpcd.service 2>/dev/null || true
  systemctl enable hostapd.service 2>/dev/null || true
  systemctl enable dnsmasq.service 2>/dev/null || true

  log "Restarting dhcpcd"
  systemctl restart dhcpcd.service 2>/dev/null || systemctl start dhcpcd.service 2>/dev/null || true

  log "Preparing ${HOTSPOT_INTERFACE}"
  ip link set "$HOTSPOT_INTERFACE" up
  ip addr replace "${HOTSPOT_GATEWAY}/24" dev "$HOTSPOT_INTERFACE"

  log "Restarting hostapd"
  systemctl restart hostapd.service

  sleep 2

  log "Restarting dnsmasq"
  systemctl restart dnsmasq.service

  ok "Hotspot stack restarted"
}

stop_and_disable_unit() {
  local unit_name="$1"

  log "Stopping and disabling ${unit_name} if present"
  systemctl disable --now "$unit_name" 2>/dev/null || true
  systemctl reset-failed "$unit_name" 2>/dev/null || true
}

restore_dnsmasq_conf_if_possible() {
  if [ -f "$DNSMASQ_CONF" ] && grep -q '^# initbox-hotspot' "$DNSMASQ_CONF"; then
    if [ -f "$DNSMASQ_BACKUP" ]; then
      log "Restoring previous dnsmasq config from ${DNSMASQ_BACKUP}"
      cp "$DNSMASQ_BACKUP" "$DNSMASQ_CONF"
      rm -f "$DNSMASQ_BACKUP"
    else
      log "Removing InitBox-owned dnsmasq config"
      rm -f "$DNSMASQ_CONF"
    fi
  else
    log "dnsmasq config is not InitBox-owned; leaving unchanged"
  fi
}

remove_dhcpcd_hotspot_block() {
  if [ -f "$DHCPCD_CONF" ] && grep -q '^# initbox-hotspot$' "$DHCPCD_CONF"; then
    log "Removing InitBox dhcpcd hotspot block"
    sed -i '/^# initbox-hotspot$/,/^$/d' "$DHCPCD_CONF"
  fi
}

remove_hostapd_config_if_owned() {
  if [ -f "$HOSTAPD_CONF" ] && grep -q '^# initbox-hotspot' "$HOSTAPD_CONF"; then
    log "Removing InitBox-owned hostapd config"
    rm -f "$HOSTAPD_CONF"
  else
    log "hostapd config is not InitBox-owned; leaving unchanged"
  fi

  if [ -f "$HOSTAPD_DEFAULT" ] && grep -q "$HOSTAPD_CONF" "$HOSTAPD_DEFAULT"; then
    log "Removing hostapd default config pointer"
    rm -f "$HOSTAPD_DEFAULT"
  fi
}

remove_networkmanager_unmanaged_config() {
  if [ -f "$NETWORKMANAGER_UNMANAGED_FILE" ]; then
    log "Removing NetworkManager unmanaged config for ${HOTSPOT_INTERFACE}"
    rm -f "$NETWORKMANAGER_UNMANAGED_FILE"

    if systemctl list-unit-files NetworkManager.service >/dev/null 2>&1; then
      systemctl reload NetworkManager.service 2>/dev/null || systemctl restart NetworkManager.service 2>/dev/null || true
    fi
  fi
}

release_hotspot_interface() {
  log "Removing InitBox hotspot IP from ${HOTSPOT_INTERFACE} if present"

  if command_exists ip; then
    ip -4 addr del "${HOTSPOT_GATEWAY}/24" dev "$HOTSPOT_INTERFACE" 2>/dev/null || true
    ip link set "$HOTSPOT_INTERFACE" down 2>/dev/null || true
  fi
}

remove_hotspot_services_and_config() {
  log "Removing InitBox hotspot services and configuration"

  stop_and_disable_unit "dnsmasq.service"
  stop_and_disable_unit "hostapd.service"

  remove_legacy_dnsmasq_dropins
  restore_dnsmasq_conf_if_possible
  remove_dhcpcd_hotspot_block
  remove_hostapd_config_if_owned
  remove_networkmanager_unmanaged_config
  release_hotspot_interface

  systemctl daemon-reload
  systemctl reset-failed 2>/dev/null || true
}

print_summary() {
  local ssid="$1"

  echo
  echo "InitBox hotspot installed"
  echo "-------------------------"
  echo "SSID:       ${ssid}"
  echo "Password:   ${HOTSPOT_PASS}"
  echo "Interface:  ${HOTSPOT_INTERFACE}"
  echo "IP:         ${HOTSPOT_GATEWAY}/24"
  echo "DHCP range: ${HOTSPOT_DHCP_START},${HOTSPOT_DHCP_END},${HOTSPOT_DHCP_LEASE}"
  echo
  echo "Captive DNS:"
  echo "  address=/#/${HOTSPOT_GATEWAY}"
  echo
  echo "Local URLs:"
  echo "  http://initbox.wlan/"
  echo "  http://${HOTSPOT_GATEWAY}/"
  echo
  echo "Config files:"
  echo "  ${HOSTAPD_CONF}"
  echo "  ${HOSTAPD_DEFAULT}"
  echo "  ${DNSMASQ_CONF}"
  echo "  ${DHCPCD_CONF}"
  echo
  echo "Offline field-mode behavior:"
  echo "  - Debian packages are installed from ${INITBOX_PACKAGE_CACHE_DIR}"
  echo "  - uninstall does not remove packages or cached .deb files"
  echo "  - purge is disabled and behaves like uninstall"
  echo
  echo "Check services:"
  echo "  sudo systemctl status hostapd dnsmasq dhcpcd --no-pager"
  echo
  echo "Check wlan0:"
  echo "  ip -4 addr show ${HOTSPOT_INTERFACE}"
  echo
  echo "Check DNS config:"
  echo "  sudo dnsmasq --test"
  echo "  sudo grep -n 'address=/#' ${DNSMASQ_CONF}"
  echo
  echo "Check logs:"
  echo "  sudo journalctl -u hostapd -u dnsmasq -u dhcpcd -b --no-pager -n 120"
}

print_uninstall_summary() {
  echo
  echo "InitBox hotspot uninstalled"
  echo "---------------------------"
  echo "Removed/restored:"
  echo "  - InitBox hostapd config if owned by InitBox"
  echo "  - InitBox dnsmasq config if owned by InitBox"
  echo "  - previous dnsmasq config from ${DNSMASQ_BACKUP}, if backup exists"
  echo "  - InitBox dhcpcd hotspot block"
  echo "  - old InitBox dnsmasq drop-ins, if present"
  echo "  - NetworkManager unmanaged config written by this module"
  echo "  - hotspot IP ${HOTSPOT_GATEWAY}/24 from ${HOTSPOT_INTERFACE}"
  echo
  echo "Not removed:"
  echo "  - installed packages"
  echo "  - cached .deb files under ${INITBOX_PACKAGE_CACHE_DIR}"
  echo "  - ${BOXNO_FILE}"
  echo
  echo "Check:"
  echo "  sudo systemctl status hostapd dnsmasq dhcpcd --no-pager"
  echo "  ip -4 addr show ${HOTSPOT_INTERFACE}"
}

install_main() {
  local boxno=""
  local ssid=""

  require_root
  ensure_log_dir
  validate_hotspot_values
  install_dependencies

  boxno="$(get_box_number)"
  ssid="initbox_${boxno}"

  log "Hotspot SSID=${ssid}, gateway=${HOTSPOT_GATEWAY}, DHCP=${HOTSPOT_DHCP_START}-${HOTSPOT_DHCP_END}"
  log "HOTSPOT_PASS is set but not logged"

  stop_conflicting_wifi_clients
  write_hostapd_conf "$ssid"
  write_dnsmasq_conf
  write_dhcpcd_conf
  validate_configs
  restart_hotspot_stack
  print_summary "$ssid"

  ok "Hotspot module installed. Connect to SSID '${ssid}'."
}

uninstall_main() {
  require_root
  ensure_log_dir

  remove_hotspot_services_and_config
  print_uninstall_summary
  ok "Hotspot module uninstalled."
}

main() {
  case "$ACTION" in
    install|"")
      install_main
      ;;
    uninstall|remove)
      uninstall_main
      ;;
    purge)
      warn "purge is disabled by offline field-mode policy; running uninstall only"
      uninstall_main
      ;;
    *)
      die "unknown action '$ACTION'. Use install or uninstall."
      ;;
  esac
}

main "$@"
