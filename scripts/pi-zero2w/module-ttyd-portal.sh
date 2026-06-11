#!/usr/bin/env bash

# InitBox Pi Zero 2W Web Terminal and captive portal module
#
# Actions:
#   install   Install and enable ttyd plus captive portal socket responder.
#   uninstall Remove services and files created by this module.
#   purge     Uninstall and also remove /usr/local/bin/ttyd.
#
# Default action:
#   install
#
# Installs and enables:
#   - ttyd Web Terminal on port 7681
#   - systemd socket-activated captive HTTP responder on port 80
#
# User-facing URLs:
#   http://initbox.wlan/
#   http://initbox.wlan:7681/
#
# Captive portal behavior:
#   - dnsmasq wildcard DNS from the hotspot module sends captive-check
#     domains to the Pi hotspot IP.
#   - systemd listens on port 80.
#   - each HTTP request receives a lightweight 302 redirect to ttyd.
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
#   - ttyd.service on port 7681
#   - socket-activated port-80 captive responder
#
# It must not replace or duplicate the hotspot module's DHCP, DNS,
# wlan0 IP, dnsmasq.conf, hostapd ownership, or captive DNS.

set -euo pipefail

MODULE_NAME="Web Terminal and Captive Portal"

ACTION="${1:-install}"

OWNER="${OWNER:-initbox}"
PORTAL_HOSTNAME="${PORTAL_HOSTNAME:-initbox.wlan}"
TERMINAL_PORT="${TERMINAL_PORT:-7681}"
CAPTIVE_PORTAL_PORT="${CAPTIVE_PORTAL_PORT:-80}"
HOTSPOT_INTERFACE="${HOTSPOT_INTERFACE:-wlan0}"
TTYD_VERSION="${TTYD_VERSION:-1.7.7}"

TTYD_INSTALL_PATH="/usr/local/bin/ttyd"
TTYD_SERVICE_FILE="/etc/systemd/system/ttyd.service"

CAPTIVE_RESPONDER="/usr/local/sbin/initbox-captive-responder.sh"
CAPTIVE_SOCKET_FILE="/etc/systemd/system/initbox-captive-http.socket"
CAPTIVE_SERVICE_FILE="/etc/systemd/system/initbox-captive-http@.service"

OLD_PORTAL_SCRIPT="/usr/local/bin/initbox-ttyd-portal.sh"
OLD_PORTAL_SERVICE_FILE="/etc/systemd/system/initbox-ttyd-portal.service"
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
    warn "captive portal detection may not trigger"
  fi

  if ! grep -q "^dhcp-option=6,${hotspot_ip}$" /etc/dnsmasq.conf; then
    warn "DHCP DNS option was not found in /etc/dnsmasq.conf"
    warn "expected: dhcp-option=6,${hotspot_ip}"
  fi
}

remove_old_web_terminal_dns_fragments() {
  log "removing old web-terminal dnsmasq fragments if present"

  rm -f /etc/dnsmasq.d/initbox-wlan.conf
  rm -f /etc/dnsmasq.d/initbox-captive-portal.conf
}

remove_old_portal_services() {
  log "removing old captive portal services and scripts if present"

  systemctl disable --now initbox-captive-portal.service 2>/dev/null || true
  systemctl disable --now initbox-ttyd-portal.service 2>/dev/null || true

  rm -f "$OLD_CAPTIVE_SERVICE_FILE"
  rm -f "$OLD_CAPTIVE_SCRIPT"
  rm -f "$OLD_PORTAL_SERVICE_FILE"
  rm -f "$OLD_PORTAL_SCRIPT"
}

remove_old_portal_redirect_rule() {
  log "removing old wlan0 port 80 to 7681 redirect rule if present"

  if ! command_exists iptables; then
    return 0
  fi

  while iptables -t nat -C PREROUTING -i "$HOTSPOT_INTERFACE" -p tcp --dport 80 \
    -j REDIRECT --to-ports 7681 2>/dev/null; do
    iptables -t nat -D PREROUTING -i "$HOTSPOT_INTERFACE" -p tcp --dport 80 \
      -j REDIRECT --to-ports 7681
  done
}

write_ttyd_service() {
  local ttyd_bin="$1"

  log "writing ttyd systemd service using $ttyd_bin on port $TERMINAL_PORT"

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

write_captive_responder_script() {
  log "writing socket-activated captive HTTP responder"

  cat >"$CAPTIVE_RESPONDER" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

PORTAL_URL="${INITBOX_TERMINAL_URL:-http://initbox.wlan:7681/}"
BODY="InitBox captive portal redirect"

printf 'HTTP/1.1 302 Found\r\n'
printf 'Location: %s\r\n' "$PORTAL_URL"
printf 'Content-Type: text/plain; charset=utf-8\r\n'
printf 'Content-Length: %s\r\n' "${#BODY}"
printf 'Cache-Control: no-store, no-cache, must-revalidate, max-age=0\r\n'
printf 'Pragma: no-cache\r\n'
printf 'Connection: close\r\n'
printf '\r\n'
printf '%s\n' "$BODY"
EOF

  chmod 755 "$CAPTIVE_RESPONDER"
  chown root:root "$CAPTIVE_RESPONDER" 2>/dev/null || true
}

write_captive_socket_units() {
  local terminal_url=""

  terminal_url="http://${PORTAL_HOSTNAME}:${TERMINAL_PORT}/"

  log "writing captive portal socket unit on port $CAPTIVE_PORTAL_PORT"

  cat >"$CAPTIVE_SOCKET_FILE" <<EOF
[Unit]
Description=InitBox captive portal HTTP socket

[Socket]
ListenStream=0.0.0.0:$CAPTIVE_PORTAL_PORT
Accept=yes
NoDelay=true

[Install]
WantedBy=sockets.target
EOF

  log "writing captive portal per-connection service"

  cat >"$CAPTIVE_SERVICE_FILE" <<EOF
[Unit]
Description=InitBox captive portal HTTP responder

[Service]
Type=simple
User=$OWNER
Group=$OWNER
Environment=INITBOX_TERMINAL_URL=$terminal_url
ExecStart=$CAPTIVE_RESPONDER
StandardInput=socket
StandardOutput=socket
StandardError=journal
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

  log "enabling captive HTTP socket"
  systemctl enable --now initbox-captive-http.socket
  systemctl restart initbox-captive-http.socket
}

stop_and_disable_unit() {
  local unit_name="$1"

  log "stopping and disabling $unit_name if present"
  systemctl disable --now "$unit_name" 2>/dev/null || true
  systemctl reset-failed "$unit_name" 2>/dev/null || true
}

remove_module_services() {
  log "removing Web Terminal and captive portal services"

  stop_and_disable_unit "initbox-captive-http.socket"
  stop_and_disable_unit "ttyd.service"
  stop_and_disable_unit "initbox-captive-portal.service"
  stop_and_disable_unit "initbox-ttyd-portal.service"

  systemctl stop 'initbox-captive-http@*.service' 2>/dev/null || true
  systemctl reset-failed 'initbox-captive-http@*.service' 2>/dev/null || true

  rm -f "$CAPTIVE_SOCKET_FILE"
  rm -f "$CAPTIVE_SERVICE_FILE"
  rm -f "$CAPTIVE_RESPONDER"

  rm -f "$TTYD_SERVICE_FILE"

  rm -f "$OLD_CAPTIVE_SERVICE_FILE"
  rm -f "$OLD_CAPTIVE_SCRIPT"
  rm -f "$OLD_PORTAL_SERVICE_FILE"
  rm -f "$OLD_PORTAL_SCRIPT"

  remove_old_web_terminal_dns_fragments
  remove_old_portal_redirect_rule

  systemctl daemon-reload
  systemctl reset-failed 2>/dev/null || true
}

purge_ttyd_binary() {
  if [ -f "$TTYD_INSTALL_PATH" ]; then
    log "removing ttyd binary: $TTYD_INSTALL_PATH"
    rm -f "$TTYD_INSTALL_PATH"
  else
    log "ttyd binary not found at $TTYD_INSTALL_PATH"
  fi
}

print_install_summary() {
  local hotspot_ip="$1"

  echo
  echo "Web Terminal and captive portal installed"
  echo "----------------------------------------"
  echo "Captive portal URL: http://$PORTAL_HOSTNAME/"
  echo "Web Terminal URL:   http://$PORTAL_HOSTNAME:$TERMINAL_PORT/"
  echo "Hotspot IP:         $hotspot_ip"
  echo
  echo "Expected behavior:"
  echo "  - port 80 is handled by systemd socket activation"
  echo "  - port 80 replies with HTTP 302 to $PORTAL_HOSTNAME:$TERMINAL_PORT"
  echo "  - ttyd runs on port $TERMINAL_PORT"
  echo "  - ttyd login user: $OWNER"
  echo "  - ttyd keyboard input: enabled by -W"
  echo "  - no Python captive portal"
  echo "  - no extra web server package"
  echo "  - no iptables redirect service"
  echo
  echo "DNS ownership:"
  echo "  - Hotspot module owns /etc/dnsmasq.conf"
  echo "  - Expected wildcard rule: address=/#/$hotspot_ip"
  echo
  echo "Check services:"
  echo "  sudo systemctl status hostapd dnsmasq ttyd initbox-captive-http.socket --no-pager"
  echo
  echo "Check ports:"
  echo "  sudo ss -tulpn | grep -E ':80|:$TERMINAL_PORT'"
  echo
  echo "Manual tests:"
  echo "  curl -I http://127.0.0.1/"
  echo "  curl -I http://127.0.0.1:$TERMINAL_PORT/"
  echo "  From a Wi-Fi client: open http://$PORTAL_HOSTNAME/"
}

print_uninstall_summary() {
  echo
  echo "Web Terminal and captive portal uninstalled"
  echo "------------------------------------------"
  echo "Removed:"
  echo "  - ttyd.service"
  echo "  - initbox-captive-http.socket"
  echo "  - initbox-captive-http@.service"
  echo "  - $CAPTIVE_RESPONDER"
  echo
  echo "Not removed:"
  echo "  - hotspot service"
  echo "  - dnsmasq hotspot configuration"
  echo "  - hostapd hotspot configuration"
  echo "  - ttyd binary at $TTYD_INSTALL_PATH"
  echo
  echo "Check:"
  echo "  sudo systemctl status ttyd initbox-captive-http.socket --no-pager"
  echo "  sudo ss -tulpn | grep -E ':80|:$TERMINAL_PORT'"
}

print_purge_summary() {
  echo
  echo "Web Terminal and captive portal purged"
  echo "-------------------------------------"
  echo "Removed services and files created by this module."
  echo "Also removed:"
  echo "  - $TTYD_INSTALL_PATH"
  echo
  echo "Not removed:"
  echo "  - hotspot service"
  echo "  - dnsmasq hotspot configuration"
  echo "  - hostapd hotspot configuration"
}

install_main() {
  local hotspot_ip=""
  local ttyd_bin=""

  require_root
  require_user
  install_packages

  ttyd_bin="$(get_required_command_path ttyd)"
  hotspot_ip="$(get_hotspot_ip)"

  check_hotspot_dns_owner "$hotspot_ip"
  remove_old_web_terminal_dns_fragments
  remove_old_portal_services
  remove_old_portal_redirect_rule
  write_ttyd_service "$ttyd_bin"
  write_captive_responder_script
  write_captive_socket_units
  restart_services
  print_install_summary "$hotspot_ip"
}

uninstall_main() {
  require_root

  remove_module_services
  print_uninstall_summary
}

purge_main() {
  require_root

  remove_module_services
  purge_ttyd_binary
  print_purge_summary
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
      purge_main
      ;;
    *)
      fail "unknown action '$ACTION'. Use install, uninstall, or purge."
      ;;
  esac
}

main "$@"
