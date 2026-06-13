#!/usr/bin/env bash

# InitBox Raspberry Pi 3 / 4 / 5 dashboard module
#
# Installs:
#   - Node-RED dashboard controller
#   - ttyd web terminal
#   - captive portal redirect to Node-RED
#   - role sync helper using /etc/pi_roles.conf
#   - Pi stats helper for dashboard use
#
# Package/cache model:
#   - Uses scripts/lib/packages.sh for Debian packages.
#   - With Internet: installs packages and keeps them cached.
#   - Without Internet: installs Debian packages from local cache only.
#   - ttyd is built once, installed, and cached locally for future reruns.
#   - Node-RED installer script is downloaded once and cached locally.
#   - Node.js and npm are owned by the official Node-RED installer, not by Debian apt cache.
#   - If Node-RED and node-red-dashboard are already installed with a supported Node.js,
#     offline reruns reuse them.
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
NODE_RED_INSTALLER_CACHE="${NODE_RED_INSTALLER_CACHE:-${DASHBOARD_CACHE_DIR}/install-update-nodered-deb.sh}"
NODE_RED_INSTALLER_URL="${NODE_RED_INSTALLER_URL:-https://github.com/node-red/linux-installers/releases/latest/download/install-update-nodered-deb}"
NODE_RED_INSTALLER_FALLBACK_URL="${NODE_RED_INSTALLER_FALLBACK_URL:-https://raw.githubusercontent.com/node-red/linux-installers/master/deb/update-nodejs-and-nodered}"

MIN_NODE_MAJOR="${MIN_NODE_MAJOR:-22}"

LOG_DIR="/home/${OWNER}/pi_logs"
LOGFILE="${LOGFILE:-${LOG_DIR}/initbox-install.log}"

ROLE_FILE="${ROLE_FILE:-/etc/pi_roles.conf}"
MODS_FILE="${MODS_FILE:-/etc/initbox-mods.conf}"

TTYD_PORT="${TTYD_PORT:-7681}"
DASHBOARD_PORT="${DASHBOARD_PORT:-1880}"
HOTSPOT_IFACE="${HOTSPOT_IFACE:-wlan0}"

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
}

have_internet() {
  ping -c 1 -W 1 8.8.8.8 >/dev/null 2>&1
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
    iptables 2>&1 | tee -a "$LOGFILE"; then
    err "Base dashboard package installation failed."
    err "If this Pi is offline, prepare the package cache first with:"
    err "  sudo ./scripts/initbox-installer.sh pi-3-4-5 p"
    exit 1
  fi
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

node_red_is_installed() {
  command -v node-red >/dev/null 2>&1
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

node_red_needs_installer() {
  if ! node_red_is_installed; then
    return 0
  fi

  if ! node_version_is_supported; then
    warn "Installed Node.js is too old for current Node-RED: $(node -v 2>/dev/null || echo missing)"
    warn "Node.js must be major version ${MIN_NODE_MAJOR} or newer."
    return 0
  fi

  return 1
}

node_red_dashboard_is_installed() {
  local nr_dir="/home/${OWNER}/.node-red"

  if [ ! -d "$nr_dir" ]; then
    return 1
  fi

  su - "$OWNER" -s /bin/bash -c "cd \"\$HOME/.node-red\" 2>/dev/null && npm list node-red-dashboard --depth=0 >/dev/null 2>&1"
}

download_node_red_installer_once() {
  local url=""

  prepare_dashboard_cache

  if [ -f "$NODE_RED_INSTALLER_CACHE" ]; then
    log "Node-RED installer script already cached: ${NODE_RED_INSTALLER_CACHE}"
    chmod 755 "$NODE_RED_INSTALLER_CACHE" || true
    return 0
  fi

  if ! have_internet; then
    warn "No Internet and Node-RED installer script is not cached."
    return 1
  fi

  log "Downloading Node-RED installer script once to ${NODE_RED_INSTALLER_CACHE}."

  for url in \
    "$NODE_RED_INSTALLER_URL" \
    "$NODE_RED_INSTALLER_FALLBACK_URL"; do
    log "Trying Node-RED installer URL: ${url}"

    if curl -fsSL "$url" -o "$NODE_RED_INSTALLER_CACHE"; then
      chmod 755 "$NODE_RED_INSTALLER_CACHE"
      ok "Cached Node-RED installer script."
      return 0
    fi

    rm -f "$NODE_RED_INSTALLER_CACHE"
    warn "Failed to download Node-RED installer from: ${url}"
  done

  err "Failed to download Node-RED installer from all known URLs."
  return 1
}

run_node_red_installer() {
  if [ ! -x "$NODE_RED_INSTALLER_CACHE" ]; then
    err "Node-RED installer cache is not executable: ${NODE_RED_INSTALLER_CACHE}"
    return 1
  fi

  if ! have_internet && ! node_red_is_installed; then
    err "Node-RED is not installed and Internet is unavailable."
    err "Run this module once in the lab with Internet so Node-RED is installed and retained."
    return 1
  fi

  if ! have_internet && ! node_version_is_supported; then
    err "Node.js is too old and Internet is unavailable."
    err "Reconnect in the lab and rerun dashboard so the official Node-RED installer can upgrade Node.js."
    return 1
  fi

  log "Running cached official Node-RED installer: ${NODE_RED_INSTALLER_CACHE}"
  log "Use target user when prompted: ${OWNER}"

  if [ -e /dev/tty ]; then
    if ! bash "$NODE_RED_INSTALLER_CACHE" </dev/tty; then
      err "Node-RED installer failed."
      return 1
    fi
  else
    warn "No /dev/tty available; running Node-RED installer non-interactively."
    if ! bash "$NODE_RED_INSTALLER_CACHE"; then
      err "Node-RED installer failed in non-interactive mode."
      return 1
    fi
  fi
}

install_node_red_dashboard_package() {
  install -d -m 0755 -o "$OWNER" -g "$OWNER" "/home/${OWNER}/.node-red"

  if node_red_dashboard_is_installed; then
    log "node-red-dashboard already installed for ${OWNER}; reusing existing install."
    return 0
  fi

  if ! have_internet; then
    err "node-red-dashboard is not installed and Internet is unavailable."
    err "Install dashboard once in the lab with Internet so npm dependencies remain on the Pi."
    return 1
  fi

  log "Installing node-red-dashboard npm package for ${OWNER}."

  su - "$OWNER" -s /bin/bash <<'EOS'
set -euo pipefail

NR_DIR="${HOME}/.node-red"
PUBLIC_DIR="${NR_DIR}/public"

mkdir -p "${PUBLIC_DIR}"
cd "${NR_DIR}"

if [ -f "${HOME}/logo.png" ]; then
  cp -f "${HOME}/logo.png" "${PUBLIC_DIR}/logo.png"
fi

if [ ! -f package.json ]; then
  npm init -y >/dev/null 2>&1 || true
fi

npm install --unsafe-perm node-red-dashboard
EOS
}

install_nodered() {
  log "Installing or reusing Node-RED."

  if node_red_needs_installer; then
    download_node_red_installer_once
    run_node_red_installer
  else
    log "Node-RED already installed with supported Node.js."
    log "Node.js: $(node -v 2>/dev/null || echo unknown)"
    log "Node-RED: $(node-red --version 2>&1 | head -n 1)"
  fi

  if ! node_red_is_installed; then
    err "node-red command not found after install/reuse step."
    return 1
  fi

  if ! node_version_is_supported; then
    err "Node.js is still too old after Node-RED installer: $(node -v 2>/dev/null || echo missing)"
    err "Expected Node.js major version ${MIN_NODE_MAJOR} or newer."
    return 1
  fi

  log "Node.js after install/reuse: $(node -v 2>/dev/null || echo unknown)"
  log "Node-RED after install/reuse: $(node-red --version 2>&1 | head -n 1)"

  if systemctl list-unit-files | grep -q '^nodered\.service'; then
    log "Disabling upstream nodered.service; InitBox uses pi-nodered.service."
    systemctl disable --now nodered.service 2>/dev/null || true
  fi

  install_node_red_dashboard_package
}

deploy_flows_settings() {
  local nr_dir="/home/${OWNER}/.node-red"
  local host=""
  local flows_src=""

  host="$(hostname 2>/dev/null || echo raspberrypi)"

  if [ -f "${SCRIPT_DIR}/flows_initbox.json" ]; then
    flows_src="${SCRIPT_DIR}/flows_initbox.json"
  elif [ -f "${SCRIPT_DIR}/flows_dashboard.json" ]; then
    flows_src="${SCRIPT_DIR}/flows_dashboard.json"
  elif [ -f "${SCRIPT_DIR}/flows.json" ]; then
    flows_src="${SCRIPT_DIR}/flows.json"
  fi

  install -d -m 0755 -o "$OWNER" -g "$OWNER" "$nr_dir"

  if [ -n "$flows_src" ]; then
    log "Deploying Node-RED flows from $(basename "$flows_src")."
    install -m 0644 "$flows_src" "${nr_dir}/flows_initbox.json"
    install -m 0644 "$flows_src" "${nr_dir}/flows_${host}.json"
  else
    log "No flows_initbox.json/flows_dashboard.json/flows.json found; leaving default flows."
  fi

  if [ -f "${SCRIPT_DIR}/settings.js" ]; then
    log "Deploying Node-RED settings.js."
    install -m 0644 "${SCRIPT_DIR}/settings.js" "${nr_dir}/settings.js"
  else
    log "No custom settings.js found; using default Node-RED settings."
  fi

  chown -R "${OWNER}:${OWNER}" "$nr_dir" || true
}

install_initbox_mods() {
  log "Ensuring ${MODS_FILE} exists."

  if [ ! -f "$MODS_FILE" ]; then
    cat >"$MODS_FILE" <<'EOF'
ISI=0
FMS=0
WSBR0=0
DASHBOARD=1
EOF
    chmod 644 "$MODS_FILE"
    log "Created ${MODS_FILE} with default flags."
  else
    log "${MODS_FILE} already exists; leaving contents unchanged."
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
ExecStart=/bin/bash -lc 'exec node-red'
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

install_portal() {
  log "Writing /usr/local/bin/portal.sh."

  cat >/usr/local/bin/portal.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

IFACE="${1:-wlan0}"
DASHBOARD_PORT="${DASHBOARD_PORT:-1880}"

if ! iptables -t nat -C PREROUTING -i "$IFACE" -p tcp --dport 80 \
  -j REDIRECT --to-ports "$DASHBOARD_PORT" 2>/dev/null; then
  iptables -t nat -A PREROUTING -i "$IFACE" -p tcp --dport 80 \
    -j REDIRECT --to-ports "$DASHBOARD_PORT"
fi
EOF

  chmod 755 /usr/local/bin/portal.sh
  chown root:root /usr/local/bin/portal.sh || true
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

  cat >/etc/systemd/system/portal.service <<EOF
[Unit]
Description=InitBox captive portal redirect (${HOTSPOT_IFACE}:80 -> ${DASHBOARD_PORT})
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/portal.sh ${HOTSPOT_IFACE}
RemainAfterExit=yes
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_RAW
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_RAW
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
}

enable_and_start_services() {
  log "Enabling and restarting dashboard services."

  systemctl daemon-reload

  systemctl enable pi-nodered.service pi-servsync.service portal.service 2>/dev/null || true
  systemctl restart pi-nodered.service 2>/dev/null || true
  systemctl restart pi-servsync.service 2>/dev/null || true
  systemctl restart portal.service 2>/dev/null || true

  if [ -f /etc/systemd/system/ttyd.service ]; then
    systemctl enable ttyd.service 2>/dev/null || true
    systemctl restart ttyd.service 2>/dev/null || true
  fi
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
  install_pi_stats
  install_services
  enable_and_start_services

  ok "Dashboard module installed."
  ok "Node-RED dashboard: http://initbox.wlan:${DASHBOARD_PORT}/ui"
  ok "Web terminal: http://initbox.wlan:${TTYD_PORT}"
  ok "Role file: ${ROLE_FILE}"
  ok "Dashboard cache: ${DASHBOARD_CACHE_DIR}"
}

uninstall_module() {
  require_root
  prepare_log

  log "Uninstalling Dashboard module."

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

  rm -f /usr/local/bin/portal.sh
  rm -f /usr/local/bin/pi-servsync.sh
  rm -f /usr/local/bin/pi-rolectl.sh
  rm -f /usr/local/bin/pi-stats.sh

  systemctl daemon-reload

  ok "Dashboard services and helper scripts removed."
  warn "Node-RED, ttyd, npm packages, ${ROLE_FILE}, ${MODS_FILE}, and cache files were left in place intentionally."
}

usage() {
  cat <<EOF
Usage:
  sudo ./scripts/pi-3-4-5/module-dashboard.sh [install|uninstall|purge]

Actions:
  install    Install/update dashboard services
  uninstall  Remove dashboard services and helper scripts
  purge      Compatibility alias for uninstall; packages are not purged

Package cache:
  This module uses:
    scripts/lib/packages.sh

  To prepare Debian package cache in the lab:
    sudo ./scripts/initbox-installer.sh pi-3-4-5 p

Dashboard asset cache:
  ${DASHBOARD_CACHE_DIR}

Cached assets:
  ${TTYD_CACHE_BIN}
  ${NODE_RED_INSTALLER_CACHE}

Node-RED note:
  Node.js and npm are managed by the official Node-RED installer.

Role file:
  ${ROLE_FILE}

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
