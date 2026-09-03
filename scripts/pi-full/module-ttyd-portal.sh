#!/usr/bin/env bash
# InitBox Raspberry Pi 3 / 4 / 5 / CM4 / CM5 Web Terminal module.
#
# Actions:
#   install    Install ttyd and the shared same-host captive HTTP responder.
#   uninstall  Remove Web Terminal/captive services. Refuses while the React
#              Dashboard service exists; uninstall Dashboard first.
#   remove     Alias for uninstall.
#   purge      Compatibility alias for uninstall; packages/cache are retained.
#
# Runtime ownership:
#   - ttyd listens on port 7681.
#   - systemd socket activation owns port 80.
#   - /usr/local/sbin/initbox-portal-target selects where port 80 redirects:
#       terminal  -> same host on port 7681
#       dashboard -> same host on port 8080
#   - The React Dashboard module may change the portal target, but it does not
#     own ttyd or the port-80 socket.
#   - Hotspot owns dnsmasq/hostapd/wlan0 and is expected to be installed first.
set -euo pipefail

ACTION="${1:-install}"

: "${OWNER:=initbox}"
: "${PORTAL_HOSTNAME:=initbox.wlan}"
: "${TERMINAL_PORT:=7681}"
: "${DASHBOARD_PORT:=8080}"
: "${CAPTIVE_PORTAL_PORT:=80}"
: "${HOTSPOT_INTERFACE:=wlan0}"
: "${TTYD_VERSION:=1.7.7}"
: "${LOGFILE:=/home/${OWNER}/pi_logs/initbox-install.log}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${INITBOX_REPO_ROOT:-$(cd "$SCRIPT_DIR/../.." && pwd)}"
INITBOX_PACKAGES_FILE="${INITBOX_PACKAGES_FILE:-$REPO_ROOT/scripts/packages/pi-full.txt}"
INITBOX_PACKAGE_CACHE_ROOT="${INITBOX_PACKAGE_CACHE_ROOT:-/opt/initbox/packages}"
INITBOX_PACKAGE_CACHE_DIR="${INITBOX_PACKAGE_CACHE_DIR:-${INITBOX_PACKAGE_CACHE_ROOT}/apt}"
PACKAGES_LIB_FILE="$REPO_ROOT/scripts/lib/packages.sh"

TTYD_INSTALL_PATH="/usr/local/bin/ttyd"
TTYD_CACHE_DIR="${TTYD_CACHE_DIR:-${INITBOX_PACKAGE_CACHE_ROOT}/ttyd}"
TTYD_SERVICE_FILE="/etc/systemd/system/ttyd.service"

PORTAL_TARGET_FILE="${PORTAL_TARGET_FILE:-/etc/initbox/portal-target.env}"
PORTAL_TARGET_HELPER="/usr/local/sbin/initbox-portal-target"
CAPTIVE_RESPONDER="/usr/local/sbin/initbox-captive-responder.sh"
CAPTIVE_SOCKET_FILE="/etc/systemd/system/initbox-captive-http.socket"
CAPTIVE_SERVICE_FILE="/etc/systemd/system/initbox-captive-http@.service"

OLD_DASHBOARD_PORTAL_SERVICE="/etc/systemd/system/portal.service"
OLD_DASHBOARD_PORTAL_SCRIPT="/usr/local/bin/initbox-dashboard-portal.py"
OLD_TTYD_PORTAL_SERVICE="/etc/systemd/system/initbox-ttyd-portal.service"
OLD_TTYD_PORTAL_SCRIPT="/usr/local/bin/initbox-ttyd-portal.sh"
OLD_CAPTIVE_SERVICE="/etc/systemd/system/initbox-captive-portal.service"
OLD_CAPTIVE_SCRIPT="/usr/local/sbin/initbox-captive-portal.py"

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

command_exists() {
  command -v "$1" >/dev/null 2>&1
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

install_base_packages() {
  log "Installing Web Terminal dependencies through InitBox package cache"
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

cached_ttyd_path() {
  local ttyd_asset="$1"
  printf '%s\n' "$TTYD_CACHE_DIR/${TTYD_VERSION}-${ttyd_asset}"
}

download_ttyd_to_cache() {
  local ttyd_asset="$1"
  local cached_ttyd="$2"
  local ttyd_url=""
  local tmp_file=""

  if ! command_exists curl; then
    fail "curl is not installed; prepare the package cache and rerun"
  fi

  ttyd_url="https://github.com/tsl0922/ttyd/releases/download/${TTYD_VERSION}/${ttyd_asset}"
  tmp_file="${cached_ttyd}.tmp"
  install -d -m 0755 "$TTYD_CACHE_DIR"

  log "Cached ttyd binary not found; downloading it once for reuse"
  log "ttyd version: $TTYD_VERSION"
  log "ttyd asset:   $ttyd_asset"
  log "cache path:   $cached_ttyd"

  if ! curl -fL --retry 5 --retry-delay 3 "$ttyd_url" -o "$tmp_file"; then
    rm -f "$tmp_file"
    fail "failed to download ttyd; run once in the lab with Internet or place the binary at $cached_ttyd"
  fi

  chmod 0755 "$tmp_file"
  mv -f "$tmp_file" "$cached_ttyd"
}

install_ttyd_binary() {
  local ttyd_asset=""
  local cached_ttyd=""

  ttyd_asset="$(detect_ttyd_asset)"
  cached_ttyd="$(cached_ttyd_path "$ttyd_asset")"

  if [ ! -f "$cached_ttyd" ]; then
    download_ttyd_to_cache "$ttyd_asset" "$cached_ttyd"
  else
    log "Using cached ttyd binary: $cached_ttyd"
  fi

  chmod 0755 "$cached_ttyd"
  install -m 0755 "$cached_ttyd" "$TTYD_INSTALL_PATH"

  if ! "$TTYD_INSTALL_PATH" --version >/dev/null 2>&1; then
    fail "installed ttyd binary did not execute successfully: $TTYD_INSTALL_PATH"
  fi

  ok "ttyd installed at $TTYD_INSTALL_PATH"
}

get_required_command_path() {
  local command_name="$1"
  local command_path=""

  command_path="$(command -v "$command_name" || true)"
  if [ -z "$command_path" ] || [ ! -x "$command_path" ]; then
    fail "$command_name is not installed or executable"
  fi

  printf '%s\n' "$command_path"
}

get_hotspot_ip() {
  local hotspot_ip=""

  hotspot_ip="$(
    ip -4 addr show "$HOTSPOT_INTERFACE" 2>/dev/null \
      | awk '/inet / {print $2}' \
      | cut -d/ -f1 \
      | head -n 1
  )"

  if [ -z "$hotspot_ip" ]; then
    fail "could not detect IPv4 on $HOTSPOT_INTERFACE; install/start the hotspot module first"
  fi

  printf '%s\n' "$hotspot_ip"
}

check_hotspot_dns_owner() {
  local hotspot_ip="$1"

  if [ ! -f /etc/dnsmasq.conf ]; then
    fail "/etc/dnsmasq.conf does not exist; install the hotspot module first"
  fi

  if ! grep -q "^address=/#/${hotspot_ip}$" /etc/dnsmasq.conf; then
    warn "wildcard captive DNS rule not found; expected address=/#/${hotspot_ip}"
  fi

  if ! grep -q "^dhcp-option=6,${hotspot_ip}$" /etc/dnsmasq.conf; then
    warn "hotspot DHCP DNS option not found; expected dhcp-option=6,${hotspot_ip}"
  fi
}

remove_old_dns_fragments() {
  rm -f \
    /etc/dnsmasq.d/initbox-wlan.conf \
    /etc/dnsmasq.d/initbox-captive-portal.conf \
    /etc/dnsmasq.d/initbox-hotspot.conf
}

stop_unit_if_present() {
  local unit_name="$1"
  systemctl disable --now "$unit_name" 2>/dev/null || true
  systemctl reset-failed "$unit_name" 2>/dev/null || true
}

remove_legacy_portal_runtime() {
  log "Removing obsolete portal implementations if present"

  stop_unit_if_present portal.service
  stop_unit_if_present initbox-captive-portal.service
  stop_unit_if_present initbox-ttyd-portal.service

  rm -f \
    "$OLD_DASHBOARD_PORTAL_SERVICE" \
    "$OLD_DASHBOARD_PORTAL_SCRIPT" \
    "$OLD_CAPTIVE_SERVICE" \
    "$OLD_CAPTIVE_SCRIPT" \
    "$OLD_TTYD_PORTAL_SERVICE" \
    "$OLD_TTYD_PORTAL_SCRIPT"
}

remove_old_redirect_rules() {
  if ! command_exists iptables; then
    return 0
  fi

  while iptables -t nat -C PREROUTING -i "$HOTSPOT_INTERFACE" -p tcp --dport 80 \
    -j REDIRECT --to-ports "$TERMINAL_PORT" 2>/dev/null; do
    iptables -t nat -D PREROUTING -i "$HOTSPOT_INTERFACE" -p tcp --dport 80 \
      -j REDIRECT --to-ports "$TERMINAL_PORT"
  done

  while iptables -t nat -C PREROUTING -i "$HOTSPOT_INTERFACE" -p tcp --dport 80 \
    -j REDIRECT --to-ports "$DASHBOARD_PORT" 2>/dev/null; do
    iptables -t nat -D PREROUTING -i "$HOTSPOT_INTERFACE" -p tcp --dport 80 \
      -j REDIRECT --to-ports "$DASHBOARD_PORT"
  done
}

write_ttyd_service() {
  local ttyd_bin="$1"

  cat >"$TTYD_SERVICE_FILE" <<EOF_TTYD
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
EOF_TTYD
}

write_portal_target_helper() {
  install -d -m 0755 "$(dirname "$PORTAL_TARGET_FILE")"

  cat >"$PORTAL_TARGET_HELPER" <<EOF_HELPER
#!/usr/bin/env bash
set -euo pipefail

TARGET_FILE="$PORTAL_TARGET_FILE"
TERMINAL_PORT="$TERMINAL_PORT"
DASHBOARD_PORT="$DASHBOARD_PORT"

require_root() {
  if [ "\$(id -u)" -ne 0 ]; then
    echo "ERROR: portal target changes must run as root" >&2
    exit 1
  fi
}

show_target() {
  if [ -r "\$TARGET_FILE" ]; then
    cat "\$TARGET_FILE"
  else
    echo "INITBOX_PORTAL_TARGET_NAME=terminal"
    echo "INITBOX_PORTAL_TARGET_PORT=\$TERMINAL_PORT"
  fi
}

write_target() {
  local name="\$1"
  local port="\$2"
  local tmp=""

  require_root
  install -d -m 0755 "\$(dirname "\$TARGET_FILE")"
  tmp="\$(mktemp "\$(dirname "\$TARGET_FILE")/.portal-target.XXXXXX")"
  {
    echo "INITBOX_PORTAL_TARGET_NAME=\$name"
    echo "INITBOX_PORTAL_TARGET_PORT=\$port"
  } >"\$tmp"
  install -m 0644 -o root -g root "\$tmp" "\$TARGET_FILE"
  rm -f "\$tmp"
  echo "InitBox portal target: \$name (port \$port)"
}

case "\${1:-show}" in
  terminal)
    write_target terminal "\$TERMINAL_PORT"
    ;;
  dashboard)
    write_target dashboard "\$DASHBOARD_PORT"
    ;;
  show)
    show_target
    ;;
  *)
    echo "Usage: sudo initbox-portal-target terminal|dashboard|show" >&2
    exit 2
    ;;
esac
EOF_HELPER

  chmod 0755 "$PORTAL_TARGET_HELPER"
  chown root:root "$PORTAL_TARGET_HELPER" 2>/dev/null || true
}

portal_target_port() {
  local target_port=""

  if [ -r "$PORTAL_TARGET_FILE" ]; then
    target_port="$(sed -n 's/^INITBOX_PORTAL_TARGET_PORT=//p' "$PORTAL_TARGET_FILE" | tail -n 1)"
  fi

  case "$target_port" in
    "$TERMINAL_PORT"|"$DASHBOARD_PORT")
      printf '%s\n' "$target_port"
      ;;
    *)
      printf '%s\n' "$TERMINAL_PORT"
      ;;
  esac
}

ensure_sane_portal_target() {
  local current_port=""

  current_port="$(portal_target_port)"

  if [ "$current_port" = "$DASHBOARD_PORT" ] \
    && systemctl cat initbox-dashboard.service >/dev/null 2>&1; then
    log "Preserving dashboard portal target on port $DASHBOARD_PORT"
    return 0
  fi

  "$PORTAL_TARGET_HELPER" terminal >/dev/null
  log "Portal target set to Web Terminal on port $TERMINAL_PORT"
}

write_captive_responder() {
  cat >"$CAPTIVE_RESPONDER" <<'EOF_RESPONDER'
#!/usr/bin/env bash
set -uo pipefail

TARGET_FILE="${INITBOX_PORTAL_TARGET_FILE:-/etc/initbox/portal-target.env}"
DEFAULT_TARGET_PORT="${INITBOX_DEFAULT_TARGET_PORT:-7681}"
DEFAULT_HOST="${INITBOX_DEFAULT_HOST:-initbox.wlan}"
REQUEST_LINE=""
HEADER_LINE=""
HOST_HEADER=""
REDIRECT_HOST=""
TARGET_PORT=""
LOCATION=""
BODY="InitBox captive portal redirect"

trap 'exit 0' PIPE

trim_spaces() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s\n' "$value"
}

read_target_port() {
  local value=""

  if [ -r "$TARGET_FILE" ]; then
    value="$(sed -n 's/^INITBOX_PORTAL_TARGET_PORT=//p' "$TARGET_FILE" | tail -n 1)"
  fi

  case "$value" in
    ''|*[!0-9]*)
      printf '%s\n' "$DEFAULT_TARGET_PORT"
      ;;
    *)
      if [ "$value" -ge 1 ] 2>/dev/null && [ "$value" -le 65535 ] 2>/dev/null; then
        printf '%s\n' "$value"
      else
        printf '%s\n' "$DEFAULT_TARGET_PORT"
      fi
      ;;
  esac
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
  [ -z "$HEADER_LINE" ] && break

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
[ -n "$REDIRECT_HOST" ] || REDIRECT_HOST="$DEFAULT_HOST"

TARGET_PORT="$(read_target_port)"
LOCATION="http://${REDIRECT_HOST}:${TARGET_PORT}/"
send_response || true
exit 0
EOF_RESPONDER

  chmod 0755 "$CAPTIVE_RESPONDER"
  chown root:root "$CAPTIVE_RESPONDER" 2>/dev/null || true
}

write_captive_socket_units() {
  cat >"$CAPTIVE_SOCKET_FILE" <<EOF_SOCKET
[Unit]
Description=InitBox captive portal HTTP socket

[Socket]
ListenStream=0.0.0.0:$CAPTIVE_PORTAL_PORT
Accept=yes
NoDelay=true

[Install]
WantedBy=sockets.target
EOF_SOCKET

  cat >"$CAPTIVE_SERVICE_FILE" <<EOF_SERVICE
[Unit]
Description=InitBox captive portal HTTP responder

[Service]
Type=simple
User=$OWNER
Group=$OWNER
Environment=INITBOX_PORTAL_TARGET_FILE=$PORTAL_TARGET_FILE
Environment=INITBOX_DEFAULT_TARGET_PORT=$TERMINAL_PORT
Environment=INITBOX_DEFAULT_HOST=$PORTAL_HOSTNAME
ExecStart=-$CAPTIVE_RESPONDER
StandardInput=socket
StandardOutput=socket
StandardError=journal
SuccessExitStatus=0 1 141 SIGPIPE
EOF_SERVICE
}

restart_services() {
  log "Reloading systemd and starting Web Terminal services"
  systemctl daemon-reload

  if systemctl list-unit-files dnsmasq.service >/dev/null 2>&1; then
    dnsmasq --test
    systemctl restart dnsmasq.service
  else
    fail "dnsmasq service not found; install the hotspot module first"
  fi

  systemctl enable --now ttyd.service
  systemctl restart ttyd.service
  systemctl enable --now initbox-captive-http.socket
  systemctl restart initbox-captive-http.socket
  systemctl reset-failed 'initbox-captive-http@*.service' 2>/dev/null || true
}

dashboard_is_installed() {
  systemctl cat initbox-dashboard.service >/dev/null 2>&1
}

remove_module_runtime() {
  log "Removing Web Terminal and shared captive portal runtime"

  stop_unit_if_present initbox-captive-http.socket
  stop_unit_if_present ttyd.service
  systemctl stop 'initbox-captive-http@*.service' 2>/dev/null || true
  systemctl reset-failed 'initbox-captive-http@*.service' 2>/dev/null || true

  rm -f \
    "$CAPTIVE_SOCKET_FILE" \
    "$CAPTIVE_SERVICE_FILE" \
    "$CAPTIVE_RESPONDER" \
    "$PORTAL_TARGET_HELPER" \
    "$PORTAL_TARGET_FILE" \
    "$TTYD_SERVICE_FILE"

  remove_legacy_portal_runtime
  remove_old_dns_fragments
  remove_old_redirect_rules
  systemctl daemon-reload
  systemctl reset-failed 2>/dev/null || true
}

print_install_summary() {
  local hotspot_ip="$1"
  local target_port=""
  local target_name="terminal"

  target_port="$(portal_target_port)"
  if [ "$target_port" = "$DASHBOARD_PORT" ]; then
    target_name="dashboard"
  fi

  echo
  echo "Web Terminal installed"
  echo "----------------------"
  echo "Portal URL:          http://$PORTAL_HOSTNAME/"
  echo "Hotspot portal:      http://$hotspot_ip/"
  echo "Web Terminal:        http://$PORTAL_HOSTNAME:$TERMINAL_PORT/"
  echo "Hotspot terminal:    http://$hotspot_ip:$TERMINAL_PORT/"
  echo "Portal target:       $target_name (port $target_port)"
  echo "ttyd binary:         $TTYD_INSTALL_PATH"
  echo "ttyd cache:          $TTYD_CACHE_DIR"
  echo "Portal target file:  $PORTAL_TARGET_FILE"
  echo
  echo "Dashboard integration:"
  echo "  sudo $PORTAL_TARGET_HELPER dashboard"
  echo "  sudo $PORTAL_TARGET_HELPER terminal"
  echo "  sudo $PORTAL_TARGET_HELPER show"
  echo
  echo "The responder keeps the original host name/IP when redirecting."
}

install_main() {
  local hotspot_ip=""
  local ttyd_bin=""

  require_root
  ensure_log_dir
  require_user
  install_base_packages

  if ! command_exists ttyd && [ ! -x "$TTYD_INSTALL_PATH" ]; then
    install_ttyd_binary
  fi

  ttyd_bin="$(get_required_command_path ttyd)"
  hotspot_ip="$(get_hotspot_ip)"
  check_hotspot_dns_owner "$hotspot_ip"

  stop_unit_if_present initbox-captive-http.socket
  systemctl stop ttyd.service 2>/dev/null || true
  remove_legacy_portal_runtime
  remove_old_dns_fragments
  remove_old_redirect_rules

  write_ttyd_service "$ttyd_bin"
  write_portal_target_helper
  ensure_sane_portal_target
  write_captive_responder
  write_captive_socket_units
  restart_services
  print_install_summary "$hotspot_ip"

  ok "Web Terminal module installed"
}

uninstall_main() {
  require_root
  ensure_log_dir

  if dashboard_is_installed; then
    fail "React Dashboard is still installed; uninstall dashboard before removing Web Terminal"
  fi

  remove_module_runtime

  echo
  echo "Web Terminal uninstalled"
  echo "------------------------"
  echo "Cached ttyd binary and Debian package cache were retained."
  ok "Web Terminal module uninstalled"
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
      warn "purge keeps shared packages and caches; running uninstall"
      uninstall_main
      ;;
    *)
      fail "unknown action '$ACTION'; use install or uninstall"
      ;;
  esac
}

main "$@"
