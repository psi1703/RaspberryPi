#!/usr/bin/env bash

# InitBox Pi Zero 2W Web Terminal and captive portal module
#
# Installs and enables:
#   - ttyd Web Terminal on port 7681
#   - lightweight captive portal landing service on port 80
#
# User-facing URL:
#   http://initbox.wlan/
#   http://initbox.wlan:7681/
#
# This module assumes the hotspot/dnsmasq module provides DHCP/DNS.
# It ensures dnsmasq resolves initbox.wlan and common captive-check
# domains to the wlan0 hotspot IP.

set -euo pipefail

MODULE_NAME="Web Terminal and Captive Portal"
PORTAL_HOSTNAME="initbox.wlan"
TERMINAL_PORT="7681"
CAPTIVE_PORTAL_PORT="80"
HOTSPOT_INTERFACE="${HOTSPOT_INTERFACE:-wlan0}"

TTYD_SERVICE_FILE="/etc/systemd/system/ttyd.service"
CAPTIVE_SCRIPT="/usr/local/sbin/initbox-captive-portal.sh"
CAPTIVE_SERVICE_FILE="/etc/systemd/system/initbox-captive-portal.service"
DNSMASQ_DIR="/etc/dnsmasq.d"
DNSMASQ_INITBOX_FILE="$DNSMASQ_DIR/initbox-wlan.conf"

log() {
  printf '[%s] %s\n' "$MODULE_NAME" "$1"
}

fail() {
  log "ERROR: $1"
  exit 1
}

require_root() {
  if [ "$(id -u)" -ne 0 ]; then
    fail "this module must be run as root"
  fi
}

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

install_packages() {
  local packages=()

  if ! command_exists ttyd; then
    packages+=("ttyd")
  fi

  if ! command_exists nc; then
    packages+=("netcat-openbsd")
  fi

  if [ "${#packages[@]}" -eq 0 ]; then
    log "required packages already installed"
    return 0
  fi

  log "installing packages: ${packages[*]}"
  apt-get update
  apt-get install -y "${packages[@]}"
}

get_hotspot_ip() {
  local hotspot_ip

  hotspot_ip="$(
    ip -4 addr show "$HOTSPOT_INTERFACE" 2>/dev/null |
      awk '/inet / {print $2}' |
      cut -d/ -f1 |
      head -n 1
  )"

  if [ -z "$hotspot_ip" ]; then
    fail "could not detect IPv4 address on $HOTSPOT_INTERFACE. Install/start hotspot first."
  fi

  printf '%s\n' "$hotspot_ip"
}

write_ttyd_service() {
  log "writing ttyd systemd service"

  cat >"$TTYD_SERVICE_FILE" <<EOF
[Unit]
Description=InitBox Web Terminal
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/bin/ttyd --interface 0.0.0.0 --port $TERMINAL_PORT /bin/bash
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF
}

write_dnsmasq_hostname_config() {
  local hotspot_ip="$1"

  log "ensuring captive portal DNS resolves to $hotspot_ip"

  mkdir -p "$DNSMASQ_DIR"

  cat >"$DNSMASQ_INITBOX_FILE" <<EOF
# InitBox local hotspot hostname and captive portal DNS
# Managed by scripts/pi-zero2w/module-ttyd-portal.sh

# Friendly local InitBox name.
address=/$PORTAL_HOSTNAME/$hotspot_ip

# Android captive portal checks.
address=/connectivitycheck.gstatic.com/$hotspot_ip
address=/clients3.google.com/$hotspot_ip
address=/connectivitycheck.android.com/$hotspot_ip
address=/www.google.com/$hotspot_ip

# Apple captive portal checks.
address=/captive.apple.com/$hotspot_ip
address=/www.apple.com/$hotspot_ip

# Windows captive portal checks.
address=/www.msftconnecttest.com/$hotspot_ip
address=/msftconnecttest.com/$hotspot_ip

# Field mode: resolve all other names to the InitBox hotspot IP while clients
# are connected to the InitBox Wi-Fi. This helps captive portal detection land
# on the local port-80 portal page instead of failing silently.
address=/#/$hotspot_ip
EOF
}

write_captive_portal_script() {
  log "writing captive portal landing script"

  cat >"$CAPTIVE_SCRIPT" <<'EOF'
#!/usr/bin/env bash

set -euo pipefail

PORT="${1:-80}"
TARGET_URL="${INITBOX_TERMINAL_URL:-http://initbox.wlan:7681/}"

require_nc() {
  if ! command -v nc >/dev/null 2>&1; then
    echo "ERROR: nc command not found. Install netcat-openbsd." >&2
    exit 1
  fi
}

serve_once() {
  {
    printf 'HTTP/1.1 200 OK\r\n'
    printf 'Content-Type: text/html; charset=utf-8\r\n'
    printf 'Cache-Control: no-store, no-cache, must-revalidate, max-age=0\r\n'
    printf 'Pragma: no-cache\r\n'
    printf 'Connection: close\r\n'
    printf '\r\n'
    printf '<!doctype html>\n'
    printf '<html>\n'
    printf '<head>\n'
    printf '  <meta charset="utf-8">\n'
    printf '  <meta name="viewport" content="width=device-width, initial-scale=1">\n'
    printf '  <title>InitBox Login</title>\n'
    printf '</head>\n'
    printf '<body style="font-family:sans-serif;padding:24px;max-width:640px;margin:auto;">\n'
    printf '  <h1>InitBox</h1>\n'
    printf '  <p>This Wi-Fi network provides local InitBox access only.</p>\n'
    printf '  <p>Use the Web Terminal to manage this unit.</p>\n'
    printf '  <p><a style="display:inline-block;padding:12px 16px;background:#111;color:#fff;text-decoration:none;border-radius:6px;" href="%s">Open InitBox Web Terminal</a></p>\n' "$TARGET_URL"
    printf '  <p>Direct URL: <a href="%s">%s</a></p>\n' "$TARGET_URL" "$TARGET_URL"
    printf '</body>\n'
    printf '</html>\n'
  } | nc -l -p "$PORT" -q 1
}

main() {
  require_nc

  while true; do
    serve_once || true
    sleep 1
  done
}

main "$@"
EOF

  chmod 755 "$CAPTIVE_SCRIPT"
}

write_captive_portal_service() {
  local terminal_url

  terminal_url="http://$PORTAL_HOSTNAME:$TERMINAL_PORT/"

  log "writing captive portal service for $terminal_url"

  cat >"$CAPTIVE_SERVICE_FILE" <<EOF
[Unit]
Description=InitBox captive portal landing page for Web Terminal
After=network-online.target dnsmasq.service ttyd.service
Wants=network-online.target

[Service]
Type=simple
Environment=INITBOX_TERMINAL_URL=$terminal_url
ExecStart=$CAPTIVE_SCRIPT $CAPTIVE_PORTAL_PORT
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF
}

restart_services() {
  log "reloading systemd"
  systemctl daemon-reload

  log "enabling ttyd"
  systemctl enable --now ttyd.service

  if systemctl list-unit-files dnsmasq.service >/dev/null 2>&1; then
    log "restarting dnsmasq"
    systemctl restart dnsmasq.service
  else
    log "dnsmasq service not found; hotspot module may not be installed yet"
  fi

  log "enabling captive portal"
  systemctl enable --now initbox-captive-portal.service
  systemctl restart initbox-captive-portal.service
}

print_summary() {
  echo
  echo "Web Terminal and captive portal installed"
  echo "----------------------------------------"
  echo "Captive portal URL: http://$PORTAL_HOSTNAME/"
  echo "Web Terminal URL:   http://$PORTAL_HOSTNAME:$TERMINAL_PORT/"
  echo
  echo "Phone testing steps:"
  echo "  1. Forget the InitBox Wi-Fi network on the phone."
  echo "  2. Disable mobile data temporarily if captive prompt does not appear."
  echo "  3. Reconnect to the InitBox hotspot."
  echo "  4. Wait for the Action needed / Sign in prompt."
  echo
  echo "Check services:"
  echo "  sudo systemctl status ttyd --no-pager"
  echo "  sudo systemctl status initbox-captive-portal --no-pager"
  echo "  sudo systemctl status dnsmasq --no-pager"
  echo
  echo "Check ports:"
  echo "  sudo ss -tulpn | grep -E ':80|:53|:67|:7681'"
  echo
  echo "Check captive DNS:"
  echo "  getent hosts initbox.wlan"
  echo "  getent hosts connectivitycheck.gstatic.com"
  echo "  getent hosts captive.apple.com"
  echo "  getent hosts www.msftconnecttest.com"
}

main() {
  local hotspot_ip

  require_root
  install_packages

  hotspot_ip="$(get_hotspot_ip)"

  write_ttyd_service
  write_dnsmasq_hostname_config "$hotspot_ip"
  write_captive_portal_script
  write_captive_portal_service
  restart_services
  print_summary
}

main "$@"
