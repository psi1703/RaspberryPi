#!/usr/bin/env bash
# InitBox Raspberry Pi 3 / 4 / 5 ISI simulator module
# Installs:
#   - isirunall.sh
#   - ISI payload files for DRACHE, NIX, and ZEITNEHMER
#   - isirunall.service
# Package model:
#   - Uses scripts/lib/packages.sh
#   - With Internet: installs through apt-get and keeps packages cached
#   - Without Internet: installs from local package cache only
# Pi 3 / 4 / 5 role model:
#   - Dashboard owns /etc/pi_roles.conf.
#   - isirunall.sh starts only when the role file contains: isi
#   - br0 is managed by bridge-check.service from the sniffer bridge module.
#   - eth0/eth1/br0 stay IP-free while bridge mode is active.
#   - namespace-side veth clients receive COPILOT DHCP addresses.
# Dashboard module availability model:
#   - This module sets ISI=1 after install.
#   - This module sets ISI=0 after uninstall/purge.
#   - If initbox-dashboard.service exists, it is restarted after the flag update
#     so the dashboard UI reloads module availability immediately.
# ZEITNEHMER model:
#   - DRACHE and NIX remain persistent cyclic ISI clients.
#   - ZEITNEHMER now uses one persistent AppName=ZEITNEHMER session.
#   - The same session performs Time_ISO8601 first, then DateTime fallback.
#   - No duplicate ZEITNEHMER AppName/session is created.
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
DASHBOARD_SERVICE="${DASHBOARD_SERVICE:-initbox-dashboard.service}"

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
    BEGIN { found = 0 }
    $0 ~ "^" key "=" {
      print key "=" value
      found = 1
      next
    }
    { print }
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
  if ! systemctl cat "$DASHBOARD_SERVICE" >/dev/null 2>&1; then
    log "React dashboard service not installed; no restart needed."
    return 0
  fi

  if systemctl is-active "$DASHBOARD_SERVICE" >/dev/null 2>&1; then
    log "Restarting ${DASHBOARD_SERVICE} so dashboard UI reloads module flags."
    if systemctl restart "$DASHBOARD_SERVICE"; then
      ok "${DASHBOARD_SERVICE} restarted."
    else
      warn "Failed to restart ${DASHBOARD_SERVICE}."
    fi
    return 0
  fi

  if systemctl is-enabled "$DASHBOARD_SERVICE" >/dev/null 2>&1; then
    log "${DASHBOARD_SERVICE} exists but is not active; starting it so dashboard UI reloads module flags."
    if systemctl restart "$DASHBOARD_SERVICE"; then
      ok "${DASHBOARD_SERVICE} started."
    else
      warn "Failed to start ${DASHBOARD_SERVICE}."
    fi
    return 0
  fi

  log "${DASHBOARD_SERVICE} exists but is disabled/inactive; no dashboard restart needed."
}

write_runner() {
  log "Writing ${ISI_RUNNER}."

  cat >"$ISI_RUNNER" <<'EOF_RUNNER'
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

DRIFT_THRESHOLD="${DRIFT_THRESHOLD:-5}"
TIME_SYNC_INTERVAL="${TIME_SYNC_INTERVAL:-3600}"
TIME_SYNC_RETRY_SECONDS="${TIME_SYNC_RETRY_SECONDS:-30}"
BRIDGE_WAIT_SECONDS="${BRIDGE_WAIT_SECONDS:-60}"
NC_FAIL_LOG_INTERVAL="${NC_FAIL_LOG_INTERVAL:-60}"

DEST_IP=""
NS_IPS=()
ZEITNEHMER_FIFO=""
ZEITNEHMER_RESPONSE_LOG=""
ZEITNEHMER_ERROR_LOG=""
ZEITNEHMER_NC_PID=""
PARSED_ZEITNEHMER_TIME=""

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

cleanup_zeitnehmer_session() {
  local pid="${ZEITNEHMER_NC_PID:-}"

  exec 9>&- 2>/dev/null || true

  if [ -n "$pid" ]; then
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  fi

  rm -f "${ZEITNEHMER_FIFO:-}" 2>/dev/null || true
  ZEITNEHMER_NC_PID=""
}

cleanup_ns() {
  local ns=""

  cleanup_zeitnehmer_session

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

ensure_bridge_up() {
  if ! ip link show "$BRIDGE" >/dev/null 2>&1; then
    log "ERROR: ${BRIDGE} does not exist."
    return 1
  fi

  ip addr flush dev "$BRIDGE" 2>/dev/null || true
  ip link set "$BRIDGE" up 2>/dev/null || true
}

add_veth_to_br() {
  local idx="$1"
  local ns="$2"
  local ifh="veth${idx}_host"
  local ifn="veth${idx}_ns"

  ensure_bridge_up

  ip link del "$ifh" 2>/dev/null || true
  ip link del "$ifn" 2>/dev/null || true
  ip netns del "$ns" 2>/dev/null || true

  ip link add "$ifh" type veth peer name "$ifn"
  ip link set "$ifh" address "$(uniq_mac "$ifh")"

  ip addr flush dev "$ifh" 2>/dev/null || true
  ip link set "$ifh" master "$BRIDGE"
  ip link set "$ifh" up

  ip netns add "$ns"
  ip link set "$ifn" netns "$ns"
  ip netns exec "$ns" ip link set lo up
  ip netns exec "$ns" ip link set "$ifn" address "$(uniq_mac "$ifn")"
  ip netns exec "$ns" ip addr flush dev "$ifn" 2>/dev/null || true
  ip netns exec "$ns" ip link set "$ifn" up

  log "${ifh} attached to ${BRIDGE}; ${ifn} moved into ${ns}."
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

  if ! command -v timeout >/dev/null 2>&1; then
    log "ERROR: timeout command missing. Install coreutils."
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
  local ifn="veth${idx}_ns"
  local ns_ip=""
  local dhcp_out=""

  ip netns exec "$ns" ip addr flush dev "$ifn" 2>/dev/null || true
  ip netns exec "$ns" ip link set "$ifn" up

  dhcp_out="$(ip netns exec "$ns" dhclient -4 -1 -v "$ifn" 2>&1 || true)"

  if ! printf '%s' "$dhcp_out" | grep -q 'DHCPACK'; then
    log "ERROR: DHCP failed in ${ns} on ${ifn}."
    printf '%s\n' "$dhcp_out" | tail -n 30 | while IFS= read -r line; do
      log "dhclient: ${line}"
    done
    exit 1
  fi

  ip netns pids "$ns" 2>/dev/null | while IFS= read -r pid; do
    if ps -p "$pid" -o comm= 2>/dev/null | grep -qx 'dhclient'; then
      kill -TERM "$pid" 2>/dev/null || true
    fi
  done

  ns_ip="$(ip netns exec "$ns" ip -o -4 addr show "$ifn" | awk '{print $4}' | cut -d/ -f1 || true)"
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

  log "Starting persistent cyclic ISI client ${name} in ${ns} (veth${idx}_ns, ${file})."

  ip netns exec "$ns" bash -c '
    set -euo pipefail

    file="$1"
    dest_ip="$2"
    name="$3"
    fail_log_interval="$4"
    last_fail=0
    now_epoch=0
    rc=0

    while true; do
      # netcat-openbsd: -q -1 keeps the TCP session open after the payload file
      # reaches EOF. This is required so COPILOT keeps the AppName registered
      # as an active ISI client instead of seeing a short one-shot sender.
      nc -q -1 "$dest_ip" 51001 < "$file" >/dev/null 2>&1
      rc=$?
      now_epoch="$(date +%s)"

      if [ $((now_epoch - last_fail)) -ge "$fail_log_interval" ]; then
        echo "[ISI $(date +%F_%T)] ${name}: persistent cyclic session ended with rc=${rc}; reconnecting."
        last_fail="$now_epoch"
      fi

      sleep 1
    done
  ' -- "$file" "$DEST_IP" "$name" "$NC_FAIL_LOG_INTERVAL" &
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
      if DRIFT_THRESHOLD="$DRIFT_THRESHOLD" COPILOT_DRIFT_THRESHOLD="${COPILOT_DRIFT_THRESHOLD:-$DRIFT_THRESHOLD}" /usr/local/bin/rtc-sync.sh --iso8601 "$value"; then
        log "ZEITNEHMER: rtc-sync.sh completed successfully."
      else
        rc=$?
        log "ZEITNEHMER: rtc-sync.sh returned non-zero exit code ${rc}."
      fi
      ;;
    legacy)
      log "ZEITNEHMER: COPILOT DateTime=${value}; delegating to rtc-sync.sh."
      if DRIFT_THRESHOLD="$DRIFT_THRESHOLD" COPILOT_DRIFT_THRESHOLD="${COPILOT_DRIFT_THRESHOLD:-$DRIFT_THRESHOLD}" /usr/local/bin/rtc-sync.sh --datetime "$value"; then
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

zeitnehmer_response_since() {
  local response_file="$1"
  local start_byte="$2"

  if [ ! -f "$response_file" ]; then
    return 0
  fi

  tail -c +"$start_byte" "$response_file" 2>/dev/null || true
}

zeitnehmer_session_alive() {
  local pid="$1"

  [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null
}

start_zeitnehmer_session() {
  local zeit_ns="$1"
  local runtime_dir="/run/initbox/zeitnehmer"
  local register_payload=""

  mkdir -p "$runtime_dir"

  ZEITNEHMER_FIFO="${runtime_dir}/input.fifo"
  ZEITNEHMER_RESPONSE_LOG="${runtime_dir}/response.log"
  ZEITNEHMER_ERROR_LOG="${runtime_dir}/error.log"
  ZEITNEHMER_NC_PID=""

  cleanup_zeitnehmer_session

  rm -f "$ZEITNEHMER_FIFO" "$ZEITNEHMER_RESPONSE_LOG" "$ZEITNEHMER_ERROR_LOG"
  mkfifo "$ZEITNEHMER_FIFO"
  : >"$ZEITNEHMER_RESPONSE_LOG"
  : >"$ZEITNEHMER_ERROR_LOG"

  log "ZEITNEHMER: opening one persistent COPILOT session in ${zeit_ns} at ${DEST_IP}:51001."

  ip netns exec "$zeit_ns" bash -c '
    set -euo pipefail
    fifo="$1"
    dest_ip="$2"
    response_log="$3"
    error_log="$4"

    cat "$fifo" | nc "$dest_ip" 51001 >>"$response_log" 2>>"$error_log"
  ' -- "$ZEITNEHMER_FIFO" "$DEST_IP" "$ZEITNEHMER_RESPONSE_LOG" "$ZEITNEHMER_ERROR_LOG" &

  ZEITNEHMER_NC_PID="$!"

  exec 9>"$ZEITNEHMER_FIFO"

  register_payload="<IsiPut><AppName>ZEITNEHMER</AppName></IsiPut>"
  printf '%s\n' "$register_payload" >&9

  sleep 1

  if zeitnehmer_session_alive "$ZEITNEHMER_NC_PID"; then
    log "ZEITNEHMER: persistent session registered."
    return 0
  fi

  log "ZEITNEHMER: persistent session exited during registration."
  return 1
}

request_zeitnehmer_item() {
  local zeit_ns="$1"
  local item="$2"
  local payload=""
  local time_response=""
  local parsed=""
  local response_size=0
  local start_byte=1
  local deadline=0
  local now_epoch=0

  PARSED_ZEITNEHMER_TIME=""

  if ! zeitnehmer_session_alive "${ZEITNEHMER_NC_PID:-}"; then
    log "ZEITNEHMER: persistent session is not active before ${item}; reconnecting."
    start_zeitnehmer_session "$zeit_ns" || return 1
  fi

  response_size="$(wc -c <"$ZEITNEHMER_RESPONSE_LOG" 2>/dev/null || printf '0')"
  start_byte=$((response_size + 1))

  payload="<IsiGet><Items>${item}</Items><Cyclic>0</Cyclic></IsiGet>"

  log "ZEITNEHMER: requesting ${item} on the existing persistent COPILOT session at ${DEST_IP}."
  log "ZEITNEHMER: request payload: $(printf '%s' "$payload" | tr '\n' ' ')"

  if ! printf '%s\n' "$payload" >&9 2>/dev/null; then
    log "ZEITNEHMER: failed to write ${item} request to persistent session."
    cleanup_zeitnehmer_session
    return 1
  fi

  deadline=$(($(date +%s) + 10))

  while true; do
    time_response="$(zeitnehmer_response_since "$ZEITNEHMER_RESPONSE_LOG" "$start_byte")"

    if [ -n "$time_response" ]; then
      log "ZEITNEHMER: raw ${item} response snippet: $(printf '%s' "$time_response" | tr '\n' ' ' | head -c 400)"

      if parsed="$(parse_datetime_response "$time_response")"; then
        PARSED_ZEITNEHMER_TIME="$parsed"
        return 0
      fi
    fi

    now_epoch="$(date +%s)"
    if [ "$now_epoch" -ge "$deadline" ]; then
      break
    fi

    if ! zeitnehmer_session_alive "${ZEITNEHMER_NC_PID:-}"; then
      log "ZEITNEHMER: persistent session ended while waiting for ${item}."
      cleanup_zeitnehmer_session
      return 1
    fi

    sleep 1
  done

  if [ -z "$time_response" ]; then
    log "ZEITNEHMER: empty response for ${item} from COPILOT."
  else
    log "ZEITNEHMER: no usable ${item} timestamp pattern found."
  fi

  return 1
}

run_zeitnehmer_loop() {
  local zeit_ns="${NS[2]}"
  local now_epoch=0
  local last_time_sync=0
  local last_time_attempt=0
  local last_fail_log=0

  log "ZEITNEHMER persistent loop starting in ${zeit_ns}; sync interval=${TIME_SYNC_INTERVAL}s; retry interval=${TIME_SYNC_RETRY_SECONDS}s."

  while ! start_zeitnehmer_session "$zeit_ns"; do
    log "ZEITNEHMER: persistent session failed to start; retrying in ${TIME_SYNC_RETRY_SECONDS}s."
    sleep "$TIME_SYNC_RETRY_SECONDS"
  done

  while true; do
    now_epoch="$(date +%s)"

    if ! zeitnehmer_session_alive "${ZEITNEHMER_NC_PID:-}"; then
      if ((now_epoch - last_fail_log >= NC_FAIL_LOG_INTERVAL)); then
        last_fail_log="$now_epoch"
        log "ZEITNEHMER: persistent session not active; reconnecting."
      fi

      cleanup_zeitnehmer_session
      start_zeitnehmer_session "$zeit_ns" || true
      sleep 1
      continue
    fi

    if ((now_epoch - last_time_sync >= TIME_SYNC_INTERVAL)) && ((now_epoch - last_time_attempt >= TIME_SYNC_RETRY_SECONDS)); then
      last_time_attempt="$now_epoch"
      PARSED_ZEITNEHMER_TIME=""

      if request_zeitnehmer_item "$zeit_ns" "Time_ISO8601"; then
        last_time_sync="$now_epoch"
        run_rtc_sync "$PARSED_ZEITNEHMER_TIME"
      elif request_zeitnehmer_item "$zeit_ns" "DateTime"; then
        last_time_sync="$now_epoch"
        run_rtc_sync "$PARSED_ZEITNEHMER_TIME"
      else
        log "ZEITNEHMER: no COPILOT time parsed from Time_ISO8601 or DateTime; will retry in ${TIME_SYNC_RETRY_SECONDS}s."
      fi
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
  log "Namespace client IPs: ${NS_IPS[*]}"

  start_isi_loop "${NS[0]}" "${ISI_FILES[0]}" "${NAMES[0]}" 1
  start_isi_loop "${NS[1]}" "${ISI_FILES[1]}" "${NAMES[1]}" 2

  run_zeitnehmer_loop
}

main "$@"
EOF_RUNNER

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
<IsiGet><Items>Time_ISO8601</Items><Cyclic>0</Cyclic></IsiGet>
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
KillMode=control-group
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

  If ${DASHBOARD_SERVICE} exists, it is restarted after the flag update.

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
