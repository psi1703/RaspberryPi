#!/usr/bin/env bash

# InitBox Pi Zero 2W Web Terminal and captive portal module
#
# Installs and enables:
#   - ttyd Web Terminal on port 7681
#   - lightweight Python captive portal landing service on port 80
#
# User-facing URLs:
#   http://initbox.wlan/
#   http://initbox.wlan:7681/
#
# This module assumes the hotspot/dnsmasq module provides:
#   - hostapd access point
#   - wlan0 static hotspot IP
#   - DHCP service through dnsmasq
#
# This module adds:
#   - local hostname/captive-check DNS overrides
#   - ttyd service running as the normal initbox user
#   - captive portal HTTP service on port 80
#
# It must not replace the hotspot module's DHCP, wlan0 IP, or hostapd ownership.

set -euo pipefail

MODULE_NAME="Web Terminal and Captive Portal"

OWNER="${OWNER:-initbox}"
PORTAL_HOSTNAME="${PORTAL_HOSTNAME:-initbox.wlan}"
TERMINAL_PORT="${TERMINAL_PORT:-7681}"
CAPTIVE_PORTAL_PORT="${CAPTIVE_PORTAL_PORT:-80}"
HOTSPOT_INTERFACE="${HOTSPOT_INTERFACE:-wlan0}"

TTYD_SERVICE_FILE="/etc/systemd/system/ttyd.service"
CAPTIVE_SCRIPT="/usr/local/sbin/initbox-captive-portal.py"
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

require_user() {
  if ! id "$OWNER" >/dev/null 2>&1; then
    fail "user '$OWNER' does not exist"
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

  if ! command_exists python3; then
    packages+=("python3")
  fi

  if [ "${#packages[@]}" -eq 0 ]; then
    log "required packages already installed"
    return 0
  fi

  log "installing packages: ${packages[*]}"
  apt-get update
  apt-get install -y "${packages[@]}"
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
ExecStart=$ttyd_bin -W --interface 0.0.0.0 --port $TERMINAL_PORT /bin/bash
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF
}

write_dnsmasq_hostname_config() {
  local hotspot_ip="$1"

  log "writing captive portal DNS overrides to $DNSMASQ_INITBOX_FILE"

  mkdir -p "$DNSMASQ_DIR"

  cat >"$DNSMASQ_INITBOX_FILE" <<EOF
# InitBox captive portal DNS overrides
# Managed by scripts/pi-zero2w/module-ttyd-portal.sh
#
# The hotspot module owns DHCP, wlan0 IP, hostapd, and the main dnsmasq.conf.
# This file only ensures known captive-check hostnames resolve to the Pi.

address=/$PORTAL_HOSTNAME/$hotspot_ip
address=/initbox.local/$hotspot_ip

# Android captive portal checks
address=/connectivitycheck.gstatic.com/$hotspot_ip
address=/connectivitycheck.android.com/$hotspot_ip
address=/clients3.google.com/$hotspot_ip
address=/www.gstatic.com/$hotspot_ip
address=/www.google.com/$hotspot_ip

# Apple captive portal checks
address=/captive.apple.com/$hotspot_ip
address=/www.apple.com/$hotspot_ip
address=/www.appleiphonecell.com/$hotspot_ip

# Windows NCSI / captive portal checks
address=/msftconnecttest.com/$hotspot_ip
address=/www.msftconnecttest.com/$hotspot_ip
address=/ipv6.msftconnecttest.com/$hotspot_ip
address=/msftncsi.com/$hotspot_ip
address=/www.msftncsi.com/$hotspot_ip
address=/dns.msftncsi.com/$hotspot_ip

# Firefox captive portal check
address=/detectportal.firefox.com/$hotspot_ip
EOF
}

write_captive_portal_script() {
  log "writing Python captive portal HTTP server"

  cat >"$CAPTIVE_SCRIPT" <<'PYEOF'
#!/usr/bin/env python3

import html
import os
import signal
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


PORT = int(os.environ.get("INITBOX_CAPTIVE_PORT", "80"))
HOSTNAME = os.environ.get("INITBOX_PORTAL_HOSTNAME", "initbox.wlan")
TERMINAL_PORT = os.environ.get("INITBOX_TERMINAL_PORT", "7681")

PORTAL_URL = "http://" + HOSTNAME + "/"
TERMINAL_URL = os.environ.get(
    "INITBOX_TERMINAL_URL",
    "http://" + HOSTNAME + ":" + TERMINAL_PORT + "/",
)


class CaptivePortalHandler(BaseHTTPRequestHandler):
    server_version = "InitBoxCaptivePortal/1.2"

    def log_message(self, fmt, *args):
        sys.stdout.write("%s - %s\n" % (self.client_address[0], fmt % args))
        sys.stdout.flush()

    def do_GET(self):
        if self.is_probe_request():
            self.redirect_to_portal()
            return

        self.show_portal()

    def do_HEAD(self):
        if self.is_probe_request():
            self.redirect_to_portal(body=False)
            return

        self.show_portal(body=False)

    def do_POST(self):
        self.show_portal()

    def is_probe_request(self):
        host = self.headers.get("Host", "").lower()
        path = self.path.split("?", 1)[0].lower()

        probe_hosts = (
            "msftconnecttest.com",
            "www.msftconnecttest.com",
            "ipv6.msftconnecttest.com",
            "msftncsi.com",
            "www.msftncsi.com",
            "dns.msftncsi.com",
            "connectivitycheck.gstatic.com",
            "connectivitycheck.android.com",
            "clients3.google.com",
            "captive.apple.com",
            "detectportal.firefox.com",
        )

        probe_paths = (
            "/connecttest.txt",
            "/ncsi.txt",
            "/generate_204",
            "/gen_204",
            "/hotspot-detect.html",
            "/success.txt",
            "/canonical.html",
        )

        if any(name in host for name in probe_hosts):
            return True

        return path in probe_paths

    def redirect_to_portal(self, body=True):
        content = b"InitBox captive portal redirect\n"

        self.send_response(302)
        self.send_header("Location", PORTAL_URL)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Content-Length", str(len(content)))
        self.send_header("Cache-Control", "no-store, no-cache, must-revalidate, max-age=0")
        self.send_header("Pragma", "no-cache")
        self.send_header("Connection", "close")
        self.end_headers()

        if body:
            self.wfile.write(content)

    def show_portal(self, body=True):
        terminal_url = html.escape(TERMINAL_URL, quote=True)
        hostname = html.escape(HOSTNAME, quote=True)

        content = """<!doctype html>
<html>
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>InitBox</title>
  <style>
    body {
      font-family: sans-serif;
      padding: 24px;
      max-width: 720px;
      margin: auto;
      line-height: 1.45;
    }
    .button {
      display: inline-block;
      padding: 12px 16px;
      background: #111;
      color: #fff;
      text-decoration: none;
      border-radius: 6px;
      font-weight: 700;
    }
    code {
      background: #eee;
      padding: 2px 5px;
      border-radius: 4px;
    }
  </style>
</head>
<body>
  <h1>InitBox</h1>
  <p>This Wi-Fi network provides local InitBox access only.</p>
  <p>Use the Web Terminal to manage this unit.</p>
  <p><a class="button" href="{terminal_url}">Open InitBox Web Terminal</a></p>
  <p>Portal URL: <code>http://{hostname}/</code></p>
  <p>Terminal URL: <code>{terminal_url}</code></p>
</body>
</html>
""".format(
            terminal_url=terminal_url,
            hostname=hostname,
        ).encode("utf-8")

        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(content)))
        self.send_header("Cache-Control", "no-store, no-cache, must-revalidate, max-age=0")
        self.send_header("Pragma", "no-cache")
        self.send_header("Connection", "close")
        self.end_headers()

        if body:
            self.wfile.write(content)


def main():
    signal.signal(signal.SIGTERM, lambda signum, frame: sys.exit(0))

    server = ThreadingHTTPServer(("0.0.0.0", PORT), CaptivePortalHandler)
    print("InitBox captive portal listening on 0.0.0.0:%d" % PORT)
    print("Portal URL: %s" % PORTAL_URL)
    print("Terminal URL: %s" % TERMINAL_URL)
    sys.stdout.flush()
    server.serve_forever()


if __name__ == "__main__":
    main()
PYEOF

  chmod 755 "$CAPTIVE_SCRIPT"
}

write_captive_portal_service() {
  local python_bin="$1"
  local terminal_url=""

  terminal_url="http://$PORTAL_HOSTNAME:$TERMINAL_PORT/"

  log "writing captive portal service for $terminal_url"

  cat >"$CAPTIVE_SERVICE_FILE" <<EOF
[Unit]
Description=InitBox captive portal landing page for Web Terminal
After=network.target dnsmasq.service ttyd.service
Wants=ttyd.service

[Service]
Type=simple
Environment=INITBOX_PORTAL_HOSTNAME=$PORTAL_HOSTNAME
Environment=INITBOX_TERMINAL_PORT=$TERMINAL_PORT
Environment=INITBOX_CAPTIVE_PORT=$CAPTIVE_PORTAL_PORT
Environment=INITBOX_TERMINAL_URL=$terminal_url
ExecStart=$python_bin $CAPTIVE_SCRIPT
Restart=always
RestartSec=2

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

    log "restarting dnsmasq"
    systemctl restart dnsmasq.service
  else
    log "dnsmasq service not found; run hotspot module first"
  fi

  log "enabling ttyd"
  systemctl enable --now ttyd.service
  systemctl restart ttyd.service

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
  echo "Expected ttyd behavior:"
  echo "  - Login user: $OWNER"
  echo "  - Keyboard input: enabled by ttyd -W"
  echo
  echo "Phone/Windows testing steps:"
  echo "  1. Forget the InitBox Wi-Fi network."
  echo "  2. Reconnect to the InitBox hotspot."
  echo "  3. On Windows, the Wi-Fi panel should show Action needed."
  echo "  4. On Android/iOS, the sign-in/captive prompt should open automatically or after tapping the network."
  echo
  echo "Manual captive portal test URLs:"
  echo "  http://$PORTAL_HOSTNAME/"
  echo "  http://www.msftconnecttest.com/connecttest.txt"
  echo "  http://connectivitycheck.gstatic.com/generate_204"
  echo "  http://captive.apple.com/hotspot-detect.html"
  echo
  echo "Check services:"
  echo "  sudo systemctl status ttyd --no-pager"
  echo "  sudo systemctl status initbox-captive-portal --no-pager"
  echo "  sudo systemctl status dnsmasq --no-pager"
  echo "  sudo systemctl status hostapd --no-pager"
  echo
  echo "Check ports:"
  echo "  sudo ss -tulpn | grep -E ':80|:53|:67|:7681'"
  echo
  echo "Check generated services:"
  echo "  systemctl cat ttyd"
  echo "  systemctl cat initbox-captive-portal"
}

main() {
  local hotspot_ip=""
  local python_bin=""
  local ttyd_bin=""

  require_root
  require_user
  install_packages

  python_bin="$(get_required_command_path python3)"
  ttyd_bin="$(get_required_command_path ttyd)"
  hotspot_ip="$(get_hotspot_ip)"

  write_ttyd_service "$ttyd_bin"
  write_dnsmasq_hostname_config "$hotspot_ip"
  write_captive_portal_script
  write_captive_portal_service "$python_bin"
  restart_services
  print_summary
}

main "$@"
