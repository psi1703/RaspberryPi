#!/usr/bin/env bash
set -euo pipefail

: "${OWNER:=initbox}"
: "${HOTSPOT_PASS:=TomatoH34d}"
: "${HOTSPOT_INTERFACE:=wlan0}"
: "${LOGFILE:=/home/${OWNER}/pi_logs/initbox-install.log}"

HOSTAPD_CONF="/etc/hostapd/hostapd.conf"
HOSTAPD_DEFAULT="/etc/default/hostapd"
HOSTAPD_OVERRIDE_DIR="/etc/systemd/system/hostapd.service.d"
HOSTAPD_OVERRIDE_FILE="${HOSTAPD_OVERRIDE_DIR}/initbox-hotspot.conf"

DNSMASQ_CONF="/etc/dnsmasq.conf"
DNSMASQ_DIR="/etc/dnsmasq.d"
DNSMASQ_OVERRIDE_DIR="/etc/systemd/system/dnsmasq.service.d"
DNSMASQ_OVERRIDE_FILE="${DNSMASQ_OVERRIDE_DIR}/initbox-hotspot.conf"

DHCPCD_CONF="/etc/dhcpcd.conf"
BOXNO_FILE="/etc/pi-boxno"

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

apt_safe() {
  apt-get -o Dpkg::Use-Pty=0 -o Acquire::Retries=5 "$@" 2>&1 | tee -a "$LOGFILE"
}

ask() {
  local prompt="$1"
  local default="$2"
  local reply=""

  if [ -t 0 ]; then
    read -r -p "$prompt [$default]: " reply
    echo "${reply:-$default}"
  else
    echo "$default"
  fi
}

require_root() {
  if [ "$(id -u)" -ne 0 ]; then
    err "this module must be run as root"
    exit 1
  fi
}

ensure_log_dir() {
  mkdir -p "$(dirname "$LOGFILE")"
  touch "$LOGFILE"
  chown "$OWNER:$OWNER" "$LOGFILE" 2>/dev/null || true
}

calc_hotspot_subnet() {
  local model=""

  model="$(tr -d '\0' </proc/device-tree/model 2>/dev/null || echo "")"

  case "$model" in
    *Zero*) echo "192.168.20" ;;
    *"Raspberry Pi 3"*) echo "192.168.30" ;;
    *"Raspberry Pi 4"*) echo "192.168.40" ;;
    *"Raspberry Pi 5"*) echo "192.168.50" ;;
    *) echo "192.168.20" ;;
  esac
}

get_box_number() {
  local boxno=""

  if [ -r "$BOXNO_FILE" ]; then
    boxno="$(cat "$BOXNO_FILE" 2>/dev/null || echo "1")"
  else
    boxno="$(ask 'Enter BOX number (last octet, e.g., 1)' '1')"
    echo "$boxno" >"$BOXNO_FILE"
  fi

  if ! echo "$boxno" | grep -Eq '^[0-9]+$'; then
    warn "invalid BOX number '$boxno'; using 1"
    boxno="1"
    echo "$boxno" >"$BOXNO_FILE"
  fi

  if [ "$boxno" -lt 1 ] || [ "$boxno" -gt 254 ]; then
    warn "BOX number '$boxno' outside valid range 1-254; using 1"
    boxno="1"
    echo "$boxno" >"$BOXNO_FILE"
  fi

  echo "$boxno"
}

install_dependencies() {
  log "Installing hotspot dependencies"
  apt_safe update
  apt_safe install -y dnsmasq hostapd dhcpcd5 iproute2 iptables rfkill
}

stop_conflicting_wifi_clients() {
  log "Disabling interface-specific client Wi-Fi services for ${HOTSPOT_INTERFACE}"

  systemctl stop "wpa_supplicant@${HOTSPOT_INTERFACE}.service" 2>/dev/null || true
  systemctl disable "wpa_supplicant@${HOTSPOT_INTERFACE}.service" 2>/dev/null || true

  if systemctl list-unit-files NetworkManager.service >/dev/null 2>&1; then
    warn "NetworkManager exists; marking ${HOTSPOT_INTERFACE} unmanaged"
    mkdir -p /etc/NetworkManager/conf.d

    cat >/etc/NetworkManager/conf.d/initbox-unmanaged-wlan0.conf <<EOF
[keyfile]
unmanaged-devices=interface-name:${HOTSPOT_INTERFACE}
EOF

    systemctl reload NetworkManager.service 2>/dev/null || systemctl restart NetworkManager.service 2>/dev/null || true
  fi
}

write_hostapd_conf() {
  local ssid="$1"

  log "Writing ${HOSTAPD_CONF}"

  mkdir -p /etc/hostapd

  cat >"$HOSTAPD_CONF" <<EOF
# initbox-hotspot
country_code=AE
interface=${HOTSPOT_INTERFACE}
driver=nl80211
ssid=${ssid}
hw_mode=g
channel=6
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
  chmod 600 "$HOSTAPD_CONF"

  cat >"$HOSTAPD_DEFAULT" <<EOF
DAEMON_CONF="${HOSTAPD_CONF}"
DAEMON_OPTS=""
EOF
}

remove_legacy_dnsmasq_fragments() {
  log "Removing old InitBox dnsmasq fragments to avoid conflicting captive DNS"

  rm -f "${DNSMASQ_DIR}/initbox-wlan.conf"
  rm -f "${DNSMASQ_DIR}/initbox-captive-portal.conf"
  rm -f "${DNSMASQ_DIR}/initbox-hotspot.conf"
}

write_dnsmasq_conf() {
  local hip="$1"
  local range="$2"

  log "Writing ${DNSMASQ_CONF}"

  mkdir -p "$DNSMASQ_DIR"

  if [ -f "$DNSMASQ_CONF" ] && ! grep -q '^# initbox-hotspot' "$DNSMASQ_CONF"; then
    cp "$DNSMASQ_CONF" "${DNSMASQ_CONF}.initbox.bak" 2>/dev/null || true
  fi

  cat >"$DNSMASQ_CONF" <<EOF
# initbox-hotspot
interface=${HOTSPOT_INTERFACE}
bind-dynamic
dhcp-authoritative

dhcp-range=${range}
dhcp-option=3,${hip}
dhcp-option=6,${hip}

domain=initbox.wlan
local=/initbox.wlan/

# Local InitBox names
address=/initbox.wlan/${hip}
address=/initbox.local/${hip}

# Field captive mode:
# Resolve all DNS names to the InitBox hotspot IP.
# This is the simple wildcard captive DNS trick.
address=/#/${hip}

# Android captive portal checks
address=/connectivitycheck.gstatic.com/${hip}
address=/connectivitycheck.android.com/${hip}
address=/clients3.google.com/${hip}
address=/www.gstatic.com/${hip}
address=/www.google.com/${hip}

# Apple captive portal checks
address=/captive.apple.com/${hip}
address=/www.apple.com/${hip}
address=/www.appleiphonecell.com/${hip}

# Windows captive portal checks
address=/msftconnecttest.com/${hip}
address=/www.msftconnecttest.com/${hip}
address=/ipv6.msftconnecttest.com/${hip}
address=/msftncsi.com/${hip}
address=/www.msftncsi.com/${hip}
address=/dns.msftncsi.com/${hip}

# Firefox captive portal check
address=/detectportal.firefox.com/${hip}
EOF
}

write_dhcpcd_conf() {
  local hip="$1"

  log "Ensuring static IP for ${HOTSPOT_INTERFACE} in ${DHCPCD_CONF}"

  touch "$DHCPCD_CONF"

  if grep -q '^# initbox-hotspot$' "$DHCPCD_CONF"; then
    sed -i '/^# initbox-hotspot$/,/^$/d' "$DHCPCD_CONF"
  fi

  cat >>"$DHCPCD_CONF" <<EOF

# initbox-hotspot
interface ${HOTSPOT_INTERFACE}
    static ip_address=${hip}/24
    nohook wpa_supplicant

EOF
}

write_hostapd_systemd_override() {
  local hip="$1"

  log "Writing hostapd systemd boot-order override"

  mkdir -p "$HOSTAPD_OVERRIDE_DIR"

  cat >"$HOSTAPD_OVERRIDE_FILE" <<EOF
[Unit]
After=systemd-rfkill.service dhcpcd.service
Wants=systemd-rfkill.service dhcpcd.service

[Service]
Restart=always
RestartSec=3
ExecStartPre=/bin/sleep 5
ExecStartPre=/usr/sbin/rfkill unblock wifi
ExecStartPre=/usr/sbin/ip link set ${HOTSPOT_INTERFACE} up
ExecStartPre=/usr/sbin/ip addr replace ${hip}/24 dev ${HOTSPOT_INTERFACE}
EOF
}

write_dnsmasq_systemd_override() {
  local hip="$1"

  log "Writing dnsmasq systemd boot-order override"

  mkdir -p "$DNSMASQ_OVERRIDE_DIR"

  cat >"$DNSMASQ_OVERRIDE_FILE" <<EOF
[Unit]
After=dhcpcd.service hostapd.service
Wants=dhcpcd.service hostapd.service

[Service]
Restart=always
RestartSec=3
ExecStartPre=/usr/sbin/ip link set ${HOTSPOT_INTERFACE} up
ExecStartPre=/usr/sbin/ip addr replace ${hip}/24 dev ${HOTSPOT_INTERFACE}
EOF
}

validate_configs() {
  log "Validating dnsmasq configuration"
  dnsmasq --test 2>&1 | tee -a "$LOGFILE"

  if [ ! -s "$HOSTAPD_CONF" ]; then
    err "hostapd config is missing or empty: $HOSTAPD_CONF"
    exit 1
  fi

  if ! grep -q "^interface=${HOTSPOT_INTERFACE}$" "$HOSTAPD_CONF"; then
    err "hostapd config does not target ${HOTSPOT_INTERFACE}"
    exit 1
  fi
}

restart_hotspot_stack() {
  local hip="$1"

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
  ip addr replace "${hip}/24" dev "$HOTSPOT_INTERFACE"

  log "Restarting hostapd"
  systemctl restart hostapd.service

  sleep 2

  log "Restarting dnsmasq"
  systemctl restart dnsmasq.service

  ok "Hotspot stack restarted"
}

print_summary() {
  local ssid="$1"
  local hip="$2"
  local range="$3"

  echo
  echo "InitBox hotspot installed"
  echo "-------------------------"
  echo "SSID:       ${ssid}"
  echo "Password:   ${HOTSPOT_PASS}"
  echo "Interface:  ${HOTSPOT_INTERFACE}"
  echo "IP:         ${hip}/24"
  echo "DHCP range: ${range}"
  echo
  echo "Captive DNS:"
  echo "  address=/#/${hip}"
  echo
  echo "Check services:"
  echo "  sudo systemctl status hostapd dnsmasq dhcpcd --no-pager"
  echo
  echo "Check wlan0:"
  echo "  ip -4 addr show ${HOTSPOT_INTERFACE}"
  echo
  echo "Check DNS config:"
  echo "  sudo dnsmasq --test"
  echo "  sudo grep -n 'address=/#' /etc/dnsmasq.conf"
  echo
  echo "Check logs:"
  echo "  sudo journalctl -u hostapd -u dnsmasq -u dhcpcd -b --no-pager -n 120"
}

main() {
  local boxno=""
  local ssid=""
  local baseip=""
  local hip=""
  local range=""

  require_root
  ensure_log_dir
  install_dependencies

  boxno="$(get_box_number)"
  ssid="initbox_${boxno}"
  baseip="$(calc_hotspot_subnet)"
  hip="${baseip}.${boxno}"
  range="${baseip}.10,${baseip}.20,24h"

  log "Hotspot SSID=${ssid}, IP=${hip}, range=${range}"
  log "HOTSPOT_PASS is set but not logged"

  stop_conflicting_wifi_clients
  write_hostapd_conf "$ssid"
  remove_legacy_dnsmasq_fragments
  write_dnsmasq_conf "$hip" "$range"
  write_dhcpcd_conf "$hip"
  write_hostapd_systemd_override "$hip"
  write_dnsmasq_systemd_override "$hip"
  validate_configs
  restart_hotspot_stack "$hip"
  print_summary "$ssid" "$hip" "$range"

  ok "Hotspot module installed. Connect to SSID '${ssid}'."
}

main "$@"
