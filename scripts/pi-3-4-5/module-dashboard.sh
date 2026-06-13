#!/usr/bin/env bash

# InitBox Raspberry Pi 3 / 4 / 5 dashboard module
#
# Installs:
#   - Node.js 22 when required
#   - Node-RED dashboard controller under /home/initbox/.node-red
#   - node-red-dashboard package
#   - ttyd web terminal
#   - captive portal landing service on port 80 that redirects to Node-RED UI
#   - role sync helper using /etc/pi_roles.conf
#   - Pi stats helper for dashboard use
#   - restricted File Transfer helper for dashboard upload/download actions
#
# Important service model:
#   - InitBox uses pi-nodered.service only.
#   - The upstream/default nodered.service is stopped, disabled, masked, and removed
#     if it exists locally.
#   - Node-RED must never run from /root/.node-red for InitBox.
#
# Important flow/settings/logo model:
#   - Repository source files must exist here:
#       scripts/flows.json
#       scripts/settings.js
#       scripts/logo.png
#   - Runtime files are always replaced with the repository versions:
#       /home/initbox/.node-red/flows.json
#       /home/initbox/.node-red/settings.js
#       /home/initbox/.node-red/public/logo.png
#   - Generated/hostname flow files are removed during install.
#
# Package/cache model:
#   - Uses scripts/lib/packages.sh for Debian packages where practical.
#   - With Internet: installs packages and keeps Debian packages cached.
#   - Without Internet: reuses already-installed Node.js, Node-RED, dashboard nodes,
#     ttyd, and local Debian package cache.
#   - ttyd is built once, installed, and cached locally for future reruns.
#
# Pi 3 / 4 / 5 role model:
#   - Dashboard/Node-RED owns /etc/pi_roles.conf.
#   - pi-servsync.sh applies roles to services.
#   - Sniffer roles accepted: sniff, wireshark, sniffer, sniffer-bridge.
#
# Actions:
#   install    Install/update dashboard services and helper scripts
#   uninstall  Disable/remove services and helper scripts created by this module
#   purge      Compatibility alias for uninstall; packages are not purged

set -euo pipefail

ACTION="${1:-install}"

: "${OWNER:=initbox}"

SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_PATH")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PACKAGES_HELPER="$REPO_ROOT/scripts/lib/packages.sh"

INITBOX_PACKAGE_CACHE_DIR="${INITBOX_PACKAGE_CACHE_DIR:-/opt/initbox-package-cache}"
DASHBOARD_CACHE_DIR="${DASHBOARD_CACHE_DIR:-${INITBOX_PACKAGE_CACHE_DIR}/dashboard}"
TTYD_CACHE_BIN="${TTYD_CACHE_BIN:-${DASHBOARD_CACHE_DIR}/ttyd}"

MIN_NODE_MAJOR="${MIN_NODE_MAJOR:-22}"

LOG_DIR="/home/${OWNER}/pi_logs"
LOGFILE="${LOGFILE:-${LOG_DIR}/initbox-install.log}"

ROLE_FILE="${ROLE_FILE:-/etc/pi_roles.conf}"
MODS_FILE="${MODS_FILE:-/etc/initbox-mods.conf}"

TTYD_PORT="${TTYD_PORT:-7681}"
DASHBOARD_PORT="${DASHBOARD_PORT:-1880}"
HOTSPOT_IFACE="${HOTSPOT_IFACE:-wlan0}"
HOTSPOT_IP="${HOTSPOT_IP:-}"
PORTAL_SCRIPT="/usr/local/bin/initbox-dashboard-portal.py"
PORTAL_SERVICE="/etc/systemd/system/portal.service"

NODE_RED_USER_DIR="/home/${OWNER}/.node-red"
NODE_RED_LOCAL_BIN="${NODE_RED_USER_DIR}/node_modules/.bin/node-red"
REPO_FLOWS_FILE="${REPO_ROOT}/scripts/flows.json"
REPO_SETTINGS_FILE="${REPO_ROOT}/scripts/settings.js"
REPO_LOGO_FILE="${REPO_ROOT}/scripts/logo.png"

ts() {
  date +"%Y-%m-%d %H:%M:%S"
}

log() {
  echo "[DASH $(ts)] $*" | tee -a "$LOGFILE"
}

ok() {
  echo "[DASH $(ts)] [OK] $*" | tee -a "$LOGFILE"
}

warn() {
  echo "[DASH $(ts)] [WARN] $*" | tee -a "$LOGFILE" >&2
}

err() {
  echo "[DASH $(ts)] [ERR] $*" | tee -a "$LOGFILE" >&2
}

require_root() {
  if [ "$(id -u)" -ne 0 ]; then
    err "This module must be run as root."
    echo "Run with:"
    echo "  sudo ./scripts/pi-3-4-5/module-dashboard.sh ${ACTION}"
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

prepare_dashboard_cache() {
  install -d -m 0755 "$INITBOX_PACKAGE_CACHE_DIR"
  install -d -m 0755 "$DASHBOARD_CACHE_DIR"

  if id "$OWNER" >/dev/null 2>&1; then
    chown "$OWNER:$OWNER" "$DASHBOARD_CACHE_DIR" 2>/dev/null || true
  fi
}

have_internet() {
  ping -c 1 -W 1 8.8.8.8 >/dev/null 2>&1
}

require_owner_user() {
  if ! id "$OWNER" >/dev/null 2>&1; then
    err "Owner user does not exist: ${OWNER}"
    exit 1
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

install_base_packages() {
  log "Installing base dashboard package requirements through InitBox package cache helper."

  require_package_helper

  if ! bash "$PACKAGES_HELPER" install \
    ca-certificates \
    curl \
    git \
    build-essential \
    cmake \
    libjson-c-dev \
    libwebsockets-dev \
    iptables \
    python3 2>&1 | tee -a "$LOGFILE"; then
    err "Base dashboard package installation failed."
    err "If this Pi is offline, prepare the package cache first with:"
    err "  sudo ./scripts/initbox-installer.sh pi-3-4-5 p"
    exit 1
  fi
}

node_major_version() {
  local version=""

  if ! command -v node >/dev/null 2>&1; then
    echo 0
    return 0
  fi

  version="$(node -v 2>/dev/null || true)"
  version="${version#v}"
  version="${version%%.*}"

  if [[ "$version" =~ ^[0-9]+$ ]]; then
    echo "$version"
  else
    echo 0
  fi
}

node_version_is_supported() {
  local major=""

  major="$(node_major_version)"
  [ "$major" -ge "$MIN_NODE_MAJOR" ]
}

install_nodejs_22() {
  if node_version_is_supported; then
    log "Node.js already meets requirement: $(node -v 2>/dev/null || echo unknown)"
    return 0
  fi

  if ! have_internet; then
    err "Node.js is missing or too old, and Internet is unavailable."
    err "Current Node.js: $(node -v 2>/dev/null || echo missing)"
    err "Required Node.js major version: ${MIN_NODE_MAJOR}+"
    exit 1
  fi

  log "Installing/upgrading Node.js 22 using NodeSource."

  if ! curl -fsSL https://deb.nodesource.com/setup_22.x | bash - 2>&1 | tee -a "$LOGFILE"; then
    err "NodeSource setup failed."
    exit 1
  fi

  if ! DEBIAN_FRONTEND=noninteractive apt-get -o Dpkg::Use-Pty=0 install -y nodejs 2>&1 | tee -a "$LOGFILE"; then
    err "Node.js 22 installation failed."
    exit 1
  fi

  if ! node_version_is_supported; then
    err "Node.js is still too old after installation: $(node -v 2>/dev/null || echo missing)"
    err "Required Node.js major version: ${MIN_NODE_MAJOR}+"
    exit 1
  fi

  ok "Node.js installed/upgraded: $(node -v 2>/dev/null || echo unknown)"
}

restore_ttyd_from_cache() {
  if command -v ttyd >/dev/null 2>&1; then
    log "ttyd already installed at $(command -v ttyd)"
    return 0
  fi

  if [ -x "$TTYD_CACHE_BIN" ]; then
    log "Restoring ttyd from local cache: ${TTYD_CACHE_BIN}"
    install -m 0755 "$TTYD_CACHE_BIN" /usr/local/bin/ttyd
    ok "ttyd restored to /usr/local/bin/ttyd"
    return 0
  fi

  return 1
}

cache_installed_ttyd() {
  local ttyd_bin=""

  ttyd_bin="$(command -v ttyd || true)"

  if [ -z "$ttyd_bin" ]; then
    return 1
  fi

  prepare_dashboard_cache
  install -m 0755 "$ttyd_bin" "$TTYD_CACHE_BIN"
  ok "Cached ttyd binary at ${TTYD_CACHE_BIN}"
}

build_ttyd_from_git() {
  local tmp=""

  if restore_ttyd_from_cache; then
    return 0
  fi

  if ! have_internet; then
    warn "No Internet and no cached ttyd binary found."
    warn "Web Terminal will be skipped until ttyd is built once in the lab."
    return 1
  fi

  log "Building ttyd from GitHub source and caching binary."

  tmp="$(mktemp -d)"

  if ! git clone https://github.com/tsl0922/ttyd.git "$tmp/ttyd" >>"$LOGFILE" 2>&1; then
    warn "git clone for ttyd failed; skipping web terminal."
    rm -rf "$tmp"
    return 1
  fi

  mkdir -p "$tmp/ttyd/build"

  if ! (
    cd "$tmp/ttyd/build"
    {
      cmake ..
      make -j"$(nproc)"
      make install
    } >>"$LOGFILE" 2>&1
  ); then
    warn "ttyd build/install failed; skipping web terminal."
    rm -rf "$tmp"
    return 1
  fi

  rm -rf "$tmp"

  cache_installed_ttyd || true
  ok "ttyd installed at $(command -v ttyd || echo /usr/local/bin/ttyd)"
  return 0
}

emit_ttyd_service() {
  local ttyd_bin=""

  ttyd_bin="$(command -v ttyd || true)"

  if [ -z "$ttyd_bin" ]; then
    warn "ttyd binary not found; skipping ttyd.service creation."
    return 0
  fi

  log "Installing ttyd.service."

  cat >/etc/systemd/system/ttyd.service <<EOF
[Unit]
Description=InitBox ttyd web terminal
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${OWNER}
Group=${OWNER}
ExecStart=${ttyd_bin} -p ${TTYD_PORT} --writable -i 0.0.0.0 bash -l
Restart=on-failure
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
}

install_ttyd() {
  if ! build_ttyd_from_git; then
    warn "ttyd build/restore failed or skipped; continuing without web terminal."
    return 0
  fi

  emit_ttyd_service
}

enforce_pi_nodered_only() {
  log "Enforcing Node-RED service model: pi-nodered.service only."

  systemctl stop nodered.service 2>/dev/null || true
  systemctl disable nodered.service 2>/dev/null || true
  systemctl mask nodered.service 2>/dev/null || true

  if [ -f /etc/systemd/system/nodered.service ]; then
    warn "Removing generated /etc/systemd/system/nodered.service."
    rm -f /etc/systemd/system/nodered.service
  fi

  systemctl daemon-reload

  if systemctl is-active --quiet nodered.service 2>/dev/null; then
    err "nodered.service is still active. InitBox requires pi-nodered.service only."
    return 1
  fi

  ok "nodered.service is stopped/disabled/masked. InitBox will use pi-nodered.service only."
}

prepare_node_red_user_dir() {
  require_owner_user

  install -d -m 0755 -o "$OWNER" -g "$OWNER" "$NODE_RED_USER_DIR"
  install -d -m 0755 -o "$OWNER" -g "$OWNER" "${NODE_RED_USER_DIR}/public"

  chown -R "${OWNER}:${OWNER}" "$NODE_RED_USER_DIR" || true
}

node_red_local_is_installed() {
  [ -x "$NODE_RED_LOCAL_BIN" ]
}

node_red_dashboard_is_installed() {
  if [ ! -d "$NODE_RED_USER_DIR" ]; then
    return 1
  fi

  sudo -H -u "$OWNER" bash -lc 'cd "$HOME/.node-red" 2>/dev/null && npm list node-red-dashboard --depth=0 >/dev/null 2>&1'
}

install_node_red_local() {
  prepare_node_red_user_dir

  if node_red_local_is_installed && node_red_dashboard_is_installed; then
    log "Local Node-RED and node-red-dashboard already installed for ${OWNER}."
    return 0
  fi

  if ! have_internet; then
    err "Node-RED/dashboard npm packages are missing and Internet is unavailable."
    err "Run dashboard install once in the lab with Internet."
    exit 1
  fi

  log "Installing Node-RED and node-red-dashboard locally under ${NODE_RED_USER_DIR}."
  log "This can take several minutes on a Raspberry Pi."

  chown -R "${OWNER}:${OWNER}" "$NODE_RED_USER_DIR" || true

  if ! sudo -H -u "$OWNER" bash <<'EOS' 2>&1 | tee -a "$LOGFILE"
set -euo pipefail

NR_DIR="${HOME}/.node-red"
PUBLIC_DIR="${NR_DIR}/public"

mkdir -p "${PUBLIC_DIR}"
cd "${NR_DIR}"

echo "[npm] user: $(id)"
echo "[npm] home: ${HOME}"
echo "[npm] node: $(node -v 2>/dev/null || echo missing)"
echo "[npm] npm: $(npm -v 2>/dev/null || echo missing)"
echo "[npm] working directory: $(pwd)"

if [ ! -f package.json ]; then
  echo "[npm] creating package.json"
  cat >package.json <<'JSON'
{
  "name": "initbox-node-red",
  "version": "1.0.0",
  "description": "InitBox local Node-RED runtime",
  "private": true,
  "dependencies": {}
}
JSON
fi

echo "[npm] cleaning npm cache metadata"
npm cache verify || true

echo "[npm] installing local Node-RED packages"
npm install --omit=dev --no-audit --no-fund --legacy-peer-deps node-red node-red-dashboard

echo "[npm] installed packages:"
npm list --depth=0 || true
EOS
  then
    err "npm install failed for local Node-RED/dashboard packages."
    err "Check the detailed npm output above or in:"
    err "  ${LOGFILE}"
    exit 1
  fi

  chown -R "${OWNER}:${OWNER}" "$NODE_RED_USER_DIR" || true

  if ! node_red_local_is_installed; then
    err "Local Node-RED binary not found after npm install: ${NODE_RED_LOCAL_BIN}"
    exit 1
  fi

  if ! node_red_dashboard_is_installed; then
    err "node-red-dashboard package not found after npm install."
    exit 1
  fi

  ok "Local Node-RED installed: ${NODE_RED_LOCAL_BIN}"
}

install_nodered() {
  log "Installing or reusing InitBox Node-RED."

  enforce_pi_nodered_only
  install_nodejs_22
  install_node_red_local
  enforce_pi_nodered_only

  log "Node.js: $(node -v 2>/dev/null || echo unknown)"
  log "npm: $(npm -v 2>/dev/null || echo unknown)"
  log "Node-RED binary: ${NODE_RED_LOCAL_BIN}"
}

require_repo_dashboard_files() {
  if [ ! -f "$REPO_FLOWS_FILE" ]; then
    err "Required repository flow file missing: ${REPO_FLOWS_FILE}"
    err "Place your approved Node-RED dashboard flow here:"
    err "  scripts/flows.json"
    exit 1
  fi

  if [ ! -f "$REPO_SETTINGS_FILE" ]; then
    err "Required repository settings file missing: ${REPO_SETTINGS_FILE}"
    err "Place your approved Node-RED settings file here:"
    err "  scripts/settings.js"
    exit 1
  fi

  if [ ! -f "$REPO_LOGO_FILE" ]; then
    err "Required repository logo file missing: ${REPO_LOGO_FILE}"
    err "Place your approved dashboard logo here:"
    err "  scripts/logo.png"
    exit 1
  fi
}

deploy_flows_settings() {
  local host=""

  host="$(hostname 2>/dev/null || echo raspberrypi)"

  require_repo_dashboard_files
  prepare_node_red_user_dir

  log "Discarding generated/hostname Node-RED flow files."
  rm -f "${NODE_RED_USER_DIR}/flows_"*.json
  rm -f "${NODE_RED_USER_DIR}/flows_initbox.json"
  rm -f "${NODE_RED_USER_DIR}/flows_dashboard.json"

  log "Deploying approved repository flows.json."
  install -m 0644 -o "$OWNER" -g "$OWNER" "$REPO_FLOWS_FILE" "${NODE_RED_USER_DIR}/flows.json"

  log "Deploying approved repository settings.js."
  install -m 0644 -o "$OWNER" -g "$OWNER" "$REPO_SETTINGS_FILE" "${NODE_RED_USER_DIR}/settings.js"

  log "Deploying approved repository logo.png."
  install -d -m 0755 -o "$OWNER" -g "$OWNER" "${NODE_RED_USER_DIR}/public"
  install -m 0644 -o "$OWNER" -g "$OWNER" "$REPO_LOGO_FILE" "${NODE_RED_USER_DIR}/public/logo.png"

  chown -R "${OWNER}:${OWNER}" "$NODE_RED_USER_DIR" || true

  log "Runtime Node-RED files:"
  log "  ${NODE_RED_USER_DIR}/flows.json"
  log "  ${NODE_RED_USER_DIR}/settings.js"
  log "  ${NODE_RED_USER_DIR}/public/logo.png"
  log "Hostname flow files discarded for host: ${host}"
}

set_mod_flag() {
  local key="$1"
  local value="$2"
  local tmp_file=""

  if [ ! -f "$MODS_FILE" ]; then
    cat >"$MODS_FILE" <<'EOF'
ISI=0
FMS=0
WSBR0=0
HOTSPOT=0
DASHBOARD=0
RTC=0
EOF
  fi

  tmp_file="$(mktemp)"

  if grep -q "^${key}=" "$MODS_FILE"; then
    grep -v "^${key}=" "$MODS_FILE" >"$tmp_file" || true
  else
    cat "$MODS_FILE" >"$tmp_file"
  fi

  printf '%s=%s\n' "$key" "$value" >>"$tmp_file"
  install -m 0644 "$tmp_file" "$MODS_FILE"
  rm -f "$tmp_file"

  chown root:root "$MODS_FILE" 2>/dev/null || true
}

install_initbox_mods() {
  log "Ensuring ${MODS_FILE} exists and marking dashboard available."

  if [ ! -f "$MODS_FILE" ]; then
    cat >"$MODS_FILE" <<'EOF'
ISI=0
FMS=0
WSBR0=0
HOTSPOT=0
DASHBOARD=1
RTC=0
EOF
    chmod 644 "$MODS_FILE"
    chown root:root "$MODS_FILE" 2>/dev/null || true
    log "Created ${MODS_FILE} with default flags."
  else
    set_mod_flag "DASHBOARD" "1"
    log "Updated ${MODS_FILE}: DASHBOARD=1"
  fi
}

install_role_file() {
  log "Ensuring ${ROLE_FILE} exists."

  if [ ! -f "$ROLE_FILE" ]; then
    cat >"$ROLE_FILE" <<'EOF'
# InitBox role file managed by the dashboard.
#
# Supported role words:
#   isi
#   fms
#   sniff
#   wireshark
#   sniffer
#   sniffer-bridge
#
# Example:
#   ROLES="isi fms sniff"

ROLES=""
EOF
    chmod 664 "$ROLE_FILE"
    chown root:"$OWNER" "$ROLE_FILE" 2>/dev/null || chown root:root "$ROLE_FILE" || true
    log "Created ${ROLE_FILE}."
  else
    chmod 664 "$ROLE_FILE" || true
    chown root:"$OWNER" "$ROLE_FILE" 2>/dev/null || true
    log "${ROLE_FILE} already exists; leaving contents unchanged."
  fi
}

install_nodered_service() {
  log "Installing pi-nodered.service."

  enforce_pi_nodered_only

  cat >/etc/systemd/system/pi-nodered.service <<EOF
[Unit]
Description=InitBox Node-RED dashboard controller
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${OWNER}
Group=${OWNER}
WorkingDirectory=/home/${OWNER}
Environment=NODE_OPTIONS=--max-old-space-size=128
Environment=NODE_RED_HOME=${NODE_RED_USER_DIR}
ExecStart=${NODE_RED_LOCAL_BIN} --userDir ${NODE_RED_USER_DIR} --settings ${NODE_RED_USER_DIR}/settings.js
Restart=on-failure
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
}

install_pi_rolectl() {
  log "Writing /usr/local/bin/pi-rolectl.sh."

  cat >/usr/local/bin/pi-rolectl.sh <<'EOF'
#!/usr/bin/env bash
exec /usr/local/bin/pi-servsync.sh "$@"
EOF

  chmod 755 /usr/local/bin/pi-rolectl.sh
  chown root:root /usr/local/bin/pi-rolectl.sh || true
}

install_pi_servsync() {
  log "Writing /usr/local/bin/pi-servsync.sh."

  cat >/usr/local/bin/pi-servsync.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

ROLE_FILE="${ROLE_FILE:-/etc/pi_roles.conf}"

SVC_ISI="isirunall.service"
SVC_FMS="fms.service"
SVC_SNIFF="wireshark-autostart.service"
SVC_BRIDGE="bridge-check.service"

log() {
  echo "[servsync] $*"
  logger -t pi-servsync -- "$*" 2>/dev/null || true
}

read_roles() {
  local role_text=""

  if [ -r "$ROLE_FILE" ]; then
    # shellcheck disable=SC1090
    . "$ROLE_FILE" || true
    role_text="${ROLES:-${roles:-}}"
    role_text="${role_text,,}"
    role_text="${role_text//$'\r'/}"
  fi

  printf '%s' "$role_text"
}

start_enable() {
  local unit="$1"

  systemctl enable --now "$unit" >/dev/null 2>&1 || true
  sleep 0.2

  if systemctl is-active --quiet "$unit"; then
    log "started ${unit}"
  else
    log "failed to start ${unit}"
  fi
}

stop_disable() {
  local unit="$1"

  systemctl stop "$unit" >/dev/null 2>&1 || true
  systemctl disable "$unit" >/dev/null 2>&1 || true

  log "stopped+disabled ${unit}"
}

mode="${1:-apply}"
force_stop=0

case "$mode" in
  stop|stopall|--force-stop)
    force_stop=1
    ;;
  *)
    force_stop=0
    ;;
esac

roles="$(read_roles)"

want_isi=0
want_sniff=0
want_fms=0

if [ "$force_stop" -eq 0 ]; then
  for role_word in $roles; do
    case "$role_word" in
      isi)
        want_isi=1
        ;;
      fms)
        want_fms=1
        ;;
      sniff|wireshark|sniffer|sniffer-bridge)
        want_sniff=1
        ;;
    esac
  done
fi

log "parsed roles='${roles}' -> isi:${want_isi} sniff:${want_sniff} fms:${want_fms}"

if [ "$want_isi" -eq 1 ] || [ "$want_sniff" -eq 1 ]; then
  start_enable "$SVC_BRIDGE"
else
  stop_disable "$SVC_BRIDGE"
fi

if [ "$want_sniff" -eq 1 ]; then
  start_enable "$SVC_SNIFF"
else
  stop_disable "$SVC_SNIFF"
fi

if [ "$want_isi" -eq 1 ]; then
  start_enable "$SVC_ISI"
else
  stop_disable "$SVC_ISI"
fi

if [ "$want_fms" -eq 1 ]; then
  start_enable "$SVC_FMS"
else
  stop_disable "$SVC_FMS"
fi

exit 0
EOF

  chmod 755 /usr/local/bin/pi-servsync.sh
  chown root:root /usr/local/bin/pi-servsync.sh || true
}

detect_hotspot_ip() {
  local detected_ip=""

  if [ -n "$HOTSPOT_IP" ]; then
    printf '%s
' "$HOTSPOT_IP"
    return 0
  fi

  detected_ip="$(ip -4 addr show dev "$HOTSPOT_IFACE" 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1 | head -n 1 || true)"

  if [ -n "$detected_ip" ]; then
    printf '%s
' "$detected_ip"
    return 0
  fi

  err "Could not detect hotspot IP from interface: ${HOTSPOT_IFACE}"
  err "Install/start the hotspot module first, or run with HOTSPOT_IP set explicitly."
  err "Example: sudo HOTSPOT_IP=<hotspot-gateway-ip> ./scripts/pi-3-4-5/module-dashboard.sh install"
  exit 1
}

install_portal() {
  local hotspot_ip=""

  hotspot_ip="$(detect_hotspot_ip)"

  log "Installing dashboard captive portal landing service."
  log "Using hotspot captive portal IP: ${hotspot_ip}"
  log "DNS is not managed by dashboard; hotspot module owns /etc/dnsmasq.d/initbox-hotspot.conf."

  log "Writing ${PORTAL_SCRIPT}."

  cat >"$PORTAL_SCRIPT" <<EOF
#!/usr/bin/env python3
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HOTSPOT_IP = "${hotspot_ip}"
DASHBOARD_PORT = "${DASHBOARD_PORT}"
DASHBOARD_URL = f"http://{HOTSPOT_IP}:{DASHBOARD_PORT}/ui"


class InitBoxPortalHandler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        return

    def _send_landing(self):
        body = f"""<!doctype html>
<html>
  <head>
    <meta charset=\"utf-8\">
    <meta http-equiv=\"refresh\" content=\"0; url={DASHBOARD_URL}\">
    <title>InitBox Dashboard</title>
    <style>
      body {{
        font-family: Arial, sans-serif;
        margin: 2rem;
        background: #111827;
        color: #f9fafb;
      }}
      a {{
        color: #93c5fd;
        font-size: 1.1rem;
      }}
      .card {{
        max-width: 520px;
        padding: 1.5rem;
        border-radius: 12px;
        background: #1f2937;
      }}
    </style>
  </head>
  <body>
    <div class=\"card\">
      <h1>InitBox Dashboard</h1>
      <p>Opening the dashboard UI...</p>
      <p><a href=\"{DASHBOARD_URL}\">Open InitBox Dashboard</a></p>
    </div>
  </body>
</html>
"""
        encoded = body.encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(encoded)))
        self.end_headers()
        self.wfile.write(encoded)

    def _redirect_to_dashboard(self):
        self.send_response(302)
        self.send_header("Location", DASHBOARD_URL)
        self.send_header("Cache-Control", "no-store")
        self.end_headers()

    def do_GET(self):
        # Captive-portal probes and normal landing requests should always
        # open the InitBox dashboard UI.
        self._redirect_to_dashboard()

    def do_HEAD(self):
        self._redirect_to_dashboard()

    def do_POST(self):
        self._redirect_to_dashboard()


def main():
    server = ThreadingHTTPServer(("0.0.0.0", 80), InitBoxPortalHandler)
    server.serve_forever()


if __name__ == "__main__":
    main()
EOF

  chmod 755 "$PORTAL_SCRIPT"
  chown root:root "$PORTAL_SCRIPT" 2>/dev/null || true

  log "Removing old iptables captive redirect rule if present."

  while iptables -t nat -C PREROUTING -i "$HOTSPOT_IFACE" -p tcp --dport 80 \
    -j REDIRECT --to-ports "$DASHBOARD_PORT" 2>/dev/null; do
    iptables -t nat -D PREROUTING -i "$HOTSPOT_IFACE" -p tcp --dport 80 \
      -j REDIRECT --to-ports "$DASHBOARD_PORT" 2>/dev/null || break
  done
}


install_file_transfer_helper() {
  log "Writing /usr/local/bin/initbox-file-transfer.sh."

  cat >/usr/local/bin/initbox-file-transfer.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

HOME_ROOT="/home/initbox"
BIN_ROOT="/usr/local/bin"
CAN_TRC="/usr/local/bin/CAN.trc"

usage() {
  cat <<'USAGE'
Usage:
  initbox-file-transfer.sh list home|bin
  initbox-file-transfer.sh download-path home|bin <relative-file>
  initbox-file-transfer.sh download-can
  initbox-file-transfer.sh delete-home <relative-file>
  initbox-file-transfer.sh upload-home <tmp-file> <original-name>
  initbox-file-transfer.sh install-can-trc <tmp-file> [original-name]
USAGE
}

die() {
  echo "ERR: $*" >&2
  exit 1
}

json_escape() {
  python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))'
}

safe_basename() {
  local name="$1"
  name="${name##*/}"
  name="${name//$'\r'/}"
  name="${name//$'\n'/}"

  if [ -z "$name" ]; then
    die "empty filename"
  fi

  case "$name" in
    .*|*/*|*'..'*)
      die "unsafe filename: $name"
      ;;
  esac

  if ! printf '%s' "$name" | grep -Eq '^[A-Za-z0-9._@+=,-]+$'; then
    die "filename contains unsupported characters: $name"
  fi

  printf '%s\n' "$name"
}

area_root() {
  case "${1:-}" in
    home) printf '%s\n' "$HOME_ROOT" ;;
    bin) printf '%s\n' "$BIN_ROOT" ;;
    *) die "unknown area: ${1:-}" ;;
  esac
}

resolve_existing_file() {
  local area="$1"
  local rel="$2"
  local root=""
  local target=""
  local resolved=""

  root="$(area_root "$area")"

  if [ -z "$rel" ]; then
    die "missing relative path"
  fi

  case "$rel" in
    /*|*'..'*) die "unsafe relative path" ;;
  esac

  target="${root}/${rel}"

  if [ ! -e "$target" ]; then
    die "file does not exist"
  fi

  resolved="$(realpath -e "$target")"

  case "$resolved" in
    "$root"|"$root"/*) ;;
    *) die "path escapes allowed root" ;;
  esac

  if [ ! -f "$resolved" ]; then
    die "not a regular file"
  fi

  printf '%s\n' "$resolved"
}

list_area() {
  local area="$1"
  local root=""

  root="$(area_root "$area")"

  if [ ! -d "$root" ]; then
    printf '[]\n'
    return 0
  fi

  python3 - "$root" <<'PYJSON'
import json
import os
import sys
from pathlib import Path

root = Path(sys.argv[1]).resolve()
items = []

for path in sorted(root.rglob("*")):
    try:
        resolved = path.resolve(strict=True)
    except OSError:
        continue
    if root != resolved and root not in resolved.parents:
        continue
    try:
        st = path.lstat()
    except OSError:
        continue
    rel = str(path.relative_to(root))
    if rel.startswith("."):
        continue
    is_file = path.is_file()
    is_dir = path.is_dir()
    if not is_file and not is_dir:
        continue
    if rel.count(os.sep) > 3:
        continue
    items.append({
        "name": path.name,
        "rel": rel,
        "type": "dir" if is_dir else "file",
        "size": st.st_size if is_file else 0,
        "mtime": int(st.st_mtime),
    })

print(json.dumps(items, separators=(",", ":")))
PYJSON
}

download_path() {
  local area="$1"
  local rel="$2"
  resolve_existing_file "$area" "$rel"
}

download_can() {
  if [ ! -f "$CAN_TRC" ]; then
    die "CAN trace file not found: $CAN_TRC"
  fi
  printf '%s\n' "$CAN_TRC"
}

delete_home() {
  local rel="$1"
  local target=""
  target="$(resolve_existing_file home "$rel")"
  rm -f -- "$target"
  printf '{"ok":true,"deleted":'
  printf '%s' "$rel" | json_escape
  printf '}\n'
}

upload_home() {
  local tmp_file="$1"
  local original_name="$2"
  local safe_name=""
  local dest=""

  [ -f "$tmp_file" ] || die "temporary upload file not found"
  safe_name="$(safe_basename "$original_name")"
  dest="${HOME_ROOT}/${safe_name}"

  install -m 0644 -o initbox -g initbox "$tmp_file" "$dest"
  rm -f -- "$tmp_file" 2>/dev/null || true

  printf '{"ok":true,"path":'
  printf '%s' "$dest" | json_escape
  printf '}\n'
}

install_can_trc() {
  local tmp_file="$1"
  local original_name="${2:-CAN.trc}"

  [ -f "$tmp_file" ] || die "temporary upload file not found"

  case "$original_name" in
    *.trc|*.TRC|CAN.trc|CAN.TRC) ;;
    *) die "CAN upload must be a .trc file" ;;
  esac

  install -m 0644 -o root -g root "$tmp_file" "$CAN_TRC"
  rm -f -- "$tmp_file" 2>/dev/null || true

  if systemctl cat fms.service >/dev/null 2>&1; then
    systemctl restart fms.service >/dev/null 2>&1 || true
  fi

  printf '{"ok":true,"path":"%s","service":"fms.service"}\n' "$CAN_TRC"
}

cmd="${1:-}"
shift || true

case "$cmd" in
  list) list_area "${1:-}" ;;
  download-path) download_path "${1:-}" "${2:-}" ;;
  download-can) download_can ;;
  delete-home) delete_home "${1:-}" ;;
  upload-home) upload_home "${1:-}" "${2:-}" ;;
  install-can-trc) install_can_trc "${1:-}" "${2:-CAN.trc}" ;;
  -h|--help|help|"") usage ;;
  *) die "unknown command: $cmd" ;;
esac
EOF

  chmod 755 /usr/local/bin/initbox-file-transfer.sh
  chown root:root /usr/local/bin/initbox-file-transfer.sh 2>/dev/null || true
}


install_pi_stats() {
  log "Writing /usr/local/bin/pi-stats.sh."

  cat >/usr/local/bin/pi-stats.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

escape_json() {
  local s="${1:-}"

  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  printf '%s' "$s"
}

model="$(tr -d '\0' </proc/device-tree/model 2>/dev/null || echo Unknown)"
serial="$(awk -F: '/Serial/{print $2}' /proc/cpuinfo | xargs || true)"

read -r u1 n1 s1 i1 io1 irq1 sirq1 st1 _ < <(awk '/^cpu /{print $2,$3,$4,$5,$6,$7,$8,$9}' /proc/stat)
sleep 0.5
read -r u2 n2 s2 i2 io2 irq2 sirq2 st2 _ < <(awk '/^cpu /{print $2,$3,$4,$5,$6,$7,$8,$9}' /proc/stat)

total_delta=$(((u2 + n2 + s2 + i2 + io2 + irq2 + sirq2 + st2) - (u1 + n1 + s1 + i1 + io1 + irq1 + sirq1 + st1)))
idle_delta=$((i2 - i1))

cpu_pct="$(awk -v total="$total_delta" -v idle="$idle_delta" 'BEGIN{if(total>0) printf "%.1f", 100*(total-idle)/total; else print "0.0"}')"

mem_total_kb="$(awk '/MemTotal/{print $2}' /proc/meminfo)"
mem_avail_kb="$(awk '/MemAvailable/{print $2}' /proc/meminfo)"
mem_used_pct="$(awk -v total="$mem_total_kb" -v avail="$mem_avail_kb" 'BEGIN{if(total>0) printf "%.1f", 100*(total-avail)/total; else print "0.0"}')"

disk_used_pct="$(df -P / | awk 'NR==2{gsub(/%/,"",$5); print $5}')"
disk_avail_gb="$(df -P -BG / | awk 'NR==2{gsub(/G/,"",$4); print $4}')"

temp_raw="$(cat /sys/class/thermal/thermal_zone0/temp 2>/dev/null || echo 0)"
temp_c="$(awk -v val="$temp_raw" 'BEGIN{printf "%.1f", val/1000}')"
uptime_s="$(awk '{printf "%d",$1}' /proc/uptime)"
load1="$(awk '{print $1}' /proc/loadavg)"

hostname_val="$(hostname 2>/dev/null || echo raspberrypi)"

os_name="Linux"
if [ -r /etc/os-release ]; then
  # shellcheck disable=SC1091
  . /etc/os-release || true
  os_name="${PRETTY_NAME:-${NAME:-Linux}}"
fi

ipaddr="$(ip -4 addr show wlan0 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1 | head -n 1)"
if [ -z "$ipaddr" ]; then
  ipaddr="$(hostname -I 2>/dev/null | awk '{print $1}')"
fi

ssid=""
if [ -r /etc/hostapd/hostapd.conf ]; then
  ssid="$(awk -F= '/^ssid=/{print $2}' /etc/hostapd/hostapd.conf 2>/dev/null | head -n 1)"
fi

if [ -z "$ssid" ]; then
  ssid="$hostname_val"
fi

device_id="$ssid"

printf '{'
printf '"device_id":"%s",' "$(escape_json "$device_id")"
printf '"ip":"%s",' "$(escape_json "$ipaddr")"
printf '"hostname":"%s",' "$(escape_json "$hostname_val")"
printf '"os":"%s",' "$(escape_json "$os_name")"
printf '"model":"%s",' "$(escape_json "$model")"
printf '"serial":"%s",' "$(escape_json "$serial")"
printf '"cpu_pct":%.1f,' "$cpu_pct"
printf '"mem_used_pct":%.1f,' "$mem_used_pct"
printf '"disk_used_pct":%.1f,' "$disk_used_pct"
printf '"disk_avail_gb":%.1f,' "$disk_avail_gb"
printf '"temp_c":%.1f,' "$temp_c"
printf '"uptime_s":%d,' "$uptime_s"
printf '"load1":%.2f' "$load1"
printf '}\n'
EOF

  chmod 755 /usr/local/bin/pi-stats.sh
  chown root:root /usr/local/bin/pi-stats.sh || true
}

install_services() {
  log "Installing pi-servsync.service."

  cat >/etc/systemd/system/pi-servsync.service <<EOF
[Unit]
Description=Apply /etc/pi_roles.conf to InitBox services
After=multi-user.target
Wants=multi-user.target

[Service]
Type=simple
ExecStart=/usr/local/bin/pi-servsync.sh
Restart=always
RestartSec=2
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

  log "Installing portal.service."

  cat >"$PORTAL_SERVICE" <<EOF
[Unit]
Description=InitBox dashboard captive portal landing page
After=network-online.target pi-nodered.service
Wants=network-online.target pi-nodered.service

[Service]
Type=simple
ExecStart=${PORTAL_SCRIPT}
Restart=on-failure
RestartSec=3
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
}

enable_and_start_services() {
  log "Enabling and restarting dashboard services."

  enforce_pi_nodered_only

  systemctl daemon-reload

  systemctl enable pi-nodered.service pi-servsync.service portal.service 2>/dev/null || true

  if ! systemctl restart pi-nodered.service; then
    err "pi-nodered.service failed to restart."
    systemctl status pi-nodered.service --no-pager 2>&1 | tee -a "$LOGFILE" || true
    exit 1
  fi

  systemctl restart pi-servsync.service 2>/dev/null || true
  systemctl restart portal.service 2>/dev/null || true

  if [ -f /etc/systemd/system/ttyd.service ]; then
    systemctl enable ttyd.service 2>/dev/null || true
    systemctl restart ttyd.service 2>/dev/null || true
  fi

  enforce_pi_nodered_only
}

install_module() {
  require_root
  prepare_log
  prepare_dashboard_cache

  log "Starting Dashboard module installation."

  install_base_packages
  install_ttyd
  install_nodered
  deploy_flows_settings
  install_initbox_mods
  install_role_file
  install_nodered_service
  install_pi_rolectl
  install_pi_servsync
  install_portal
  install_file_transfer_helper
  install_pi_stats
  install_services
  enable_and_start_services

  ok "Dashboard module installed."
  ok "Dashboard landing page: http://initbox.wlan/"
  ok "Node-RED dashboard: http://initbox.wlan:${DASHBOARD_PORT}/ui"
  ok "Web terminal: embedded in dashboard UI; ttyd backend port ${TTYD_PORT}"
  ok "Role file: ${ROLE_FILE}"
  ok "Dashboard cache: ${DASHBOARD_CACHE_DIR}"
  ok "Node-RED runtime: ${NODE_RED_USER_DIR}"
  ok "Only Node-RED service enabled by InitBox: pi-nodered.service"
}

uninstall_module() {
  require_root
  prepare_log

  log "Uninstalling Dashboard module."

  systemctl stop nodered.service 2>/dev/null || true
  systemctl disable nodered.service 2>/dev/null || true
  systemctl mask nodered.service 2>/dev/null || true

  systemctl stop portal.service 2>/dev/null || true
  systemctl disable portal.service 2>/dev/null || true

  systemctl stop pi-servsync.service 2>/dev/null || true
  systemctl disable pi-servsync.service 2>/dev/null || true

  systemctl stop pi-nodered.service 2>/dev/null || true
  systemctl disable pi-nodered.service 2>/dev/null || true

  systemctl stop ttyd.service 2>/dev/null || true
  systemctl disable ttyd.service 2>/dev/null || true

  rm -f /etc/systemd/system/portal.service
  rm -f /etc/systemd/system/pi-servsync.service
  rm -f /etc/systemd/system/pi-nodered.service
  rm -f /etc/systemd/system/ttyd.service
  rm -f /etc/systemd/system/nodered.service

  rm -f /usr/local/bin/portal.sh
  rm -f "$PORTAL_SCRIPT"
  rm -f /usr/local/bin/pi-servsync.sh
  rm -f /usr/local/bin/pi-rolectl.sh
  rm -f /usr/local/bin/pi-stats.sh
  rm -f /usr/local/bin/initbox-file-transfer.sh

  rm -f "${NODE_RED_USER_DIR}/flows.json"
  rm -f "${NODE_RED_USER_DIR}/flows_"*.json
  rm -f "${NODE_RED_USER_DIR}/flows_initbox.json"
  rm -f "${NODE_RED_USER_DIR}/flows_dashboard.json"
  rm -f "${NODE_RED_USER_DIR}/settings.js"
  rm -f "${NODE_RED_USER_DIR}/public/logo.png"

  if [ -f "$MODS_FILE" ]; then
    set_mod_flag "DASHBOARD" "0"
  fi

  systemctl daemon-reload

  ok "Dashboard services and helper scripts removed."
  ok "Runtime flows/settings/logo deployed by this module were removed."
  ok "DASHBOARD flag set to 0 in ${MODS_FILE} when present."
  warn "Node.js, npm packages, ${ROLE_FILE}, ${MODS_FILE}, ttyd binary, and cache files were left in place intentionally."
  warn "nodered.service remains masked so InitBox cannot accidentally run Node-RED as root."
}

usage() {
  cat <<EOF
Usage:
  sudo ./scripts/pi-3-4-5/module-dashboard.sh [install|uninstall|purge]

Actions:
  install    Install/update dashboard services
  uninstall  Remove dashboard services and helper scripts created by this module
  purge      Compatibility alias for uninstall; packages are not purged

Required repository files:
  ${REPO_FLOWS_FILE}
  ${REPO_SETTINGS_FILE}
  ${REPO_LOGO_FILE}

Runtime Node-RED files:
  ${NODE_RED_USER_DIR}/flows.json
  ${NODE_RED_USER_DIR}/settings.js
  ${NODE_RED_USER_DIR}/public/logo.png

Service model:
  InitBox uses pi-nodered.service only.
  nodered.service is stopped, disabled, masked, and not used.

Package cache:
  This module uses:
    scripts/lib/packages.sh

  To prepare Debian package cache in the lab:
    sudo ./scripts/initbox-installer.sh pi-3-4-5 p

Dashboard asset cache:
  ${DASHBOARD_CACHE_DIR}

Cached assets:
  ${TTYD_CACHE_BIN}

Role file:
  ${ROLE_FILE}

File transfer helper:
  /usr/local/bin/initbox-file-transfer.sh


Captive portal model:
  Dashboard owns portal.service and /usr/local/bin/initbox-dashboard-portal.py.
  Hotspot owns dnsmasq and /etc/dnsmasq.d/initbox-hotspot.conf.
  This dashboard module does not write DNS configuration.

Supported role words:
  isi
  fms
  sniff
  wireshark
  sniffer
  sniffer-bridge
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
