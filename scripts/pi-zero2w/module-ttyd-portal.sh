#!/usr/bin/env bash

# InitBox Pi Zero 2W Web Terminal and captive portal module
#
# Installs and enables:
#   - ttyd Web Terminal on port 7681
#   - captive portal redirect from wlan0:80 to ttyd:7681
#
# User-facing URLs:
#   http://initbox.wlan/
#   http://initbox.wlan:7681/
#
# This module assumes the hotspot module provides:
#   - hostapd access point
#   - wlan0 static hotspot IP
#   - DHCP service through dnsmasq
#   - wildcard captive DNS:
#       address=/#/<hotspot-ip>
#
# This module owns only:
#   - ttyd binary installation if missing
#   - ttyd service
#   - iptables redirect from port 80 to port 7681
#
# It must not replace or duplicate the hotspot module's DHCP, DNS,
# wlan0 IP, dnsmasq.conf, or hostapd ownership.

set -euo pipefail

MODULE_NAME="Web Terminal and Captive Portal"

OWNER="${OWNER:-initbox}"
PORTAL_HOSTNAME="${PORTAL_HOSTNAME:-initbox.wlan}"
TERMINAL_PORT="${TERMINAL_PORT:-7681}"
CAPTIVE_PORTAL_PORT="${CAPTIVE_PORTAL_PORT:-80}"
HOTSPOT_INTERFACE="${HOTSPOT_INTERFACE:-wlan0}"
TTYD_VERSION="${TTYD_VERSION:-1.7.7}"

TTYD_INSTALL_PATH="/usr/local/bin/ttyd"
TTYD_SERVICE_FILE="/etc/systemd/system/ttyd.service"
PORTAL_SCRIPT="/usr/local/bin/initbox-ttyd-portal.sh"
PORTAL_SERVICE_FILE="/etc/systemd/system/initbox-ttyd-portal.service"
OLD_CAPTIVE_SCRIPT="/usr/local/sbin/initbox-captive-portal.py"
OLD_CAPTIVE_SERVICE_FILE="/etc/systemd/system/initbox-captive-portal.service"

log() {
  printf '[%s] %s\n' "$MODULE_NAME" "$1"
}

fail() {
  log "ERROR: $1"
  exit 1
}

warn() {
  log "WARN: $1"
}

require_root() {
  if [ "$(id -u)" -ne 0 ]; then
    fail "this module must be run as root"
  fi
}

require_user() {
  if ! id "$OWNER" >/dev/null 2>&1; then
    fail "user '$OWNER' does not exist"
  fi
}

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

install_base_packages() {
  local packages=()

  if ! command_exists curl; then
    packages+=("curl")
  fi

  if ! command_exists update-ca-certificates; then
    packages+=("ca-certificates")
  fi

  if ! command_exists iptables; then
    packages+=("iptables")
  fi

  if [ "${#packages[@]}" -eq 0 ]; then
    log "base packages already installed"
    return 0
  fi

  log "installing base packages: ${packages[*]}"
  apt-get update
  apt-get install -y "${packages[@]}"
}

detect_ttyd_asset() {
  local machine=""

  machine="$(uname -m)"

  case "$machine" in
    aarch64|arm64)
      printf '%s\n' "ttyd.aarch64"
      ;;
    armv7l|armv6l)
      printf '%s\n' "ttyd.armhf"
      ;;
    arm*)
      printf '%s\n' "ttyd.arm"
      ;;
    x86_64|amd64)
      printf '%s\n' "ttyd.x86_64"
      ;;
    i386|i686)
      printf '%s\n' "ttyd.i686"
      ;;
    *)
      fail "unsupported CPU architecture for ttyd binary: $machine"
      ;;
  esac
}

install_ttyd_binary() {
  local ttyd_asset=""
  local ttyd_url=""
  local tmp_file=""

  ttyd_asset="$(detect_ttyd_asset)"
  ttyd_url="https://github.com/tsl0922/ttyd/releases/download/${TTYD_VERSION}/${ttyd_asset}"
  tmp_file="/tmp/${ttyd_asset}"

  log "ttyd not available locally; installing upstream binary"
  log "ttyd version: ${TTYD_VERSION}"
  log "ttyd asset: ${ttyd_asset}"

  curl -fL --retry 5 --retry-delay 3 "$ttyd_url" -o "$tmp_file"
  install -m 0755 "$tmp_file" "$TTYD_INSTALL_PATH"
  rm -f "$tmp_file"

  if ! "$TTYD_INSTALL_PATH" --version >/dev/null 2>&1; then
    fail "installed ttyd binary did not run successfully: $TTYD_INSTALL_PATH"
  fi

  log "installed ttyd at $TTYD_INSTALL_PATH"
}

install_packages() {
  install_base_packages

  if command_exists ttyd; then
    log "ttyd already installed at $(command -v ttyd)"
    return 0
  fi

  install_ttyd_binary
}

get_required_command_path() {
  local command_name="$1"
  local command_path=""

  command_path="$(command -v "$command_name" || true)"

  if [ -z "$command_path" ]; then
    fail "$command_name is not installed or not in PATH"
  fi

  if [ ! -x "$command_path" ]; then
    fail "$command_path exists but is not executable"
  fi

  printf '%s\n' "$command_path"
}

get_hotspot_ip() {
  local hotspot_ip=""

  hotspot_ip="$(
    ip -4 addr show "$HOTSPOT_INTERFACE" 2>/dev/null |
      awk '/inet / {print $2}' |
      cut -d/ -f1 |
      head -n 1
  )"

  if [ -z "$hotspot_ip" ]; then
    fail "could not detect IPv4 address on $HOTSPOT_INTERFACE. Run the hotspot module first."
  fi

  printf '%s\n' "$hotspot_ip"
}

check_hotspot_dns_owner() {
  local hotspot_ip="$1"

  if [ ! -f /etc/dnsmasq.conf ]; then
    fail "/etc/dnsmasq.conf does not exist. Run the hotspot module first."
  fi

  if ! grep -q "^address=/#/${hotspot_ip}$" /etc/dnsmasq.conf; then
    warn "wildcard captive DNS was not found in /etc/dnsmasq.conf"
    warn "expected: address=/#/${hotspot_ip}"
    warn "the hotspot may still work, but captive portal detection may not trigger"
  fi

  if ! grep -q "^dhcp-option=6,${hotspot_ip}$" /etc/dnsmasq.conf; then
    warn "DHCP DNS option was not found in /etc/dnsmasq.conf"
    warn "expected: dhcp-option=6,${hotspot_ip}"
    warn "clients must receive the Pi as DNS server for captive portal detection"
  fi
}

remove_old_web_terminal_dns_fragments() {
  log "removing old web-terminal dnsmasq fragments if present"

  rm -f /etc/dnsmasq.d/initbox-wlan.conf
  rm -f /etc/dnsmasq.d/initbox-captive-portal.conf
}

remove_old_python_captive_portal() {
  log "removing old Python captive portal service if present"

  systemctl disable --now initbox-captive-portal.service 2>/dev/null || true
  rm -f "$OLD_CAPTIVE_SERVICE_FILE"
  rm -f "$OLD_CAPTIVE_SCRIPT"
}

write_ttyd_service() {
  local ttyd_bin="$1"

  log "writing ttyd systemd service using $ttyd_bin"

  cat >"$TTYD_SERVICE_FILE" <<EOF
[Unit]
Description=InitBox Web Terminal
After=network.target
Wants=network.target

[Service]
Type=simple
User=$OWNER
Group=$OWNER
WorkingDirectory=/home/$OWNER
Environment=HOME=/home/$OWNER
Environment=USER=$OWNER
ExecStart=$ttyd_bin -W --interface 0.0.0.0 --port $TERMINAL_PORT /bin/bash -l
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF
}

write_portal_redirect_script() {
  log "writing portal redirect script"

  cat >"$PORTAL_SCRIPT" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

IFACE="${HOTSPOT_INTERFACE:-wlan0}"
FROM_PORT="${CAPTIVE_PORTAL_PORT:-80}"
TO_PORT="${TERMINAL_PORT:-7681}"

if ! iptables -t nat -C PREROUTING -i "$IFACE" -p tcp --dport "$FROM_PORT" \
  -j REDIRECT --to-ports "$TO_PORT" 2>/dev/null; then
  iptables -t nat -A PREROUTING -i "$IFACE" -p tcp --dport "$FROM_PORT" \
    -j REDIRECT --to-ports "$TO_PORT"
fi
EOF

  chmod 755 "$PORTAL_SCRIPT"
  chown root:root "$PORTAL_SCRIPT" 2>/dev/null || true
}

write_portal_redirect_service() {
  log "writing portal redirect systemd service"

  cat >"$PORTAL_SERVICE_FILE" <<EOF
[Unit]
Description=InitBox captive portal redirect (${CAPTIVE_PORTAL_PORT} -> ${TERMINAL_PORT})
After=network.target hostapd.service dnsmasq.service ttyd.service
Wants=hostapd.service dnsmasq.service ttyd.service

[Service]
Type=oneshot
Environment=HOTSPOT_INTERFACE=$HOTSPOT_INTERFACE
Environment=CAPTIVE_PORTAL_PORT=$CAPTIVE_PORTAL_PORT
Environment=TERMINAL_PORT=$TERMINAL_PORT
ExecStart=$PORTAL_SCRIPT
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
}

restart_services() {
  log "reloading systemd"
  systemctl daemon-reload

  if systemctl list-unit-files dnsmasq.service >/dev/null 2>&1; then
    log "testing dnsmasq configuration"
    dnsmasq --test

    log "restarting dnsmasq after removing old fragments"
    systemctl restart dnsmasq.service
  else
    fail "dnsmasq service not found. Run the hotspot module first."
  fi

  log "enabling ttyd"
  systemctl enable --now ttyd.service
  systemctl restart ttyd.service

  log "enabling portal redirect"
  systemctl enable --now initbox-ttyd-portal.service
  systemctl restart initbox-ttyd-portal.service
}

print_summary() {
  local hotspot_ip="$1"

  echo
  echo "Web Terminal and captive portal redirect installed"
  echo "--------------------------------------------------"
  echo "Captive portal URL: http://$PORTAL_HOSTNAME/"
  echo "Web Terminal URL:   http://$PORTAL_HOSTNAME:$TERMINAL_PORT/"
  echo "Hotspot IP:         $hotspot_ip"
  echo
  echo "Expected behavior:"
  echo "  - http://$PORTAL_HOSTNAME/ redirects at iptables level to ttyd on port $TERMINAL_PORT"
  echo "  - http://$PORTAL_HOSTNAME:$TERMINAL_PORT/ opens ttyd directly"
  echo "  - ttyd login user: $OWNER"
  echo "  - ttyd keyboard input: enabled by -W"
  echo
  echo "DNS ownership:"
  echo "  - Hotspot module owns /etc/dnsmasq.conf"
  echo "  - Web terminal module does not write dnsmasq captive DNS"
  echo "  - Expected wildcard rule: address=/#/$hotspot_ip"
  echo
  echo "Check services:"
  echo "  sudo systemctl status hostapd dnsmasq ttyd initbox-ttyd-portal --no-pager"
  echo
  echo "Check ports and redirect:"
  echo "  sudo ss -tulpn | grep -E ':53|:67|:$TERMINAL_PORT'"
  echo "  sudo iptables -t nat -S PREROUTING"
  echo
  echo "Manual tests:"
  echo "  curl -I http://127.0.0.1:$TERMINAL_PORT/"
  echo "  curl -I http://$PORTAL_HOSTNAME:$TERMINAL_PORT/"
  echo "  From a Wi-Fi client: open http://$PORTAL_HOSTNAME/"
}

main() {
  local hotspot_ip=""
  local ttyd_bin=""

  require_root
  require_user
  install_packages

  ttyd_bin="$(get_required_command_path ttyd)"
  hotspot_ip="$(get_hotspot_ip)"

  check_hotspot_dns_owner "$hotspot_ip"
  remove_old_web_terminal_dns_fragments
  remove_old_python_captive_portal
  write_ttyd_service "$ttyd_bin"
  write_portal_redirect_script
  write_portal_redirect_service
  restart_services
  print_summary "$hotspot_ip"
}

main "$@"
