#!/usr/bin/env bash
# InitBox Raspberry Pi 3 / 4 / 5 / CM4 / CM5 React Dashboard module.
#
# Dashboard-only responsibilities:
#   - install the prebuilt React UI from frontend/dist when running from repo
#     or validate the already-synced UI under /usr/local/share/initbox
#   - install the Python standard-library dashboard API
#   - create dashboard authentication
#   - create and start initbox-dashboard.service on port 8080
#   - install dashboard-specific helper scripts used by the API/UI
#   - mark DASHBOARD=1 in /etc/initbox/dashboard-modules.env
#   - switch the shared Web Terminal portal target to dashboard
#
# Explicitly NOT owned here:
#   - ttyd.service and the ttyd binary
#   - the port-80 captive socket/responder
#   - /etc/pi_roles.conf and pi-servsync.service
#   - ISI/FMS/sniffer/hotspot/RTC services
#   - React build tooling, Node.js, npm, or Vite
set -euo pipefail

ACTION="${1:-install}"

: "${OWNER:=initbox}"
: "${LOGFILE:=/home/${OWNER}/pi_logs/initbox-install.log}"
: "${DASHBOARD_PORT:=8080}"
: "${DASHBOARD_AUTH_USER:=initbox}"
: "${DASHBOARD_STATIC_PASSWORD:=TomatoH34d}"
: "${DASHBOARD_AUTH_FILE:=/etc/initbox/dashboard-auth.env}"
: "${ROLE_FILE:=/etc/pi_roles.conf}"
: "${MODS_FILE:=/etc/initbox/dashboard-modules.env}"
: "${DASHBOARD_UI_DIR:=/usr/local/share/initbox/dashboard/ui}"
: "${DASHBOARD_API_DST:=/usr/local/bin/initbox-dashboard-api.py}"
: "${DASHBOARD_SERVICE:=/etc/systemd/system/initbox-dashboard.service}"
: "${PORTAL_TARGET_HELPER:=/usr/local/sbin/initbox-portal-target}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${INITBOX_REPO_ROOT:-$(cd "$SCRIPT_DIR/../.." && pwd)}"
PACKAGES_LIB_FILE="$REPO_ROOT/scripts/lib/packages.sh"
INITBOX_PACKAGES_FILE="${INITBOX_PACKAGES_FILE:-$REPO_ROOT/scripts/packages/pi-full.txt}"
INITBOX_PACKAGE_CACHE_ROOT="${INITBOX_PACKAGE_CACHE_ROOT:-/opt/initbox/packages}"
INITBOX_PACKAGE_CACHE_DIR="${INITBOX_PACKAGE_CACHE_DIR:-${INITBOX_PACKAGE_CACHE_ROOT}/apt}"

DASHBOARD_API_SRC="${DASHBOARD_API_SRC:-$REPO_ROOT/backend/initbox_dashboard_api.py}"
REPO_UI_DIST="${REPO_UI_DIST:-$REPO_ROOT/frontend/dist}"
PI_STATS_SCRIPT="/usr/local/bin/pi-stats.sh"
FILE_TRANSFER_HELPER="/usr/local/bin/initbox-file-transfer.sh"
OLD_DASHBOARD_ROOT="/opt/initbox-dashboard"
OLD_PORTAL_SERVICE="/etc/systemd/system/portal.service"
OLD_PORTAL_SCRIPT="/usr/local/bin/initbox-dashboard-portal.py"

ts() {
  date '+%Y-%m-%d %H:%M:%S'
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

fail() {
  echo "[DASH $(ts)] [ERR] $*" | tee -a "$LOGFILE" >&2
  exit 1
}

require_root() {
  if [ "$(id -u)" -ne 0 ]; then
    fail "this module must be run as root"
  fi
}

ensure_log_dir() {
  install -d -m 0755 "$(dirname "$LOGFILE")"
  touch "$LOGFILE"
  if id "$OWNER" >/dev/null 2>&1; then
    chown "$OWNER:$OWNER" "$LOGFILE" 2>/dev/null || true
  fi
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
  log "Installing Dashboard runtime package requirements through InitBox package cache"
  log "packages file: $INITBOX_PACKAGES_FILE"
  log "cache dir:     $INITBOX_PACKAGE_CACHE_DIR"

  load_package_helper
  initbox_packages_install \
    "$INITBOX_PACKAGES_FILE" \
    "$INITBOX_PACKAGE_CACHE_DIR" \
    python3
}

require_runtime_control() {
  if [ ! -x /usr/local/bin/pi-servsync.sh ]; then
    fail "runtime-control is not installed: /usr/local/bin/pi-servsync.sh is missing"
  fi

  if [ ! -f "$MODS_FILE" ]; then
    fail "runtime-control module flags file is missing: $MODS_FILE"
  fi

  if [ ! -f "$ROLE_FILE" ]; then
    fail "runtime-control role file is missing: $ROLE_FILE"
  fi
}

require_web_terminal_portal() {
  if [ ! -x "$PORTAL_TARGET_HELPER" ]; then
    fail "Web Terminal portal helper is missing: $PORTAL_TARGET_HELPER. Install web-terminal first."
  fi

  if ! systemctl cat ttyd.service >/dev/null 2>&1; then
    fail "ttyd.service is missing. Install web-terminal first."
  fi
}

set_mod_flag() {
  local key="$1"
  local value="$2"
  local tmp_file=""

  install -d -m 0755 "$(dirname "$MODS_FILE")"

  if [ ! -f "$MODS_FILE" ]; then
    cat >"$MODS_FILE" <<'EOF_FLAGS'
ISI=0
FMS=0
WSBR0=0
HOTSPOT=0
DASHBOARD=0
RTC=0
EOF_FLAGS
  fi

  tmp_file="$(mktemp "$(dirname "$MODS_FILE")/.dashboard-modules.XXXXXX")"
  grep -v "^${key}=" "$MODS_FILE" >"$tmp_file" || true
  printf '%s=%s\n' "$key" "$value" >>"$tmp_file"
  install -m 0644 -o root -g root "$tmp_file" "$MODS_FILE"
  rm -f "$tmp_file"
}

install_dashboard_auth() {
  local password="$DASHBOARD_STATIC_PASSWORD"

  log "Writing dashboard authentication file: $DASHBOARD_AUTH_FILE"
  install -d -m 0755 "$(dirname "$DASHBOARD_AUTH_FILE")"
  rm -f "$DASHBOARD_AUTH_FILE"

  DASHBOARD_AUTH_USER="$DASHBOARD_AUTH_USER" DASHBOARD_PASSWORD="$password" python3 - "$DASHBOARD_AUTH_FILE" <<'PY_AUTH'
import hashlib
import os
import secrets
import sys

path = sys.argv[1]
user = os.environ['DASHBOARD_AUTH_USER']
password = os.environ['DASHBOARD_PASSWORD']
salt = secrets.token_hex(16)
digest = hashlib.sha256((salt + password).encode('utf-8')).hexdigest()
secret = secrets.token_urlsafe(32)

with open(path, 'w', encoding='utf-8') as f:
    f.write('# InitBox React dashboard authentication. Managed by module-dashboard.sh.\n')
    f.write(f'# Username: {user}\n')
    f.write('# Password: static repo-configured dashboard password\n')
    f.write(f"INITBOX_DASHBOARD_USER='{user}'\n")
    f.write(f"INITBOX_DASHBOARD_PASSWORD_SALT='{salt}'\n")
    f.write(f"INITBOX_DASHBOARD_PASSWORD_SHA256='{digest}'\n")
    f.write(f"INITBOX_DASHBOARD_SESSION_SECRET='{secret}'\n")
PY_AUTH

  chmod 0640 "$DASHBOARD_AUTH_FILE"
  chown root:"$OWNER" "$DASHBOARD_AUTH_FILE" 2>/dev/null || chown root:root "$DASHBOARD_AUTH_FILE" 2>/dev/null || true
  ok "Dashboard auth configured for user: $DASHBOARD_AUTH_USER"
}

resolve_dashboard_api_source() {
  if [ -f "$DASHBOARD_API_SRC" ]; then
    printf '%s\n' "$DASHBOARD_API_SRC"
    return 0
  fi

  if [ -f "$DASHBOARD_API_DST" ]; then
    printf '%s\n' "$DASHBOARD_API_DST"
    return 0
  fi

  return 1
}

install_dashboard_api() {
  local source_path=""

  if ! source_path="$(resolve_dashboard_api_source)"; then
    fail "dashboard API source not found. Expected $DASHBOARD_API_SRC or existing $DASHBOARD_API_DST"
  fi

  log "Installing dashboard API from: $source_path"
  if [ "$(readlink -f "$source_path")" != "$(readlink -f "$DASHBOARD_API_DST" 2>/dev/null || printf '%s' "$DASHBOARD_API_DST")" ]; then
    install -m 0755 -o root -g root "$source_path" "$DASHBOARD_API_DST"
  else
    chmod 0755 "$DASHBOARD_API_DST"
    chown root:root "$DASHBOARD_API_DST" 2>/dev/null || true
  fi

  if ! python3 -m py_compile "$DASHBOARD_API_DST"; then
    fail "dashboard API Python syntax check failed: $DASHBOARD_API_DST"
  fi
}

install_dashboard_ui() {
  local source_dist="$REPO_UI_DIST"

  if [ -f "$source_dist/index.html" ]; then
    log "Installing prebuilt React dashboard UI from: $source_dist"
    install -d -m 0755 "$DASHBOARD_UI_DIR"
    rm -rf "${DASHBOARD_UI_DIR:?}/"*
    cp -a "$source_dist/." "$DASHBOARD_UI_DIR/"
    chown -R root:root "$DASHBOARD_UI_DIR" 2>/dev/null || true
    find "$DASHBOARD_UI_DIR" -type d -exec chmod 0755 {} +
    find "$DASHBOARD_UI_DIR" -type f -exec chmod 0644 {} +
  elif [ -f "$DASHBOARD_UI_DIR/index.html" ]; then
    log "Using already synchronized dashboard UI: $DASHBOARD_UI_DIR"
  else
    fail "prebuilt dashboard UI not found. Expected $source_dist/index.html or $DASHBOARD_UI_DIR/index.html"
  fi

  [ -f "$DASHBOARD_UI_DIR/index.html" ] || fail "dashboard UI index is missing after install"
}

install_pi_stats() {
  log "Writing $PI_STATS_SCRIPT"

  cat >"$PI_STATS_SCRIPT" <<'EOF_STATS'
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

total_delta=$(((u2+n2+s2+i2+io2+irq2+sirq2+st2)-(u1+n1+s1+i1+io1+irq1+sirq1+st1)))
idle_delta=$((i2-i1))
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
time_val="$(date '+%Y-%m-%d %H:%M:%S %Z')"
hostname_val="$(hostname 2>/dev/null || echo raspberrypi)"

os_name="Linux"
if [ -r /etc/os-release ]; then
  # shellcheck disable=SC1091
  . /etc/os-release || true
  os_name="${PRETTY_NAME:-${NAME:-Linux}}"
fi

ipaddr="$(ip -4 addr show wlan0 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1 | head -n 1)"
[ -n "$ipaddr" ] || ipaddr="$(hostname -I 2>/dev/null | awk '{print $1}')"

printf '{'
printf '"device_id":"%s",' "$(escape_json "$hostname_val")"
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
printf '"time":"%s",' "$(escape_json "$time_val")"
printf '"uptime_s":%d,' "$uptime_s"
printf '"load1":%.2f' "$load1"
printf '}\n'
EOF_STATS

  chmod 0755 "$PI_STATS_SCRIPT"
  chown root:root "$PI_STATS_SCRIPT" 2>/dev/null || true
}

install_file_transfer_helper() {
  log "Writing $FILE_TRANSFER_HELPER"

  cat >"$FILE_TRANSFER_HELPER" <<'EOF_FILE_HELPER'
#!/usr/bin/env bash
set -euo pipefail

TRACE_DIR="${TRACE_DIR:-/usr/tracefiles}"
BIN_DIR="${BIN_DIR:-/usr/local/bin}"

list_trace_files() {
  find "$TRACE_DIR" -maxdepth 1 -type f \
    \( -name '*.pcap' -o -name '*.pcapng' -o -name '*.pcap.gz' -o -name '*.pcapng.gz' -o -name '*.zip' \) \
    -printf '%f\n' 2>/dev/null | sort || true
}

list_bin_files() {
  find "$BIN_DIR" -maxdepth 1 -type f \
    \( -name 'CAN.trc' -o -name '*.trc' \) \
    -printf '%f\n' 2>/dev/null | sort || true
}

case "${1:-}" in
  list-trace)
    list_trace_files
    ;;
  list-bin)
    list_bin_files
    ;;
  *)
    echo "Usage: initbox-file-transfer.sh list-trace|list-bin" >&2
    exit 2
    ;;
esac
EOF_FILE_HELPER

  chmod 0755 "$FILE_TRANSFER_HELPER"
  chown root:root "$FILE_TRANSFER_HELPER" 2>/dev/null || true
}

write_dashboard_service() {
  log "Writing $DASHBOARD_SERVICE"

  cat >"$DASHBOARD_SERVICE" <<EOF_SERVICE
[Unit]
Description=InitBox React dashboard API
After=network-online.target ttyd.service pi-servsync.service
Wants=network-online.target

[Service]
Type=simple
Environment=INITBOX_DASHBOARD_PORT=${DASHBOARD_PORT}
Environment=INITBOX_DASHBOARD_UI_DIR=${DASHBOARD_UI_DIR}
Environment=INITBOX_DASHBOARD_AUTH_FILE=${DASHBOARD_AUTH_FILE}
Environment=ROLE_FILE=${ROLE_FILE}
Environment=MODS_FILE=${MODS_FILE}
ExecStart=/usr/bin/python3 ${DASHBOARD_API_DST}
Restart=on-failure
RestartSec=3
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF_SERVICE

  chmod 0644 "$DASHBOARD_SERVICE"
  chown root:root "$DASHBOARD_SERVICE" 2>/dev/null || true
}

remove_legacy_dashboard_owned_runtime() {
  log "Removing legacy dashboard-owned portal service if present"
  systemctl disable --now portal.service 2>/dev/null || true
  rm -f "$OLD_PORTAL_SERVICE" "$OLD_PORTAL_SCRIPT"
  rm -rf "$OLD_DASHBOARD_ROOT"
}

switch_portal_target() {
  local target="$1"

  if [ ! -x "$PORTAL_TARGET_HELPER" ]; then
    warn "Portal target helper is missing; cannot switch portal to $target"
    return 1
  fi

  "$PORTAL_TARGET_HELPER" "$target" >/dev/null
  ok "Portal target set to $target"
}

start_dashboard_service() {
  log "Enabling and restarting initbox-dashboard.service"
  systemctl daemon-reload
  systemctl enable --now initbox-dashboard.service
  systemctl restart initbox-dashboard.service
}

validate_dashboard_service() {
  local attempt=""

  for attempt in 1 2 3 4 5; do
    if systemctl is-active --quiet initbox-dashboard.service; then
      if python3 - "$DASHBOARD_PORT" <<'PY_HEALTH' >/dev/null 2>&1; then
import http.client
import json
import sys

port = int(sys.argv[1])
conn = http.client.HTTPConnection('127.0.0.1', port, timeout=2)
conn.request('GET', '/api/health')
resp = conn.getresponse()
body = resp.read().decode('utf-8', errors='replace')
conn.close()
if resp.status != 200:
    raise SystemExit(1)
data = json.loads(body)
if not data.get('ok'):
    raise SystemExit(1)
PY_HEALTH
        ok "Dashboard API health check passed on 127.0.0.1:$DASHBOARD_PORT"
        return 0
      fi
    fi
    sleep 1
  done

  systemctl status initbox-dashboard.service --no-pager || true
  fail "Dashboard service did not become healthy"
}

install_module() {
  require_root
  ensure_log_dir

  log "Starting Dashboard-only module installation"
  install_base_packages
  require_runtime_control
  require_web_terminal_portal
  remove_legacy_dashboard_owned_runtime
  install_dashboard_api
  install_dashboard_ui
  install_dashboard_auth
  install_pi_stats
  install_file_transfer_helper
  write_dashboard_service
  set_mod_flag DASHBOARD 1
  start_dashboard_service
  validate_dashboard_service
  switch_portal_target dashboard

  ok "React Dashboard installed without taking ownership of ttyd, port 80, or runtime-control"
  ok "Dashboard URL: http://initbox.wlan/ or same host on port $DASHBOARD_PORT"
}

uninstall_module() {
  require_root
  ensure_log_dir

  log "Uninstalling Dashboard-only module"
  switch_portal_target terminal || true

  systemctl disable --now initbox-dashboard.service 2>/dev/null || true
  rm -f "$DASHBOARD_SERVICE" "$DASHBOARD_API_DST" "$DASHBOARD_AUTH_FILE" "$PI_STATS_SCRIPT" "$FILE_TRANSFER_HELPER"
  rm -rf "$DASHBOARD_UI_DIR"
  set_mod_flag DASHBOARD 0

  systemctl daemon-reload
  systemctl reset-failed initbox-dashboard.service 2>/dev/null || true

  ok "Dashboard removed. Web Terminal, portal socket, and runtime-control were left intact."
}

usage() {
  cat <<'EOF_USAGE'
Usage:
  sudo module-dashboard.sh [install|uninstall|remove|purge]

This module installs only the React Dashboard service and dashboard-specific
helpers. It does not install ttyd, the port-80 captive portal, runtime-control,
Node.js, npm, or React build tooling.
EOF_USAGE
}

case "$ACTION" in
  install)
    install_module
    ;;
  uninstall|remove)
    uninstall_module
    ;;
  purge)
    warn "purge is treated as uninstall; packages and offline caches are retained"
    uninstall_module
    ;;
  -h|--help|help)
    usage
    ;;
  *)
    fail "unknown action: $ACTION"
    ;;
esac
