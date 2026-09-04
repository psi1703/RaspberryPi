#!/usr/bin/env bash
# InitBox Raspberry Pi 3 / 4 / 5 hotspot module
#
# Ownership model:
#   - eth0 is upstream/lab Internet and is not configured by this module.
#   - wlan0 is hotspot-only and is the only interface this module configures.
#   - wlan0 static hotspot IP is configured in dhcpcd and also enforced
#     before hostapd/dnsmasq start, so DHCP/DNS never run on 169.254.x.x.
#   - dnsmasq provides DHCP/DNS only for hotspot clients.
#   - Captive DNS catch-all is intentional for hotspot clients.
#   - local-service prevents hotspot dnsmasq from answering non-hotspot-side
#     DNS queries from the Pi itself.
#
# Installs:
#   - hostapd hotspot on wlan0
#   - dnsmasq DHCP/DNS for hotspot clients
#   - managed /etc/dhcpcd.conf block for wlan0 hotspot IP
#
# Actions:
#   install    Install/update hotspot configuration
#   uninstall  Disable/remove hotspot configuration created by this module
#   purge      Compatibility alias for uninstall; packages are not purged

set -euo pipefail

ACTION="${1:-install}"

: "${OWNER:=initbox}"

SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_PATH")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PACKAGES_HELPER="$REPO_ROOT/scripts/lib/packages.sh"

LOG_DIR="/home/${OWNER}/pi_logs"
LOGFILE="${LOGFILE:-${LOG_DIR}/initbox-install.log}"

BOXNO_FILE="${BOXNO_FILE:-/etc/pi-boxno}"
WLAN_IFACE="${WLAN_IFACE:-wlan0}"
UPSTREAM_IFACE="${UPSTREAM_IFACE:-eth0}"
COUNTRY_CODE="${COUNTRY_CODE:-AE}"

# Hotspot network configuration.
#
# Pi 3 / 4 / 5 dashboard branch default:
#   hotspot gateway: 192.168.30.1
#   client DHCP:     192.168.30.10-192.168.30.20
#
# The installer/profile may still override HOTSPOT_SUBNET_PREFIX when needed,
# but direct module runs must remain safe and deterministic for Pi 3 / 4 / 5.
HOTSPOT_SUBNET_PREFIX="${HOTSPOT_SUBNET_PREFIX:-192.168.30}"
HOTSPOT_GATEWAY_OCTET="${HOTSPOT_GATEWAY_OCTET:-1}"
HOTSPOT_DHCP_START="${HOTSPOT_DHCP_START:-10}"
HOTSPOT_DHCP_END="${HOTSPOT_DHCP_END:-20}"
HOTSPOT_DHCP_LEASE="${HOTSPOT_DHCP_LEASE:-24h}"

HOSTAPD_CONF="/etc/hostapd/hostapd.conf"
HOSTAPD_DEFAULT="/etc/default/hostapd"
HOSTAPD_OVERRIDE_DIR="/etc/systemd/system/hostapd.service.d"
HOSTAPD_SERVICE_OVERRIDE="${HOSTAPD_OVERRIDE_DIR}/20-initbox-hostapd-service.conf"
HOSTAPD_POWERSAVE_OVERRIDE="${HOSTAPD_OVERRIDE_DIR}/10-initbox-wifi-powersave.conf"
HOSTAPD_PIDFILE="/run/hostapd.pid"

DNSMASQ_DROPIN_DIR="/etc/dnsmasq.d"
DNSMASQ_CONF="${DNSMASQ_DROPIN_DIR}/initbox-hotspot.conf"
DNSMASQ_OVERRIDE_DIR="/etc/systemd/system/dnsmasq.service.d"
DNSMASQ_HOTSPOT_OVERRIDE="${DNSMASQ_OVERRIDE_DIR}/10-initbox-hotspot.conf"

DHCPCD_CONF="/etc/dhcpcd.conf"
NM_HOTSPOT_UNMANAGED_DIR="/etc/NetworkManager/conf.d"
NM_HOTSPOT_UNMANAGED_FILE="${NM_HOTSPOT_UNMANAGED_DIR}/99-initbox-hotspot-unmanaged.conf"
STATIC_INITBOX_PASSWORD="${STATIC_INITBOX_PASSWORD:-TomatoH34d}"
OLD_HOTSPOT_IP_SERVICE="/etc/systemd/system/initbox-hotspot-ip.service"
OLD_NET_GUARD="/usr/local/bin/initbox-net-guard.sh"
OLD_NET_GUARD_SERVICE="/etc/systemd/system/initbox-net-guard.service"

HOTSPOT_STATE_FILE="/etc/initbox/hotspot-state.env"

DHCPCD_SERVICE=""

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

prepare_state_dir() {
  install -d -m 0755 /etc/initbox
}

write_hotspot_state() {
  local status="$1"
  local message="$2"
  local iface_present="$3"

  prepare_state_dir

  cat >"$HOTSPOT_STATE_FILE" <<STATE_EOF
HOTSPOT_STATUS=${status}
HOTSPOT_MESSAGE=${message}
HOTSPOT_INTERFACE=${WLAN_IFACE}
HOTSPOT_INTERFACE_PRESENT=${iface_present}
UPSTREAM_INTERFACE=${UPSTREAM_IFACE}
HOTSPOT_SUBNET_PREFIX=${HOTSPOT_SUBNET_PREFIX}
HOTSPOT_GATEWAY_OCTET=${HOTSPOT_GATEWAY_OCTET}
HOTSPOT_DHCP_START=${HOTSPOT_DHCP_START}
HOTSPOT_DHCP_END=${HOTSPOT_DHCP_END}
STATE_EOF

  chmod 644 "$HOTSPOT_STATE_FILE"
  chown root:root "$HOTSPOT_STATE_FILE" || true
}

service_exists() {
  local service_name="$1"
  systemctl cat "$service_name" >/dev/null 2>&1
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
    rfkill \
    iw 2>&1 | tee -a "$LOGFILE"; then
    err "Hotspot dependency installation failed."
    err "If this Pi is offline, prepare the package cache first with:"
    err "  sudo ./scripts/initbox-installer.sh pi-3-4-5 p"
    exit 1
  fi
}

detect_dhcpcd_service() {
  if service_exists dhcpcd.service; then
    DHCPCD_SERVICE="dhcpcd.service"
    return 0
  fi

  if service_exists dhcpcd5.service; then
    DHCPCD_SERVICE="dhcpcd5.service"
    return 0
  fi

  err "dhcpcd service not found after installing dhcpcd5."
  err "Expected one of: dhcpcd.service or dhcpcd5.service"
  exit 1
}

resolve_hotspot_pass() {
  HOTSPOT_PASS="$STATIC_INITBOX_PASSWORD"
  log "Using static InitBox hotspot passphrase (not logged)."
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

validate_ipv4_octet() {
  local value="$1"

  case "$value" in
    ''|*[!0-9]*)
      return 1
      ;;
    *)
      [ "$value" -ge 0 ] && [ "$value" -le 255 ]
      ;;
  esac
}

validate_ipv4_prefix() {
  local prefix="$1"
  local first=""
  local second=""
  local third=""
  local extra=""

  IFS=. read -r first second third extra <<EOF_PREFIX
${prefix}
EOF_PREFIX

  [ -z "$extra" ] || return 1
  validate_ipv4_octet "$first" || return 1
  validate_ipv4_octet "$second" || return 1
  validate_ipv4_octet "$third" || return 1
}

validate_hotspot_network_config() {
  if ! validate_ipv4_prefix "$HOTSPOT_SUBNET_PREFIX"; then
    err "HOTSPOT_SUBNET_PREFIX is missing or invalid: '${HOTSPOT_SUBNET_PREFIX}'"
    err "Expected Pi 3/4/5 default: 192.168.30"
    exit 1
  fi

  if ! validate_ipv4_octet "$HOTSPOT_GATEWAY_OCTET"; then
    err "HOTSPOT_GATEWAY_OCTET is invalid: '${HOTSPOT_GATEWAY_OCTET}'"
    exit 1
  fi

  if ! validate_ipv4_octet "$HOTSPOT_DHCP_START"; then
    err "HOTSPOT_DHCP_START is invalid: '${HOTSPOT_DHCP_START}'"
    exit 1
  fi

  if ! validate_ipv4_octet "$HOTSPOT_DHCP_END"; then
    err "HOTSPOT_DHCP_END is invalid: '${HOTSPOT_DHCP_END}'"
    exit 1
  fi

  if [ "$HOTSPOT_GATEWAY_OCTET" -eq 0 ] || [ "$HOTSPOT_GATEWAY_OCTET" -eq 255 ]; then
    err "HOTSPOT_GATEWAY_OCTET must be between 1 and 254."
    exit 1
  fi

  if [ "$HOTSPOT_DHCP_START" -eq 0 ] || [ "$HOTSPOT_DHCP_START" -eq 255 ]; then
    err "HOTSPOT_DHCP_START must be between 1 and 254."
    exit 1
  fi

  if [ "$HOTSPOT_DHCP_END" -eq 0 ] || [ "$HOTSPOT_DHCP_END" -eq 255 ]; then
    err "HOTSPOT_DHCP_END must be between 1 and 254."
    exit 1
  fi

  if [ "$HOTSPOT_DHCP_START" -gt "$HOTSPOT_DHCP_END" ]; then
    err "HOTSPOT_DHCP_START must be less than or equal to HOTSPOT_DHCP_END."
    exit 1
  fi

  if [ "$HOTSPOT_GATEWAY_OCTET" -ge "$HOTSPOT_DHCP_START" ] && [ "$HOTSPOT_GATEWAY_OCTET" -le "$HOTSPOT_DHCP_END" ]; then
    err "Hotspot gateway octet overlaps DHCP client range."
    err "Gateway octet: ${HOTSPOT_GATEWAY_OCTET}"
    err "DHCP range: ${HOTSPOT_DHCP_START}-${HOTSPOT_DHCP_END}"
    exit 1
  fi
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

wait_for_wlan_iface() {
  local attempt=0
  local max_attempts=20

  log "Checking for wireless interface: ${WLAN_IFACE}"

  while [ "$attempt" -lt "$max_attempts" ]; do
    if ip link show "$WLAN_IFACE" >/dev/null 2>&1; then
      ok "Wireless interface found: ${WLAN_IFACE}"
      write_hotspot_state "ok" "Wireless interface found" "1"
      return 0
    fi

    attempt=$((attempt + 1))
    log "Waiting for ${WLAN_IFACE} to appear (${attempt}/${max_attempts})."
    sleep 1
  done

  warn "Wireless interface not found: ${WLAN_IFACE}"
  warn "Hotspot configuration was written, but services were not started."
  write_hotspot_state "action_needed" "Wireless interface not found" "0"
  return 1
}

cleanup_old_net_guard() {
  log "Removing old InitBox net-guard artifacts, if present."

  systemctl stop initbox-net-guard.service 2>/dev/null || true
  systemctl disable initbox-net-guard.service 2>/dev/null || true

  rm -f "$OLD_NET_GUARD_SERVICE"
  rm -f "$OLD_NET_GUARD"

  systemctl daemon-reload
}

cleanup_old_hotspot_ip_service() {
  log "Removing old custom hotspot IP service, if present."

  systemctl stop initbox-hotspot-ip.service 2>/dev/null || true
  systemctl disable initbox-hotspot-ip.service 2>/dev/null || true
  rm -f "$OLD_HOTSPOT_IP_SERVICE"
}

backup_dhcpcd_conf() {
  local backup_file=""

  if [ ! -f "$DHCPCD_CONF" ]; then
    return 0
  fi

  backup_file="${DHCPCD_CONF}.initbox-backup.$(date +%Y%m%d-%H%M%S)"
  cp -a "$DHCPCD_CONF" "$backup_file"
  log "Backed up ${DHCPCD_CONF} to ${backup_file}."
}

remove_old_initbox_dhcpcd_blocks() {
  local tmp_file=""

  if [ ! -f "$DHCPCD_CONF" ]; then
    return 0
  fi

  log "Removing old InitBox-managed dhcpcd fragments."

  backup_dhcpcd_conf
  tmp_file="$(mktemp)"

  awk -v upstream="$UPSTREAM_IFACE" -v wlan="$WLAN_IFACE" '
    function flush_pending(    discard) {
      if (pending == "") {
        return
      }

      discard = 0

      if (pending_iface == upstream && pending ~ "^interface " upstream "\\n[[:space:]]+metric 100\\n*$") {
        discard = 1
      }

      if (pending_iface == wlan && \
          pending ~ "^interface " wlan "\\n" && \
          pending ~ /static ip_address=/ && \
          pending ~ /nohook wpa_supplicant/) {
        discard = 1
      }

      if (discard == 0) {
        printf "%s", pending
      }

      pending = ""
      pending_iface = ""
    }

    BEGIN {
      skip = 0
      pending = ""
      pending_iface = ""
    }

    /^# START INITBOX-HOTSPOT$/ {
      flush_pending()
      skip = 1
      next
    }

    /^# END INITBOX-HOTSPOT$/ {
      skip = 0
      next
    }

    /^# START INITBOX-NETWORK-SAFETY$/ {
      flush_pending()
      skip = 1
      next
    }

    /^# END INITBOX-NETWORK-SAFETY$/ {
      skip = 0
      next
    }

    skip == 1 {
      next
    }

    /^denyinterfaces veth[*]$/ {
      flush_pending()
      next
    }

    /^denyinterfaces br0$/ {
      flush_pending()
      next
    }

    /^interface[[:space:]]+/ {
      flush_pending()
      pending_iface = $2
      pending = $0 "\n"
      next
    }

    pending != "" {
      if ($0 ~ /^[[:space:]]/ || $0 == "") {
        pending = pending $0 "\n"
        next
      }
      flush_pending()
    }

    {
      print
    }

    END {
      flush_pending()
    }
  ' "$DHCPCD_CONF" >"$tmp_file"

  install -m 0644 "$tmp_file" "$DHCPCD_CONF"
  rm -f "$tmp_file"
}

networkmanager_is_available() {
  command -v nmcli >/dev/null 2>&1 || systemctl cat NetworkManager.service >/dev/null 2>&1
}

reload_networkmanager_policy() {
  if command -v nmcli >/dev/null 2>&1; then
    nmcli general reload >/dev/null 2>&1 || true
  fi
}

write_networkmanager_hotspot_unmanaged_policy() {
  if ! networkmanager_is_available; then
    log "NetworkManager not detected; skipping ${WLAN_IFACE} unmanaged policy."
    return 0
  fi

  log "Writing NetworkManager unmanaged policy for hotspot interface ${WLAN_IFACE}."

  install -d -m 0755 "$NM_HOTSPOT_UNMANAGED_DIR"

  cat >"$NM_HOTSPOT_UNMANAGED_FILE" <<NM_HOTSPOT_UNMANAGED_EOF
# InitBox hotspot interface ownership. Managed by module-hotspot.sh.
#
# ${WLAN_IFACE} is owned by dhcpcd + hostapd + dnsmasq in AP mode.
# NetworkManager must not scan, configure, reset, or roam this interface.
[keyfile]
unmanaged-devices=interface-name:${WLAN_IFACE}
NM_HOTSPOT_UNMANAGED_EOF

  chmod 644 "$NM_HOTSPOT_UNMANAGED_FILE"
  chown root:root "$NM_HOTSPOT_UNMANAGED_FILE" || true

  reload_networkmanager_policy
}

remove_networkmanager_hotspot_unmanaged_policy() {
  if [ -f "$NM_HOTSPOT_UNMANAGED_FILE" ]; then
    log "Removing NetworkManager unmanaged policy for hotspot interface ${WLAN_IFACE}."
    rm -f "$NM_HOTSPOT_UNMANAGED_FILE"
    rmdir "$NM_HOTSPOT_UNMANAGED_DIR" 2>/dev/null || true
  fi

  reload_networkmanager_policy
}

write_dhcpcd_hotspot_block() {
  local hotspot_ip="$1"

  log "Writing InitBox wlan0 hotspot block to ${DHCPCD_CONF}."

  if [ ! -f "$DHCPCD_CONF" ]; then
    touch "$DHCPCD_CONF"
    chmod 644 "$DHCPCD_CONF"
    chown root:root "$DHCPCD_CONF" || true
  fi

  remove_old_initbox_dhcpcd_blocks

  cat >>"$DHCPCD_CONF" <<DHCPCD_EOF

# START INITBOX-HOTSPOT
interface ${WLAN_IFACE}
    static ip_address=${hotspot_ip}/24
    nohook wpa_supplicant
    nohook resolv.conf
    nogateway
# END INITBOX-HOTSPOT
DHCPCD_EOF
}

write_hostapd_conf() {
  local ssid="$1"

  log "Writing ${HOSTAPD_CONF}."

  install -d -m 0755 /etc/hostapd

  cat >"$HOSTAPD_CONF" <<HOSTAPD_EOF
# initbox-hotspot
country_code=${COUNTRY_CODE}
interface=${WLAN_IFACE}
driver=nl80211
ssid=${ssid}
hw_mode=g
channel=1
wmm_enabled=0
macaddr_acl=0
auth_algs=1
ignore_broadcast_ssid=0
wpa=2
wpa_passphrase=${HOTSPOT_PASS}
wpa_key_mgmt=WPA-PSK
rsn_pairwise=CCMP
HOSTAPD_EOF

  chown root:root "$HOSTAPD_CONF"
  chmod 600 "$HOSTAPD_CONF"

  if [ -f "$HOSTAPD_DEFAULT" ]; then
    sed -i 's|^#\?DAEMON_CONF=.*|DAEMON_CONF="/etc/hostapd/hostapd.conf"|' "$HOSTAPD_DEFAULT" 2>/dev/null || true
  else
    printf '%s\n' 'DAEMON_CONF="/etc/hostapd/hostapd.conf"' >"$HOSTAPD_DEFAULT"
  fi
}


write_hostapd_overrides() {
  log "Writing hostapd systemd overrides."

  install -d -m 0755 "$HOSTAPD_OVERRIDE_DIR"

  cat >"$HOSTAPD_SERVICE_OVERRIDE" <<HOSTAPD_OVERRIDE_EOF
# InitBox hotspot service model. Managed by module-hotspot.sh.
[Service]
Type=simple
PIDFile=
ExecStart=
ExecStart=/usr/sbin/hostapd ${HOSTAPD_CONF}
Restart=on-failure
RestartSec=2
HOSTAPD_OVERRIDE_EOF

  chmod 644 "$HOSTAPD_SERVICE_OVERRIDE"
  chown root:root "$HOSTAPD_SERVICE_OVERRIDE" || true

  {
    printf '# InitBox hotspot hardening. Managed by module-hotspot.sh.\n'
    printf '[Service]\n'
    printf 'ExecStartPre=-/usr/sbin/rfkill unblock wifi\n'
    printf 'ExecStartPre=-/usr/sbin/ip link set %s up\n' "$WLAN_IFACE"
    printf 'ExecStartPre=-/usr/sbin/iw dev %s set power_save off\n' "$WLAN_IFACE"
  } >"$HOSTAPD_POWERSAVE_OVERRIDE"

  chmod 644 "$HOSTAPD_POWERSAVE_OVERRIDE"
  chown root:root "$HOSTAPD_POWERSAVE_OVERRIDE" || true
}

write_dnsmasq_conf() {
  local hotspot_ip="$1"
  local dhcp_range="$2"

  log "Writing ${DNSMASQ_CONF}."

  install -d -m 0755 "$DNSMASQ_DROPIN_DIR"

  cat >"$DNSMASQ_CONF" <<DNSMASQ_EOF
# initbox-hotspot - managed by module-hotspot.sh
# Clients need only reach the Pi (SSH + dashboard). No internet forwarding.
interface=${WLAN_IFACE}
listen-address=${hotspot_ip}
bind-dynamic
no-resolv
local-service

dhcp-range=${dhcp_range}
dhcp-option=3,${hotspot_ip}
dhcp-option=6,${hotspot_ip}
domain=${WLAN_IFACE}

# Local dashboard hostname
address=/initbox.wlan/${hotspot_ip}

# Captive portal catch-all for hotspot clients.
# local-service prevents this hotspot DNS from answering non-hotspot-side queries.
address=/#/${hotspot_ip}

# Android
address=/connectivitycheck.gstatic.com/${hotspot_ip}
address=/clients3.google.com/${hotspot_ip}

# Apple
address=/captive.apple.com/${hotspot_ip}
address=/www.apple.com/${hotspot_ip}

# Windows
address=/msftconnecttest.com/${hotspot_ip}
address=/www.msftconnecttest.com/${hotspot_ip}
address=/msftncsi.com/${hotspot_ip}
address=/www.msftncsi.com/${hotspot_ip}
address=/dns.msftncsi.com/${hotspot_ip}

# Firefox
address=/detectportal.firefox.com/${hotspot_ip}

# Generic
address=/neverssl.com/${hotspot_ip}
address=/www.neverssl.com/${hotspot_ip}
DNSMASQ_EOF

  chmod 644 "$DNSMASQ_CONF"
  chown root:root "$DNSMASQ_CONF" || true
}

write_dnsmasq_override() {
  log "Writing dnsmasq systemd override."

  install -d -m 0755 "$DNSMASQ_OVERRIDE_DIR"

  cat >"$DNSMASQ_HOTSPOT_OVERRIDE" <<DNSMASQ_OVERRIDE_EOF
# InitBox hotspot dependency. Managed by module-hotspot.sh.
[Unit]
After=${DHCPCD_SERVICE}
Wants=${DHCPCD_SERVICE}

[Service]
DNSMASQ_OVERRIDE_EOF

  chmod 644 "$DNSMASQ_HOTSPOT_OVERRIDE"
  chown root:root "$DNSMASQ_HOTSPOT_OVERRIDE" || true
}

disable_wifi_power_save_now() {
  if ! command -v iw >/dev/null 2>&1; then
    warn "iw command not found; cannot disable Wi-Fi power save now."
    return 0
  fi

  if ! ip link show "$WLAN_IFACE" >/dev/null 2>&1; then
    warn "Wi-Fi interface not found: ${WLAN_IFACE}; cannot disable power save now."
    return 0
  fi

  log "Disabling Wi-Fi power save immediately on ${WLAN_IFACE}."

  ip link set "$WLAN_IFACE" up 2>/dev/null || true

  if iw dev "$WLAN_IFACE" set power_save off 2>/dev/null; then
    ok "Wi-Fi power save disabled immediately on ${WLAN_IFACE}."
  else
    warn "Failed to disable Wi-Fi power save immediately on ${WLAN_IFACE}."
  fi
}

apply_hotspot_ip_now() {
  local hotspot_ip="$1"

  if ! ip link show "$WLAN_IFACE" >/dev/null 2>&1; then
    warn "Wi-Fi interface not found: ${WLAN_IFACE}; cannot apply hotspot IP now."
    return 0
  fi

  log "Applying hotspot IP directly on ${WLAN_IFACE}: ${hotspot_ip}/24."
  ip link set "$WLAN_IFACE" up 2>/dev/null || true
  ip addr replace "${hotspot_ip}/24" dev "$WLAN_IFACE" 2>/dev/null || true
}

wait_service_active() {
  local service_name="$1"
  local attempt=0
  local max_attempts=20
  local state=""

  while [ "$attempt" -lt "$max_attempts" ]; do
    if systemctl is-active --quiet "$service_name"; then
      ok "${service_name} is active."
      return 0
    fi

    state="$(systemctl is-active "$service_name" 2>/dev/null || true)"
    log "Waiting for ${service_name} to become active; current state=${state:-unknown} (${attempt}/${max_attempts})."
    attempt=$((attempt + 1))
    sleep 1
  done

  err "${service_name} did not become active."
  systemctl status "$service_name" --no-pager -l 2>&1 | tee -a "$LOGFILE" || true
  return 1
}

restart_service_checked() {
  local service_name="$1"

  log "Restarting ${service_name}."

  if systemctl restart "$service_name"; then
    wait_service_active "$service_name"
    return $?
  fi

  warn "${service_name} restart command failed. Trying start."

  if systemctl start "$service_name"; then
    wait_service_active "$service_name"
    return $?
  fi

  err "${service_name} failed to start."
  systemctl status "$service_name" --no-pager -l 2>&1 | tee -a "$LOGFILE" || true
  return 1
}

validate_eth0_was_not_modified() {
  log "Verifying ${UPSTREAM_IFACE} was not assigned a hotspot address."

  if [ -z "$HOTSPOT_SUBNET_PREFIX" ]; then
    warn "HOTSPOT_SUBNET_PREFIX is not set; skipping hotspot subnet validation for ${UPSTREAM_IFACE}."
    return 0
  fi

  if ip -4 addr show dev "$UPSTREAM_IFACE" 2>/dev/null | grep -q "${HOTSPOT_SUBNET_PREFIX//./\\.}\\."; then
    err "${UPSTREAM_IFACE} has a hotspot subnet address. This module refuses that state."
    ip -4 addr show dev "$UPSTREAM_IFACE" 2>&1 | tee -a "$LOGFILE" || true
    return 1
  fi

  ok "${UPSTREAM_IFACE} does not have a hotspot subnet address."
}

nudge_dhcpcd_interface() {
  if ! command -v dhcpcd >/dev/null 2>&1; then
    warn "dhcpcd command not found; relying on ${DHCPCD_SERVICE} only."
    return 0
  fi

  log "Requesting dhcpcd to reload ${WLAN_IFACE} configuration."

  if dhcpcd -n "$WLAN_IFACE" >/dev/null 2>&1; then
    return 0
  fi

  warn "dhcpcd reload for ${WLAN_IFACE} failed; trying direct interface start."
  dhcpcd "$WLAN_IFACE" >/dev/null 2>&1 || true
}

validate_hotspot_ip() {
  local hotspot_ip="$1"
  local assigned_ip=""
  local attempt=0
  local max_attempts=20

  while [ "$attempt" -lt "$max_attempts" ]; do
    assigned_ip="$(ip -4 addr show dev "$WLAN_IFACE" 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1 | head -n 1 || true)"

    if [ "$assigned_ip" = "$hotspot_ip" ]; then
      ok "${WLAN_IFACE} has hotspot IP ${hotspot_ip}."
      return 0
    fi

    attempt=$((attempt + 1))
    log "Waiting for ${WLAN_IFACE} hotspot IP ${hotspot_ip}; current=${assigned_ip:-none} (${attempt}/${max_attempts})."
    sleep 1
  done

  err "${WLAN_IFACE} does not have expected hotspot IP ${hotspot_ip}; current=${assigned_ip:-none}"
  return 1
}

start_hotspot_stack() {
  local hotspot_ip="$1"
  local failed=0

  log "Starting hotspot stack using ${DHCPCD_SERVICE}. ${UPSTREAM_IFACE} routes are not managed by this module."

  systemctl daemon-reload
  systemctl unmask hostapd 2>/dev/null || true
  systemctl enable "$DHCPCD_SERVICE" dnsmasq.service hostapd.service 2>/dev/null || true

  # Correct order:
  #   1. ask dhcpcd to reload only wlan0, without restarting global networking
  #   2. apply wlan0 hotspot IP directly as a safe immediate fallback
  #   3. verify wlan0 IP
  #   4. start hostapd
  #   5. test/start dnsmasq
  if ! systemctl is-active --quiet "$DHCPCD_SERVICE"; then
    systemctl start "$DHCPCD_SERVICE" 2>/dev/null || true
  fi

  nudge_dhcpcd_interface
  apply_hotspot_ip_now "$hotspot_ip"
  validate_hotspot_ip "$hotspot_ip" || failed=1

  rm -f "$HOSTAPD_PIDFILE" 2>/dev/null || true
  restart_service_checked hostapd.service || failed=1

  if dnsmasq --test 2>&1 | tee -a "$LOGFILE"; then
    ok "dnsmasq configuration test passed."
  else
    err "dnsmasq configuration test failed."
    failed=1
  fi

  restart_service_checked dnsmasq.service || failed=1

  validate_eth0_was_not_modified || failed=1

  if [ "$failed" -ne 0 ]; then
    write_hotspot_state "action_needed" "Hotspot stack failed" "1"
    err "Hotspot stack did not start cleanly."
    err "Check:"
    err "  sudo systemctl status ${DHCPCD_SERVICE} dnsmasq hostapd --no-pager -l"
    exit 1
  fi

  write_hotspot_state "ok" "Hotspot services active" "1"
}

install_module() {
  local boxno=""
  local ssid=""
  local hotspot_ip=""
  local dhcp_range=""

  require_root
  prepare_log
  prepare_state_dir

  log "Starting hotspot module installation."
  log "Upstream interface left untouched: ${UPSTREAM_IFACE}"
  log "Hotspot interface managed by this module through dhcpcd: ${WLAN_IFACE}"

  validate_hotspot_network_config
  resolve_hotspot_pass
  install_packages
  detect_dhcpcd_service

  boxno="$(get_boxno)"
  printf '%s\n' "$boxno" >"$BOXNO_FILE"
  chmod 644 "$BOXNO_FILE"

  ssid="initbox_${boxno}"
  hotspot_ip="${HOTSPOT_SUBNET_PREFIX}.${HOTSPOT_GATEWAY_OCTET}"
  dhcp_range="${HOTSPOT_SUBNET_PREFIX}.${HOTSPOT_DHCP_START},${HOTSPOT_SUBNET_PREFIX}.${HOTSPOT_DHCP_END},${HOTSPOT_DHCP_LEASE}"

  log "Hotspot SSID=${ssid}, gateway IP=${hotspot_ip}, DHCP range=${dhcp_range}"
  log "Static hotspot Wi-Fi password configured: TomatoH34d"

  cleanup_old_net_guard
  cleanup_old_hotspot_ip_service

  if ! wait_for_wlan_iface; then
    warn "Configuration was written, but services were not started because ${WLAN_IFACE} is missing."
    exit 0
  fi

  write_networkmanager_hotspot_unmanaged_policy
  write_dhcpcd_hotspot_block "$hotspot_ip"
  write_hostapd_conf "$ssid"
  write_hostapd_overrides
  write_dnsmasq_conf "$hotspot_ip" "$dhcp_range"
  write_dnsmasq_override

  disable_wifi_power_save_now
  start_hotspot_stack "$hotspot_ip"

  ok "Hotspot module installed."
  ok "Connect to SSID '${ssid}'."
  ok "Dashboard captive portal target: http://initbox.wlan/"
  ok "${UPSTREAM_IFACE} was not configured by this module."
}

uninstall_module() {
  require_root
  prepare_log
  prepare_state_dir

  log "Uninstalling hotspot module."

  systemctl stop hostapd.service 2>/dev/null || true
  systemctl disable hostapd.service 2>/dev/null || true

  systemctl stop dnsmasq.service 2>/dev/null || true
  systemctl disable dnsmasq.service 2>/dev/null || true

  cleanup_old_hotspot_ip_service
  cleanup_old_net_guard
  remove_networkmanager_hotspot_unmanaged_policy
  remove_old_initbox_dhcpcd_blocks

  rm -f "$DNSMASQ_CONF"
  rm -f "$DNSMASQ_HOTSPOT_OVERRIDE"
  rmdir "$DNSMASQ_OVERRIDE_DIR" 2>/dev/null || true

  rm -f "$HOSTAPD_CONF"
  rm -f "$HOSTAPD_SERVICE_OVERRIDE"
  rm -f "$HOSTAPD_POWERSAVE_OVERRIDE"
  rm -f "$HOSTAPD_PIDFILE" 2>/dev/null || true
  rmdir "$HOSTAPD_OVERRIDE_DIR" 2>/dev/null || true

  ip addr flush dev "$WLAN_IFACE" 2>/dev/null || true

  # Do not restart dhcpcd here. Restarting global DHCP can disturb eth0.
  # The wlan0 address was flushed above and persistence is handled by removing
  # the managed dhcpcd hotspot block.

  write_hotspot_state "removed" "Hotspot configuration removed" "0"

  systemctl daemon-reload

  ok "Hotspot configuration removed."
  warn "Installed packages were left in place intentionally."
  warn "BOX number file was left in place intentionally: ${BOXNO_FILE}"
  ok "${UPSTREAM_IFACE} was not restarted or reconfigured."
}

usage() {
  cat <<USAGE_EOF
Usage:
  sudo ./scripts/pi-3-4-5/module-hotspot.sh [install|uninstall|purge]

Actions:
  install    Install/update hotspot configuration
  uninstall  Disable/remove hotspot configuration created by this module
  purge      Compatibility alias for uninstall; packages are not removed

Package cache:
  This module uses:
    scripts/lib/packages.sh

  To prepare package cache in the lab:
    sudo ./scripts/initbox-installer.sh pi-3-4-5 p

Environment:
  STATIC_INITBOX_PASSWORD  WPA2 hotspot password. Default: TomatoH34d
                  Show current configured pass: sudo awk -F= '/^wpa_passphrase=/{print \$2}' /etc/hostapd/hostapd.conf
  WLAN_IFACE              Wireless interface. Default: wlan0
  UPSTREAM_IFACE          Upstream interface left untouched. Default: eth0
  COUNTRY_CODE            Wi-Fi country code. Default: AE
  HOTSPOT_SUBNET_PREFIX   Hotspot subnet prefix. Default: 192.168.30
  HOTSPOT_GATEWAY_OCTET   Gateway last octet. Default: 1
  HOTSPOT_DHCP_START      DHCP start last octet. Default: 10
  HOTSPOT_DHCP_END        DHCP end last octet. Default: 20
  HOTSPOT_DHCP_LEASE      DHCP lease time. Default: 24h
USAGE_EOF
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
