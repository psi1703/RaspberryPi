#!/usr/bin/env bash
# InitBox Pi Zero W / Zero 2W Web Terminal and captive portal module
#
# Actions:
#   install    Install and enable ttyd plus captive portal socket responder.
#   uninstall  Remove services and files created by this module.
#   remove     Alias for uninstall.
#   purge      Compatibility alias for uninstall. It does not remove packages,
#              cached .deb files, or the cached ttyd binary.
#
# Installs and enables:
#   - ttyd Web Terminal on port 7681
#   - systemd socket-activated captive HTTP responder on port 80
#
# User-facing URLs:
#   http://initbox.wlan/
#   http://initbox.wlan:7681/
#   http://192.168.20.1/
#   http://192.168.20.1:7681/
#
# Policy:
#   - This module does not edit hotspot DHCP/DNS/hostapd config.
#   - Hotspot module owns /etc/dnsmasq.conf and /etc/hostapd/hostapd.conf.
#   - This module owns only its systemd service files and responder script.
#   - No Python captive portal.
#   - No iptables redirect service.
#   - No dnsmasq drop-ins.
#   - No systemd drop-ins.

set -euo pipefail

ACTION="${1:-install}"

: "${OWNER:=initbox}"
: "${PORTAL_HOSTNAME:=initbox.wlan}"
: "${TERMINAL_PORT:=7681}"
: "${CAPTIVE_PORTAL_PORT:=80}"
: "${HOTSPOT_INTERFACE:=wlan0}"
: "${TTYD_VERSION:=1.7.7}"
: "${LOGFILE:=/home/${OWNER}/pi_logs/initbox-install.log}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${INITBOX_REPO_ROOT:-$(cd "$SCRIPT_DIR/../.." && pwd)}"

INITBOX_PACKAGES_FILE="${INITBOX_PACKAGES_FILE:-$REPO_ROOT/scripts/packages.txt}"
INITBOX_PACKAGE_CACHE_DIR="${INITBOX_PACKAGE_CACHE_DIR:-/opt/initbox/packages}"
PACKAGES_LIB_FILE="$REPO_ROOT/scripts/lib/packages.sh"

TTYD_INSTALL_PATH="/usr/local/bin/ttyd"
TTYD_CACHE_DIR="$INITBOX_PACKAGE_CACHE_DIR/ttyd"
TTYD_SERVICE_FILE="/etc/systemd/system/ttyd.service"

CAPTIVE_RESPONDER="/usr/local/sbin/initbox-captive-responder.sh"
CAPTIVE_SOCKET_FILE="/etc/systemd/system/initbox-captive-http.socket"
CAPTIVE_SERVICE_FILE="/etc/systemd/system/initbox-captive-http@.service"

OLD_PORTAL_SCRIPT="/usr/local/bin/initbox-ttyd-portal.sh"
OLD_PORTAL_SERVICE_FILE="/etc/systemd/system/initbox-ttyd-portal.service"
OLD_CAPTIVE_SCRIPT="/usr/local/sbin/initbox-captive-portal.py"
OLD_CAPTIVE_SERVICE_FILE="/etc/systemd/system/initbox-captive-portal.service"

ts() {
  date '+%Y-%m-%d %H:%M:%S'
}

log() {
  echo "[TTYD $(ts)] $*" | tee -a "$LOGFILE"
}

ok() {
  echo "[TTYD $(ts)] [OK] $*" | tee -a "$LOGFILE"
}

warn() {
  echo "[TTYD $(ts)] [WARN] $*" | tee -a "$LOGFILE" >&2
}

err() {
  echo "[TTYD $(ts)] [ERR] $*" | tee -a "$LOGFILE" >&2
}

fail() {
  err "$*"
  exit 1
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
    fail "package helper missing: $PACKAGES_LIB_FILE"
  fi

  # shellcheck disable=SC1090
  . "$PACKAGES_LIB_FILE"

  if ! declare -F initbox_packages_install >/dev/null 2>&1; then
    fail "package helper does not define initbox_packages_install"
  fi
}

install_base_packages_from_cache() {
  log "Installing required Debian packages from InitBox package cache"
  log "packages file: $INITBOX_PACKAGES_FILE"
  log "cache dir:     $INITBOX_PACKAGE_CACHE_DIR"

  load_package_helper

  initbox_packages_install \
    "$INITBOX_PACKAGES_FILE" \
    "$INITBOX_PACKAGE_CACHE_DIR" \
    curl \
    ca-certificates
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

get_cached_ttyd_path() {
  local ttyd_asset="$1"

  printf '%s\n' "$TTYD_CACHE_DIR/${TTYD_VERSION}-${ttyd_asset}"
}

download_ttyd_to_cache() {
  local ttyd_asset="$1"
  local cached_ttyd="$2"
  local ttyd_url=""
  local tmp_file=""

  if ! command_exists curl; then
    fail "curl is not installed. Prepare package cache first, then rerun this module."
  fi

  ttyd_url="https://github.com/tsl0922/ttyd/releases/download/${TTYD_VERSION}/${ttyd_asset}"
  tmp_file="${cached_ttyd}.tmp"

  install -d -m 0755 "$TTYD_CACHE_DIR"

  log "Cached ttyd binary not found; downloading once and keeping it."
  log "ttyd version: ${TTYD_VERSION}"
  log "ttyd asset:   ${ttyd_asset}"
  log "cache path:   ${cached_ttyd}"

  if ! curl -fL --retry 5 --retry-delay 3 "$ttyd_url" -o "$tmp_file"; then
    rm -f "$tmp_file"
    fail "failed to download ttyd binary. Run this module once in lab with Internet, or place the cached ttyd binary at: $cached_ttyd"
  fi

  chmod 0755 "$tmp_file"
  mv -f "$tmp_file" "$cached_ttyd"
}

install_ttyd_from_cache() {
  local ttyd_asset=""
  local cached_ttyd=""

  ttyd_asset="$(detect_ttyd_asset)"
  cached_ttyd="$(get_cached_ttyd_path "$ttyd_asset")"

  if [ ! -f "$cached_ttyd" ]; then
    download_ttyd_to_cache "$ttyd_asset" "$cached_ttyd"
  else
    log "Using cached ttyd binary: $cached_ttyd"
  fi

  if [ ! -x "$cached_ttyd" ]; then
    chmod 0755 "$cached_ttyd"
  fi

  install -m 0755 "$cached_ttyd" "$TTYD_INSTALL_PATH"

  if ! "$TTYD_INSTALL_PATH" --version >/dev/null 2>&1; then
    fail "installed ttyd binary did not run successfully: $TTYD_INSTALL_PATH"
  fi

  log "Installed ttyd at $TTYD_INSTALL_PATH"
}

install_packages() {
  install_base_packages_from_cache

  if command_exists ttyd; then
    log "ttyd already installed at $(command -v ttyd)"
    return 0
  fi

  if [ -x "$TTYD_INSTALL_PATH" ]; then
    log "ttyd already installed at $TTYD_INSTALL_PATH"
    return 0
  fi

  install_ttyd_from_cache
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
  log "Removing old Web Terminal dnsmasq fragments, if present"

  rm -f /etc/dnsmasq.d/initbox-wlan.conf
  rm -f /etc/dnsmasq.d/initbox-captive-portal.conf
  rm -f /etc/dnsmasq.d/initbox-hotspot.conf
}

remove_old_portal_services() {
  log "Removing old captive portal services and scripts, if present"

  systemctl disable --now initbox-captive-portal.service 2>/dev/null || true
  systemctl disable --now initbox-ttyd-portal.service 2>/dev/null || true

  rm -f "$OLD_CAPTIVE_SERVICE_FILE"
  rm -f "$OLD_CAPTIVE_SCRIPT"
  rm -f "$OLD_PORTAL_SERVICE_FILE"
  rm -f "$OLD_PORTAL_SCRIPT"
}

remove_old_portal_redirect_rule() {
  log "Removing old wlan0 port 80 to 7681 redirect rule, if present"

  if ! command_exists iptables; then
    return 0
  fi

  while iptables -t nat -C PREROUTING -i "$HOTSPOT_INTERFACE" -p tcp --dport 80 \
    -j REDIRECT --to-ports "$TERMINAL_PORT" 2>/dev/null; do
    iptables -t nat -D PREROUTING -i "$HOTSPOT_INTERFACE" -p tcp --dport 80 \
      -j REDIRECT --to-ports "$TERMINAL_PORT"
  done

  while iptables -t nat -C PREROUTING -i "$HOTSPOT_INTERFACE" -p tcp --dport 80 \
    -j REDIRECT --to-ports 7681 2>/dev/null; do
    iptables -t nat -D PREROUTING -i "$HOTSPOT_INTERFACE" -p tcp --dport 80 \
      -j REDIRECT --to-ports 7681
  done
}

reset_captive_failed_units() {
  log "Resetting old captive HTTP failed instances, if present"

  systemctl reset-failed 'initbox-captive-http@*.service' 2>/dev/null || true
  systemctl reset-failed 2>/dev/null || true
}

write_ttyd_service() {
  local ttyd_bin="$1"

  log "Writing ttyd systemd service using $ttyd_bin on port $TERMINAL_PORT"

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
  log "Writing same-host captive HTTP responder"

  cat >"$CAPTIVE_RESPONDER" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail

TERMINAL_PORT="${INITBOX_TERMINAL_PORT:-7681}"
DEFAULT_HOST="${INITBOX_DEFAULT_HOST:-initbox.wlan}"
REQUEST_LINE=""
HEADER_LINE=""
HOST_HEADER=""
REDIRECT_HOST=""
LOCATION=""
BODY="InitBox captive portal redirect"

trap 'exit 0' PIPE

trim_spaces() {
  local value="$1"

  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"

  printf '%s\n' "$value"
}

send_response() {
  printf 'HTTP/1.1 302 Found\r\n'
  printf 'Location: %s\r\n' "$LOCATION"
  printf 'Content-Type: text/plain; charset=utf-8\r\n'
  printf 'Content-Length: %s\r\n' "${#BODY}"
  printf 'Cache-Control: no-store, no-cache, must-revalidate, max-age=0\r\n'
  printf 'Pragma: no-cache\r\n'
  printf 'Connection: close\r\n'
  printf '\r\n'
  printf '%s\n' "$BODY"
}

read -r REQUEST_LINE || true
REQUEST_LINE="${REQUEST_LINE%$'\r'}"

while IFS= read -r HEADER_LINE; do
  HEADER_LINE="${HEADER_LINE%$'\r'}"

  if [ -z "$HEADER_LINE" ]; then
    break
  fi

  case "$HEADER_LINE" in
    [Hh][Oo][Ss][Tt]:*)
      HOST_HEADER="${HEADER_LINE#*:}"
      ;;
  esac
done

HOST_HEADER="$(trim_spaces "$HOST_HEADER")"

if [ -n "$HOST_HEADER" ]; then
  REDIRECT_HOST="${HOST_HEADER%%:*}"
else
  REDIRECT_HOST="$DEFAULT_HOST"
fi

if [ -z "$REDIRECT_HOST" ]; then
  REDIRECT_HOST="$DEFAULT_HOST"
fi

LOCATION="http://${REDIRECT_HOST}:${TERMINAL_PORT}/"

send_response || true
exit 0
EOF

  chmod 0755 "$CAPTIVE_RESPONDER"
  chown root:root "$CAPTIVE_RESPONDER" 2>/dev/null || true
}

write_captive_socket_units() {
  log "Writing captive portal socket unit on port $CAPTIVE_PORTAL_PORT"

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

  log "Writing captive portal per-connection service"

  cat >"$CAPTIVE_SERVICE_FILE" <<EOF
[Unit]
Description=InitBox captive portal HTTP responder

[Service]
Type=simple
User=$OWNER
Group=$OWNER
Environment=INITBOX_TERMINAL_PORT=$TERMINAL_PORT
Environment=INITBOX_DEFAULT_HOST=$PORTAL_HOSTNAME
ExecStart=-$CAPTIVE_RESPONDER
StandardInput=socket
StandardOutput=socket
StandardError=journal
SuccessExitStatus=0 1 141 SIGPIPE
EOF
}

restart_services() {
  log "Reloading systemd"
  systemctl daemon-reload

  if systemctl list-unit-files dnsmasq.service >/dev/null 2>&1; then
    log "Testing dnsmasq configuration"
    dnsmasq --test

    log "Restarting dnsmasq after removing old fragments"
    systemctl restart dnsmasq.service
  else
    fail "dnsmasq service not found. Run the hotspot module first."
  fi

  log "Enabling ttyd"
  systemctl enable --now ttyd.service
  systemctl restart ttyd.service

  log "Enabling captive HTTP socket"
  systemctl enable --now initbox-captive-http.socket
  systemctl restart initbox-captive-http.socket

  reset_captive_failed_units
}

stop_and_disable_unit() {
  local unit_name="$1"

  log "Stopping and disabling $unit_name, if present"
  systemctl disable --now "$unit_name" 2>/dev/null || true
  systemctl reset-failed "$unit_name" 2>/dev/null || true
}

remove_module_services() {
  log "Removing Web Terminal and captive portal services"

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

print_install_summary() {
  local hotspot_ip="$1"
  local ttyd_asset=""
  local cached_ttyd=""

  ttyd_asset="$(detect_ttyd_asset)"
  cached_ttyd="$(get_cached_ttyd_path "$ttyd_asset")"

  echo
  echo "Web Terminal and captive portal installed"
  echo "----------------------------------------"
  echo "Captive portal URL: http://$PORTAL_HOSTNAME/"
  echo "Web Terminal URL:   http://$PORTAL_HOSTNAME:$TERMINAL_PORT/"
  echo "Hotspot IP URL:     http://$hotspot_ip/"
  echo "Hotspot terminal:   http://$hotspot_ip:$TERMINAL_PORT/"
  echo "Hotspot IP:         $hotspot_ip"
  echo "ttyd binary:        $TTYD_INSTALL_PATH"
  echo "ttyd cache:         $cached_ttyd"
  echo
  echo "Expected behavior:"
  echo "  - port 80 is handled by systemd socket activation"
  echo "  - port 80 replies with HTTP 302 to the same host on port $TERMINAL_PORT"
  echo "  - closed or impatient captive-check clients do not pollute systemctl --failed"
  echo "  - http://$hotspot_ip/ redirects to http://$hotspot_ip:$TERMINAL_PORT/"
  echo "  - http://$PORTAL_HOSTNAME/ redirects to http://$PORTAL_HOSTNAME:$TERMINAL_PORT/"
  echo "  - ttyd runs on port $TERMINAL_PORT"
  echo "  - ttyd login user: $OWNER"
  echo "  - ttyd keyboard input is enabled by -W"
  echo "  - no Python captive portal"
  echo "  - no extra web server package"
  echo "  - no iptables redirect service"
  echo "  - no dnsmasq drop-ins"
  echo "  - no systemd drop-ins"
  echo
  echo "Offline field-mode behavior:"
  echo "  - Debian packages are installed from $INITBOX_PACKAGE_CACHE_DIR"
  echo "  - ttyd is cached and reused from $TTYD_CACHE_DIR"
  echo "  - uninstall does not remove shared packages or cached files"
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
  echo "  curl -I -H 'Host: $hotspot_ip' http://127.0.0.1/"
  echo "  curl -I -H 'Host: $PORTAL_HOSTNAME' http://127.0.0.1/"
  echo "  curl -I http://127.0.0.1:$TERMINAL_PORT/"
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
  echo "  - old Python captive portal service/script, if present"
  echo "  - old ttyd portal service/script, if present"
  echo "  - old iptables redirect rule, if present"
  echo
  echo "Not removed:"
  echo "  - hotspot service"
  echo "  - dnsmasq hotspot configuration"
  echo "  - hostapd hotspot configuration"
  echo "  - ttyd binary at $TTYD_INSTALL_PATH"
  echo "  - cached ttyd files under $TTYD_CACHE_DIR"
  echo "  - cached Debian packages under $INITBOX_PACKAGE_CACHE_DIR"
  echo
  echo "Check:"
  echo "  sudo systemctl status ttyd initbox-captive-http.socket --no-pager"
  echo "  sudo ss -tulpn | grep -E ':80|:$TERMINAL_PORT'"
}

install_main() {
  local hotspot_ip=""
  local ttyd_bin=""

  require_root
  ensure_log_dir
  require_user
  install_packages

  ttyd_bin="$(get_required_command_path ttyd)"
  hotspot_ip="$(get_hotspot_ip)"

  check_hotspot_dns_owner "$hotspot_ip"
  remove_old_web_terminal_dns_fragments
  remove_old_portal_services
  remove_old_portal_redirect_rule
  reset_captive_failed_units
  write_ttyd_service "$ttyd_bin"
  write_captive_responder_script
  write_captive_socket_units
  restart_services
  print_install_summary "$hotspot_ip"

  ok "Web Terminal and captive portal module installed."
}

uninstall_main() {
  require_root
  ensure_log_dir

  remove_module_services
  print_uninstall_summary

  ok "Web Terminal and captive portal module uninstalled."
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
      fail "unknown action '$ACTION'. Use install or uninstall."
      ;;
  esac
}

main "$@"
