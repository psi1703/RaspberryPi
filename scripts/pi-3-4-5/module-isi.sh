#!/usr/bin/env bash

# InitBox Raspberry Pi 3 / 4 / 5 ISI simulator module
#
# Installs:
#   - isirunall.sh
#   - ISI payload files for DRACHE, NIX, and ZEITNEHMER
#   - isirunall.service
#
# Package model:
#   - Uses scripts/lib/packages.sh
#   - With Internet: installs through apt-get and keeps packages cached
#   - Without Internet: installs from local package cache only
#
# Pi 3 / 4 / 5 role model:
#   - Dashboard/Node-RED owns /etc/pi_roles.conf.
#   - isirunall.sh starts only when the role file contains: isi
#   - br0 is managed by bridge-check.service from the sniffer bridge module.
#
# Dashboard module availability model:
#   - This module sets ISI=1 after install.
#   - This module sets ISI=0 after uninstall/purge.
#   - If pi-nodered.service exists, it is restarted after the flag update
#     so the dashboard UI reloads module availability immediately.
#
# Actions:
#   install    Install/update ISI simulator service and payloads
#   uninstall  Disable/remove ISI service and files created by this module
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

ISI_RUNNER="/usr/local/bin/isirunall.sh"
ISI_SERVICE="/etc/systemd/system/isirunall.service"

ISI_FILE_1="/usr/local/bin/isi1.txt"
ISI_FILE_2="/usr/local/bin/isi2.txt"
ISI_FILE_3="/usr/local/bin/isi3.txt"

ROLE_FILE="${ROLE_FILE:-/etc/pi_roles.conf}"

DASHBOARD_FLAGS_FILE="${DASHBOARD_FLAGS_FILE:-}"
NODERED_SERVICE="${NODERED_SERVICE:-pi-nodered.service}"

ts() {
  date +"%Y-%m-%d %H:%M:%S"
}

log() {
  echo "[ISI $(ts)] $*" | tee -a "$LOGFILE"
}

ok() {
  echo "[ISI $(ts)] [OK] $*" | tee -a "$LOGFILE"
}

warn() {
  echo "[ISI $(ts)] [WARN] $*" | tee -a "$LOGFILE" >&2
}

err() {
  echo "[ISI $(ts)] [ERR] $*" | tee -a "$LOGFILE" >&2
}

require_root() {
  if [ "$(id -u)" -ne 0 ]; then
    err "This module must be run as root."
    echo "Run with:"
    echo "  sudo ./scripts/pi-3-4-5/module-isi.sh ${ACTION}"
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

require_package_helper() {
  if [ ! -f "$PACKAGES_HELPER" ]; then
    err "Package helper not found: $PACKAGES_HELPER"
    err "Expected file: scripts/lib/packages.sh"
    exit 1
  fi

  chmod 755 "$PACKAGES_HELPER" 2>/dev/null || true
}

install_packages() {
  log "Installing ISI simulator dependencies through InitBox package cache helper."

  require_package_helper

  if ! bash "$PACKAGES_HELPER" install \
    isc-dhcp-client \
    netcat-openbsd \
    iproute2 2>&1 | tee -a "$LOGFILE"; then
    err "ISI dependency installation failed."
    err "If this Pi is offline, prepare the package cache first with:"
    err "  sudo ./scripts/initbox-installer.sh pi-3-4-5 p"
    exit 1
  fi
}

ensure_role_file() {
  if [ ! -f "$ROLE_FILE" ]; then
    log "Creating ${ROLE_FILE} with no roles enabled."

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
  else
    log "${ROLE_FILE} already exists; leaving contents unchanged."
    chmod 664 "$ROLE_FILE" || true
    chown root:"$OWNER" "$ROLE_FILE" 2>/dev/null || true
  fi
}

dashboard_flags_file_path() {
  local candidate=""

  if [ -n "$DASHBOARD_FLAGS_FILE" ]; then
    printf '%s\n' "$DASHBOARD_FLAGS_FILE"
    return 0
  fi

  for candidate in \
    /etc/initbox/dashboard-modules.env \
    /etc/initbox/dashboard-flags.env \
    /etc/pi-dashboard-modules.env \
    /etc/pi_dashboard_modules.conf; do
    if [ -f "$candidate" ]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done

  printf '%s\n' "/etc/initbox/dashboard-modules.env"
}

ensure_dashboard_flags_file() {
  local flags_file=""
  local flags_dir=""

  flags_file="$(dashboard_flags_file_path)"
  flags_dir="$(dirname "$flags_file")"

  mkdir -p "$flags_dir"

  if [ ! -f "$flags_file" ]; then
    log "Creating dashboard module flags file: ${flags_file}"

    cat >"$flags_file" <<'EOF'
# InitBox dashboard module availability flags
# 1 means the module/control is available in the dashboard.
# 0 means hide or disable the related dashboard control.
FMS=0
WSBR0=0
RTC=0
HOTSPOT=1
DASHBOARD=1
ISI=0
EOF
  fi

  chmod 664 "$flags_file" || true
  chown root:"$OWNER" "$flags_file" 2>/dev/null || true
}

write_dashboard_module_flag() {
  local key="$1"
  local value="$2"
  local flags_file=""
  local tmp_file=""

  ensure_dashboard_flags_file
  flags_file="$(dashboard_flags_file_path)"
  tmp_file="$(mktemp)"

  awk -v key="$key" -v value="$value" '
    BEGIN {
      found = 0
    }

    $0 ~ "^" key "=" {
      print key "=" value
      found = 1
      next
    }

    {
      print
    }

    END {
      if (found == 0) {
        print key "=" value
      }
    }
  ' "$flags_file" >"$tmp_file"

  install -m 0664 "$tmp_file" "$flags_file"
  rm -f "$tmp_file"

  chown root:"$OWNER" "$flags_file" 2>/dev/null || true

  log "Dashboard module flag updated: ${key}=${value} in ${flags_file}"
}

restart_dashboard_if_present() {
  if ! systemctl cat "$NODERED_SERVICE" >/dev/null 2>&1; then
    log "Dashboard Node-RED service not installed; no restart needed."
    return 0
  fi

  if systemctl is-active "$NODERED_SERVICE" >/dev/null 2>&1; then
    log "Restarting ${NODERED_SERVICE} so dashboard UI reloads module flags."
    if systemctl restart "$NODERED_SERVICE"; then
      ok "${NODERED_SERVICE} restarted."
    else
      warn "Failed to restart ${NODERED_SERVICE}."
    fi
    return 0
  fi

  if systemctl is-enabled "$NODERED_SERVICE" >/dev/null 2>&1; then
    log "${NODERED_SERVICE} exists but is not active; starting it so dashboard UI reloads module flags."
    if systemctl restart "$NODERED_SERVICE"; then
      ok "${NODERED_SERVICE} started."
    else
      warn "Failed to start ${NODERED_SERVICE}."
    fi
    return 0
  fi

  log "${NODERED_SERVICE} exists but is disabled/inactive; no dashboard restart needed."
}

write_runner() {
  log "Writing ${ISI_RUNNER}."

  cat >"$ISI_RUNNER" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

BRIDGE="${BRIDGE:-br0}"
ROLE_FILE="${ROLE_FILE:-/etc/pi_roles.conf}"

ISI_FILES=(
  "/usr/local/bin/isi1.txt"
  "/usr/local/bin/isi2.txt"
  "/usr/local/bin/isi3.txt"
)

NAMES=(DRACHE NIX ZEITNEHMER)
NS=(ns1 ns2 ns3)

DRIFT_THRESHOLD="${DRIFT_THRESHOLD:-2}"
TIME_SYNC_INTERVAL="${TIME_SYNC_INTERVAL:-3600}"
BRIDGE_WAIT_SECONDS="${BRIDGE_WAIT_SECONDS:-60}"

DEST_IP=""
NS_IPS=()

log() {
  echo "[ISI $(date +%F_%T)] $*"
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

isi_role_enabled() {
  local roles=""
  local role_word=""

  roles="$(read_roles)"

  if [ -z "$roles" ]; then
    log "No roles found in ${ROLE_FILE}; ISI disabled."
    return 1
  fi

  for role_word in $roles; do
    case "$role_word" in
      isi)
        log "ISI role enabled."
        return 0
        ;;
    esac
  done

  log "ISI role not enabled in ${ROLE_FILE}; roles='${roles}'."
  return 1
}

cleanup_ns() {
  local ns

  for ns in "${NS[@]}"; do
    ip netns del "$ns" 2>/dev/null || true
  done

  ip -o link show | awk -F': ' '{print $2}' | cut -d'@' -f1 |
    grep -E '^veth[0-9]+_(host|ns)$' 2>/dev/null |
    xargs -r -I{} ip link del "{}" 2>/dev/null || true
}

full_cleanup() {
  cleanup_ns
}

trap full_cleanup EXIT

uniq_mac() {
  local seed="$1"
  local hash=""

  hash="$(printf "%s" "$seed" | sha1sum | awk '{print $1}')"
  printf "02:%s:%s:%s:%s:%s\n" "${hash:0:2}" "${hash:2:2}" "${hash:4:2}" "${hash:6:2}" "${hash:8:2}"
}

add_veth_to_br() {
  local idx="$1"
  local ns="$2"
  local ifh="veth${idx}_host"
  local ifn="veth${idx}_ns"

  ip link del "$ifh" 2>/dev/null || true
  ip link del "$ifn" 2>/dev/null || true

  ip link add "$ifh" type veth peer name "$ifn"
  ip link set "$ifh" address "$(uniq_mac "$ifh")"
  ip link set "$ifh" master "$BRIDGE"
  ip link set "$ifh" up

  ip netns add "$ns"
  ip link set "$ifn" netns "$ns"
  ip netns exec "$ns" ip link set lo up
  ip netns exec "$ns" ip link set "$ifn" address "$(uniq_mac "$ifn")"
  ip netns exec "$ns" ip link set "$ifn" up
}

wait_for_bridge() {
  local elapsed=0

  log "Waiting for ${BRIDGE}; bridge-check.service should create it when isi role is enabled."

  while [ "$elapsed" -lt "$BRIDGE_WAIT_SECONDS" ]; do
    if ip link show "$BRIDGE" >/dev/null 2>&1; then
      if ip -br link show "$BRIDGE" | grep -q '\<UP\>'; then
        log "${BRIDGE} is UP."
        return 0
      fi
    fi

    sleep 1
    elapsed=$((elapsed + 1))
  done

  log "ERROR: ${BRIDGE} not available after ${BRIDGE_WAIT_SECONDS}s."
  log "Check: systemctl status bridge-check.service"
  return 1
}

require_commands() {
  if ! command -v dhclient >/dev/null 2>&1; then
    log "ERROR: dhclient missing. Install isc-dhcp-client."
    exit 1
  fi

  if ! command -v nc >/dev/null 2>&1 && ! command -v netcat >/dev/null 2>&1; then
    log "ERROR: nc/netcat missing. Install netcat-openbsd."
    exit 1
  fi

  if ! command -v ip >/dev/null 2>&1; then
    log "ERROR: ip command missing. Install iproute2."
    exit 1
  fi
}

discover_copilot_from_dhcp() {
  local dhcp_out="$1"
  local server_ip=""

  if [ -z "$DEST_IP" ]; then
    server_ip="$(printf '%s\n' "$dhcp_out" | sed -nE 's/.*DHCPACK of [^ ]+ from ([0-9.]+).*/\1/p' | tail -n 1)"

    if [[ "$server_ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
      DEST_IP="$server_ip"
    fi
  fi
}

discover_copilot_from_gateway() {
  local ns="$1"
  local gateway=""

  if [ -z "$DEST_IP" ]; then
    gateway="$(ip netns exec "$ns" ip route show default 2>/dev/null | awk '/^default via /{print $3; exit}')"

    if [[ "$gateway" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
      DEST_IP="$gateway"
    fi
  fi
}

request_dhcp_for_namespace() {
  local ns="$1"
  local idx="$2"
  local ns_ip=""
  local dhcp_out=""

  dhcp_out="$(ip netns exec "$ns" dhclient -4 -1 -v "veth${idx}_ns" 2>&1 || true)"

  if ! printf '%s' "$dhcp_out" | grep -q 'DHCPACK'; then
    log "ERROR: DHCP failed in ${ns}."
    printf '%s\n' "$dhcp_out" | tail -n 20 | while IFS= read -r line; do
      log "dhclient: ${line}"
    done
    exit 1
  fi

  ip netns pids "$ns" 2>/dev/null | while IFS= read -r pid; do
    if ps -p "$pid" -o comm= 2>/dev/null | grep -qx 'dhclient'; then
      kill -TERM "$pid" 2>/dev/null || true
    fi
  done

  ns_ip="$(ip netns exec "$ns" ip -o -4 addr show "veth${idx}_ns" | awk '{print $4}' | cut -d/ -f1 || true)"
  NS_IPS+=("${ns_ip:-}")

  log "${ns} got IP ${ns_ip:-unknown} via DHCP."

  discover_copilot_from_dhcp "$dhcp_out"
  discover_copilot_from_gateway "$ns"
}

start_isi_loop() {
  local ns="$1"
  local file="$2"
  local name="$3"
  local idx="$4"

  log "Starting persistent ISI client ${name} in ${ns} (veth${idx}_ns, ${file})."

  ip netns exec "$ns" bash -lc '
    while true; do
      nc "'"$DEST_IP"'" 51001 < "'"$file"'" || sleep 1
    done
  ' &
}

parse_datetime_response() {
  local response="$1"
  local dt=""

  dt="$(printf '%s\n' "$response" |
    grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}([.][0-9]+)?([Zz]|[+-][0-9]{2}:[0-9]{2})?' |
    head -n 1 || true)"

  if [ -n "$dt" ]; then
    printf 'iso:%s\n' "$dt"
    return 0
  fi

  dt="$(printf '%s\n' "$response" |
    grep -oE '[0-9]{2}\.[0-9]{2}\.[0-9]{4}-[0-9]{2}:[0-9]{2}:[0-9]{2}' |
    head -n 1 || true)"

  if [ -n "$dt" ]; then
    printf 'legacy:%s\n' "$dt"
    return 0
  fi

  return 1
}

run_rtc_sync() {
  local parsed="$1"
  local mode=""
  local value=""
  local rc=0

  mode="${parsed%%:*}"
  value="${parsed#*:}"

  if [ ! -x /usr/local/bin/rtc-sync.sh ]; then
    log "ZEITNEHMER: rtc-sync.sh missing or not executable; skipping time sync."
    return 0
  fi

  case "$mode" in
    iso)
      log "ZEITNEHMER: COPILOT Time_ISO8601=${value}; delegating to rtc-sync.sh."
      if DRIFT_THRESHOLD="$DRIFT_THRESHOLD" /usr/local/bin/rtc-sync.sh --iso8601 "$value"; then
        log "ZEITNEHMER: rtc-sync.sh completed successfully."
      else
        rc=$?
        log "ZEITNEHMER: rtc-sync.sh returned non-zero exit code ${rc}."
      fi
      ;;
    legacy)
      log "ZEITNEHMER: COPILOT DateTime=${value}; delegating to rtc-sync.sh."
      if DRIFT_THRESHOLD="$DRIFT_THRESHOLD" /usr/local/bin/rtc-sync.sh --datetime "$value"; then
        log "ZEITNEHMER: rtc-sync.sh completed successfully."
      else
        rc=$?
        log "ZEITNEHMER: rtc-sync.sh returned non-zero exit code ${rc}."
      fi
      ;;
    *)
      log "ZEITNEHMER: unsupported parsed time mode: ${mode}."
      ;;
  esac
}

run_zeitnehmer_loop() {
  local zeit_ns="${NS[2]}"
  local zeit_file="${ISI_FILES[2]}"
  local now_epoch=0
  local last_time_sync=0
  local time_response=""
  local parsed=""

  log "ZEITNEHMER loop starting in ${zeit_ns}; sync interval=${TIME_SYNC_INTERVAL}s."

  while true; do
    now_epoch="$(date +%s)"

    if ((now_epoch - last_time_sync >= TIME_SYNC_INTERVAL)); then
      last_time_sync="$now_epoch"

      log "ZEITNEHMER: requesting time from COPILOT at ${DEST_IP}."
      log "ZEITNEHMER: request file ${zeit_file}."
      log "ZEITNEHMER: request payload: $(tr '\n' ' ' < "$zeit_file")"

      time_response="$(ip netns exec "$zeit_ns" nc "$DEST_IP" 51001 -w 5 < "$zeit_file" || true)"

      log "ZEITNEHMER: raw response snippet: $(printf '%s' "$time_response" | tr '\n' ' ' | head -c 400)"

      if parsed="$(parse_datetime_response "$time_response")"; then
        run_rtc_sync "$parsed"
      else
        log "ZEITNEHMER: no DateTime or Time_ISO8601 pattern found; skipping sync."
      fi
    else
      ip netns exec "$zeit_ns" nc "$DEST_IP" 51001 < "$zeit_file" >/dev/null 2>&1 ||
        log "ZEITNEHMER: nc send failed during non-sync phase."
    fi

    sleep 1
  done
}

main() {
  local i
  local ns
  local idx

  if ! isi_role_enabled; then
    exit 0
  fi

  require_commands
  wait_for_bridge
  cleanup_ns

  for i in "${!NS[@]}"; do
    ns="${NS[$i]}"
    idx=$((i + 1))

    add_veth_to_br "$idx" "$ns"
    request_dhcp_for_namespace "$ns" "$idx"
  done

  if [ -z "$DEST_IP" ]; then
    log "ERROR: could not determine COPILOT IP from DHCP/gateway."
    exit 1
  fi

  log "COPILOT discovered at ${DEST_IP}."

  start_isi_loop "${NS[0]}" "${ISI_FILES[0]}" "${NAMES[0]}" 1
  start_isi_loop "${NS[1]}" "${ISI_FILES[1]}" "${NAMES[1]}" 2

  run_zeitnehmer_loop
}

main "$@"
EOF

  chmod 755 "$ISI_RUNNER"
  chown root:root "$ISI_RUNNER" || true
}

write_payloads() {
  log "Writing ISI payload files."

  cat >"$ISI_FILE_1" <<'EOF'
<IsiPut><AppName>DRACHE</AppName></IsiPut>
<IsiGet><Items>CurrentSoftwareVersion</Items><Cyclic>1</Cyclic></IsiGet>
EOF

  cat >"$ISI_FILE_2" <<'EOF'
<IsiPut><AppName>NIX</AppName></IsiPut>
<IsiGet><Items>DeviceState</Items><Cyclic>1</Cyclic></IsiGet>
EOF

  cat >"$ISI_FILE_3" <<'EOF'
<IsiPut><AppName>ZEITNEHMER</AppName></IsiPut>
<IsiGet><Items>DateTime,Time_ISO8601</Items><Cyclic>1</Cyclic></IsiGet>
EOF

  chmod 644 "$ISI_FILE_1" "$ISI_FILE_2" "$ISI_FILE_3"
  chown root:root "$ISI_FILE_1" "$ISI_FILE_2" "$ISI_FILE_3" || true
}

write_service() {
  log "Installing isirunall.service."

  cat >"$ISI_SERVICE" <<EOF
[Unit]
Description=InitBox ISI simulator clients over br0
After=network-online.target bridge-check.service
Wants=network-online.target bridge-check.service

[Service]
Type=simple
User=root
Environment=ROLE_FILE=${ROLE_FILE}
ExecStart=${ISI_RUNNER}
Restart=on-failure
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
}

enable_service() {
  log "Enabling isirunall.service."

  systemctl daemon-reload
  systemctl enable isirunall.service 2>/dev/null || true

  log "Starting isirunall.service. It will exit cleanly unless the isi role is enabled."
  systemctl restart isirunall.service 2>/dev/null || true
}

install_module() {
  require_root
  prepare_log

  log "Starting ISI simulator module installation."

  install_packages
  ensure_role_file
  write_runner
  write_payloads
  write_service
  enable_service

  write_dashboard_module_flag "ISI" "1"
  restart_dashboard_if_present

  ok "ISI simulator module installed."
  ok "Dashboard availability flag set: ISI=1"
  ok "Dashboard role file controls startup: ${ROLE_FILE}"
  ok "Enable role with dashboard or set: ROLES=\"isi\""
}

uninstall_module() {
  require_root
  prepare_log

  log "Uninstalling ISI simulator module."

  systemctl stop isirunall.service 2>/dev/null || true
  systemctl disable isirunall.service 2>/dev/null || true

  rm -f "$ISI_SERVICE"
  rm -f "$ISI_RUNNER"
  rm -f "$ISI_FILE_1"
  rm -f "$ISI_FILE_2"
  rm -f "$ISI_FILE_3"

  ip netns del ns1 2>/dev/null || true
  ip netns del ns2 2>/dev/null || true
  ip netns del ns3 2>/dev/null || true

  ip -o link show | awk -F': ' '{print $2}' | cut -d'@' -f1 |
    grep -E '^veth[0-9]+_(host|ns)$' 2>/dev/null |
    xargs -r -I{} ip link del "{}" 2>/dev/null || true

  systemctl daemon-reload

  write_dashboard_module_flag "ISI" "0"
  restart_dashboard_if_present

  ok "ISI simulator service and helper files removed."
  ok "Dashboard availability flag set: ISI=0"
  warn "Installed packages were left in place intentionally."
  warn "Role file was left in place intentionally: ${ROLE_FILE}"
}

usage() {
  cat <<EOF
Usage:
  sudo ./scripts/pi-3-4-5/module-isi.sh [install|uninstall|purge]

Actions:
  install    Install/update ISI simulator service
  uninstall  Remove ISI service and helper files
  purge      Compatibility alias for uninstall; packages are not purged

Package cache:
  This module uses:
    scripts/lib/packages.sh

  To prepare package cache in the lab:
    sudo ./scripts/initbox-installer.sh pi-3-4-5 p

Role control:
  Dashboard writes:
    ${ROLE_FILE}

  ISI starts only when the role file includes:
    isi

Dashboard availability:
  This module sets:
    ISI=1 on install
    ISI=0 on uninstall/purge

  If ${NODERED_SERVICE} exists, it is restarted after the flag update.

Bridge:
  This Pi 3/4/5 module expects br0 to be created by:
    bridge-check.service

  That service is installed by:
    scripts/pi-3-4-5/module-ws-br0.sh
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
