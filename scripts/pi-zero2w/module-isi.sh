#!/usr/bin/env bash
set -euo pipefail

# InitBox Pi Zero W / Zero 2W ISI module
# Actions:
#   install   Install and enable ISI simulator.
#   uninstall Remove ISI service and files created by this module.
#   remove    Alias for uninstall.
#   purge     Compatibility alias for uninstall. It does not purge packages.
# Default action:
#   install
# Offline field-mode policy:
#   - Debian packages are installed from the InitBox local package cache.
#   - Uninstall removes services/config/runtime files only.
#   - Purge is disabled and behaves like uninstall.
#   - Installed packages and cached .deb files are kept.
# COPILOT network safety policy:
#   - Installing this module must not bridge Ethernet immediately.
#   - isirunall.service is enabled but stopped after install.
#   - At runtime, the runner only creates br0 after detecting a wired Ethernet
#     interface with carrier and a 10.x.x.x IPv4 address.
#   - If the COPILOT 10.x network is not detected, the runner exits cleanly
#     without changing Ethernet bridge state.

ACTION="${1:-install}"

: "${OWNER:=initbox}"
: "${LOGFILE:=/home/${OWNER}/pi_logs/initbox-install.log}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${INITBOX_REPO_ROOT:-$(cd "$SCRIPT_DIR/../.." && pwd)}"

INITBOX_PACKAGES_FILE="${INITBOX_PACKAGES_FILE:-$REPO_ROOT/scripts/packages.txt}"
INITBOX_PACKAGE_CACHE_DIR="${INITBOX_PACKAGE_CACHE_DIR:-/opt/initbox/packages}"
PACKAGES_LIB_FILE="$REPO_ROOT/scripts/lib/packages.sh"

ISI_RUNNER="/usr/local/bin/isirunall.sh"
ISI_SERVICE_FILE="/etc/systemd/system/isirunall.service"
ISI_PAYLOAD_1="/usr/local/bin/isi1.txt"
ISI_PAYLOAD_2="/usr/local/bin/isi2.txt"
ISI_PAYLOAD_3="/usr/local/bin/isi3.txt"
ISI_DHCP_RUNTIME_DIR="/run/initbox-isi"
NM_ISI_CONF="/etc/NetworkManager/conf.d/99-initbox-isi-unmanaged.conf"
DHCPCD_CONF="/etc/dhcpcd.conf"
DHCPCD_BLOCK_START="# BEGIN InitBox ISI bridge unmanaged"
DHCPCD_BLOCK_END="# END InitBox ISI bridge unmanaged"

# ----------------------------------------------------------------------------
# Logging
# ----------------------------------------------------------------------------

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

# ----------------------------------------------------------------------------
# Shared helpers
# ----------------------------------------------------------------------------

require_root() {
  if [ "$(id -u)" -ne 0 ]; then
    err "this module must be run as root"
    exit 1
  fi
}

ensure_log_dir() {
  mkdir -p "$(dirname "$LOGFILE")"
  touch "$LOGFILE"
  chown "$OWNER:$OWNER" "$LOGFILE" 2>/dev/null || true
}

load_package_helper() {
  if [ ! -f "$PACKAGES_LIB_FILE" ]; then
    err "package helper missing: $PACKAGES_LIB_FILE"
    exit 1
  fi

  # shellcheck disable=SC1090
  . "$PACKAGES_LIB_FILE"

  if ! declare -F initbox_packages_install >/dev/null 2>&1; then
    err "package helper does not define initbox_packages_install"
    exit 1
  fi
}

# ----------------------------------------------------------------------------
# Dependency management
# ----------------------------------------------------------------------------

install_dependencies() {
  log "Installing ISI simulator dependencies from InitBox package cache"
  log "packages file: $INITBOX_PACKAGES_FILE"
  log "cache dir:     $INITBOX_PACKAGE_CACHE_DIR"

  load_package_helper

  initbox_packages_install \
    "$INITBOX_PACKAGES_FILE" \
    "$INITBOX_PACKAGE_CACHE_DIR" \
    isc-dhcp-client \
    netcat-openbsd \
    iproute2 \
    bridge-utils
}

# ----------------------------------------------------------------------------
# Network manager cleanup helpers
# ----------------------------------------------------------------------------

remove_dhcpcd_isi_block() {
  local tmp_file=""

  [ -f "$DHCPCD_CONF" ] || return 0

  tmp_file="$(mktemp)"
  awk -v start="$DHCPCD_BLOCK_START" -v end="$DHCPCD_BLOCK_END" '
    $0 == start { skip=1; next }
    $0 == end   { skip=0; next }
    skip != 1   { print }
  ' "$DHCPCD_CONF" >"$tmp_file"
  cat "$tmp_file" >"$DHCPCD_CONF"
  rm -f "$tmp_file"
}

remove_isi_network_manager_overrides() {
  log "Removing ISI network-manager overrides"

  rm -f "$NM_ISI_CONF" 2>/dev/null || true
  remove_dhcpcd_isi_block
  systemctl restart NetworkManager 2>/dev/null || true
  systemctl restart dhcpcd 2>/dev/null || true
}

# ----------------------------------------------------------------------------
# isirunall.sh - the persistent runner written to disk
# ----------------------------------------------------------------------------

write_isi_runner() {
  log "Writing ${ISI_RUNNER}"

  cat >"$ISI_RUNNER" <<'RUNNER_EOF'
#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# Runtime configuration
# ---------------------------------------------------------------------------
BRIDGE="${BRIDGE:-br0}"
DHCP_RUNTIME_DIR="${DHCP_RUNTIME_DIR:-/run/initbox-isi}"
DRIFT_THRESHOLD="${DRIFT_THRESHOLD:-2}"
TIME_SYNC_INTERVAL="${TIME_SYNC_INTERVAL:-60}"
UPLINK_IF="${UPLINK_IF:-}"

ISI_FILES=(
  "/usr/local/bin/isi1.txt"
  "/usr/local/bin/isi2.txt"
  "/usr/local/bin/isi3.txt"
)
NAMES=(DRACHE NIX ZEITNEHMER)
NS=(ns1 ns2 ns3)

# ---------------------------------------------------------------------------
# State
# ---------------------------------------------------------------------------
DEST_IP=""
NS_IPS=()
BRIDGE_CREATED_BY_ISI=0
BRIDGE_PORTS_ADDED_BY_ISI=()

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
log() {
  echo "[ISI $(date +%F_%T)] $*"
}

# ---------------------------------------------------------------------------
# Interface helpers
# ---------------------------------------------------------------------------

is_excluded_interface() {
  local iface="$1"

  case "$iface" in
    lo|wlan*|wifi*|br*|veth*|docker*|virbr*|tap*|tun*|wg*|tailscale*|zt*|dummy*|ifb*|sit*|ip6tnl*|gre*|gretap*)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

is_wired_ethernet_candidate() {
  local iface="$1"
  local dev_type=""

  is_excluded_interface "$iface" && return 1
  [ -r "/sys/class/net/${iface}/type" ] || return 1

  dev_type="$(cat "/sys/class/net/${iface}/type" 2>/dev/null || echo "")"
  [ "$dev_type" = "1" ] || return 1

  case "$iface" in
    eth*|en*|usb*)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

detect_wired_ethernet_ports() {
  local iface_path=""
  local iface=""
  local detected=()

  for iface_path in /sys/class/net/*; do
    iface="$(basename "$iface_path")"
    is_wired_ethernet_candidate "$iface" && detected+=("$iface")
  done

  if [ "${#detected[@]}" -gt 0 ]; then
    printf '%s\n' "${detected[@]}" | sort -V
  fi
}

detect_bridge_ports() {
  local wired_ifs=()

  if [ -n "$UPLINK_IF" ]; then
    if ! ip link show "$UPLINK_IF" >/dev/null 2>&1; then
      log "ERROR: UPLINK_IF=${UPLINK_IF} does not exist."
      exit 1
    fi

    if ! is_wired_ethernet_candidate "$UPLINK_IF"; then
      log "ERROR: UPLINK_IF=${UPLINK_IF} is not a valid wired Ethernet candidate."
      exit 1
    fi

    printf '%s\n' "$UPLINK_IF"
    return 0
  fi

  mapfile -t wired_ifs < <(detect_wired_ethernet_ports)

  if [ "${#wired_ifs[@]}" -eq 0 ]; then
    log "ERROR: No wired Ethernet interfaces found for ${BRIDGE}."
    log "ERROR: Check carrier board, USB Ethernet adapters, cabling, and interface names."
    exit 1
  fi

  printf '%s\n' "${wired_ifs[@]}"
}

# ---------------------------------------------------------------------------
# COPILOT network gate
# ---------------------------------------------------------------------------

interface_has_carrier() {
  local iface="$1"

  [ -r "/sys/class/net/${iface}/carrier" ] || return 1
  [ "$(cat "/sys/class/net/${iface}/carrier" 2>/dev/null || echo 0)" = "1" ]
}

interface_has_10_network() {
  local iface="$1"

  ip -4 -o addr show dev "$iface" 2>/dev/null \
    | awk '{print $4}' \
    | grep -Eq '^10\.'
}

detect_copilot_gate_port() {
  local iface=""

  while IFS= read -r iface; do
    [ -z "$iface" ] && continue

    if ! interface_has_carrier "$iface"; then
      log "Gate: ${iface} has no carrier; skipping."
      continue
    fi

    if interface_has_10_network "$iface"; then
      log "Gate: COPILOT candidate detected on ${iface}; IPv4 is in 10.x.x.x."
      printf '%s\n' "$iface"
      return 0
    fi

    log "Gate: ${iface} has carrier but no 10.x.x.x IPv4 address."
  done < <(detect_wired_ethernet_ports)

  return 1
}

require_copilot_network_gate() {
  local gate_port=""

  if ! gate_port="$(detect_copilot_gate_port)"; then
    log "COPILOT network gate not passed."
    log "No wired Ethernet interface has both carrier and a 10.x.x.x IPv4 address."
    log "Refusing to create ${BRIDGE}; leaving Ethernet untouched."
    log "Connect the Pi to the COPILOT network first, then restart isirunall.service."
    exit 0
  fi

  log "COPILOT network gate passed on ${gate_port}."

  if [ -n "$UPLINK_IF" ]; then
    log "Operator supplied UPLINK_IF=${UPLINK_IF}; only that interface will be bridged."
  else
    log "UPLINK_IF is not set; all detected wired Ethernet ports will be bridged."
    log "This supports Pi-in-the-middle mode, for example eth0 to COPILOT and eth1 to switch."
  fi
}

# ---------------------------------------------------------------------------
# Bridge setup / teardown
# ---------------------------------------------------------------------------

is_pi_zero_like() {
  local model=""

  model="$(tr -d '\0' </proc/device-tree/model 2>/dev/null || echo "")"

  case "$model" in
    *"Zero"*)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

attach_port_to_bridge() {
  local iface="$1"
  local current_master=""

  if ! ip link show "$iface" >/dev/null 2>&1; then
    log "WARN: Interface ${iface} disappeared before bridge attach; skipping it."
    return 0
  fi

  current_master="$(basename "$(readlink "/sys/class/net/${iface}/master" 2>/dev/null || echo "")")"

  if [ -n "$current_master" ] && [ "$current_master" != "$BRIDGE" ]; then
    log "ERROR: ${iface} is already enslaved to ${current_master}, refusing to steal it."
    exit 1
  fi

  if [ "$current_master" = "$BRIDGE" ]; then
    return 0
  fi

  log "Adding wired port ${iface} to ${BRIDGE}"
  ip addr flush dev "$iface" 2>/dev/null || true
  ip link set "$iface" up
  ip link set "$iface" master "$BRIDGE"

  BRIDGE_PORTS_ADDED_BY_ISI+=("$iface")
}

setup_bridge_for_isi() {
  local bridge_ports=()
  local iface=""

  if ! is_pi_zero_like; then
    log "ERROR: ISI auto bridge setup is only supported on Pi Zero W / Zero 2W by this module."
    exit 1
  fi

  mapfile -t bridge_ports < <(detect_bridge_ports)
  log "Detected wired Ethernet bridge ports: ${bridge_ports[*]}"

  if ip link show "$BRIDGE" >/dev/null 2>&1; then
    log "${BRIDGE} already exists; reusing it and ensuring all detected wired ports are attached."
  else
    log "Creating ${BRIDGE} for ISI."
    ip link add name "$BRIDGE" type bridge
    BRIDGE_CREATED_BY_ISI=1
  fi

  ip link set "$BRIDGE" type bridge stp_state 0 forward_delay 0 2>/dev/null || true

  ip addr flush dev "$BRIDGE" 2>/dev/null || true
  ip link set "$BRIDGE" up

  for iface in "${bridge_ports[@]}"; do
    attach_port_to_bridge "$iface"
  done

  ip link set "$BRIDGE" up

  log "${BRIDGE} is ready with wired ports: ${bridge_ports[*]}"
  log "Current bridge membership:"
  bridge link 2>/dev/null || true
}

teardown_bridge_for_isi() {
  local iface=""

  for iface in "${BRIDGE_PORTS_ADDED_BY_ISI[@]+"${BRIDGE_PORTS_ADDED_BY_ISI[@]}"}"; do
    ip link set "$iface" nomaster 2>/dev/null || true
    ip link set "$iface" up 2>/dev/null || true
  done

  if [ "$BRIDGE_CREATED_BY_ISI" -eq 1 ]; then
    log "Tearing down ${BRIDGE} created by ISI."
    ip link set "$BRIDGE" down 2>/dev/null || true
    ip link del "$BRIDGE" type bridge 2>/dev/null || true
  fi
}

# ---------------------------------------------------------------------------
# Namespace setup / teardown
# ---------------------------------------------------------------------------

cleanup_ns() {
  local ns=""
  local pid=""
  local link_name=""

  for ns in "${NS[@]}"; do
    if ip netns pids "$ns" >/dev/null 2>&1; then
      while read -r pid; do
        [ -n "$pid" ] && kill -TERM "$pid" 2>/dev/null || true
      done < <(ip netns pids "$ns" 2>/dev/null || true)
    fi

    ip netns del "$ns" 2>/dev/null || true
  done

  while read -r link_name; do
    [ -n "$link_name" ] && ip link del "$link_name" 2>/dev/null || true
  done < <(
    ip -o link show \
      | awk -F': ' '{print $2}' \
      | cut -d'@' -f1 \
      | grep -E '^veth[0-9]+_(host|ns)$' 2>/dev/null || true
  )
}

cleanup_dhcp_runtime() {
  mkdir -p "$DHCP_RUNTIME_DIR"
  rm -f "${DHCP_RUNTIME_DIR}"/dhclient-ns*.leases \
    "${DHCP_RUNTIME_DIR}"/dhclient-ns*.pid \
    "${DHCP_RUNTIME_DIR}"/dhclient-ns*.conf
}

uniq_mac() {
  local seed="$1"
  local hash=""

  hash="$(printf "%s" "$seed" | sha1sum | awk '{print $1}')"

  printf "02:%s:%s:%s:%s:%s\n" \
    "${hash:0:2}" \
    "${hash:2:2}" \
    "${hash:4:2}" \
    "${hash:6:2}" \
    "${hash:8:2}"
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
  ip addr flush dev "$ifh" 2>/dev/null || true
  ip link set "$ifh" master "$BRIDGE"
  ip link set "$ifh" up

  ip netns add "$ns"
  ip link set "$ifn" netns "$ns"
  ip netns exec "$ns" ip link set lo up
  ip netns exec "$ns" ip link set "$ifn" address "$(uniq_mac "$ifn")"
  ip netns exec "$ns" ip addr flush dev "$ifn" 2>/dev/null || true
  ip netns exec "$ns" ip link set "$ifn" up
}

# ---------------------------------------------------------------------------
# DHCP inside namespace
# ---------------------------------------------------------------------------

request_fresh_dhcp() {
  local ns="$1"
  local iface="$2"
  local lease_file="${DHCP_RUNTIME_DIR}/dhclient-${ns}.leases"
  local pid_file="${DHCP_RUNTIME_DIR}/dhclient-${ns}.pid"
  local conf_file="${DHCP_RUNTIME_DIR}/dhclient-${ns}.conf"
  local dhcp_out=""

  mkdir -p "$DHCP_RUNTIME_DIR"
  rm -f "$lease_file" "$pid_file" "$conf_file"
  : >"$lease_file"

  printf 'bootp-broadcast-always;\nrequest subnet-mask, routers, domain-name-servers, broadcast-address;\n' >"$conf_file"

  ip netns exec "$ns" ip addr flush dev "$iface" 2>/dev/null || true

  log "Requesting fresh DHCP for ${ns} on ${iface} (broadcast-mode, stable MAC, empty lease)"

  dhcp_out="$(
    ip netns exec "$ns" dhclient \
      -4 \
      -1 \
      -v \
      -cf "$conf_file" \
      -lf "$lease_file" \
      -pf "$pid_file" \
      "$iface" 2>&1 || true
  )"

  if [ -f "$pid_file" ]; then
    kill -TERM "$(cat "$pid_file")" 2>/dev/null || true
    rm -f "$pid_file"
  fi

  rm -f "$lease_file" "$conf_file"

  printf '%s\n' "$dhcp_out"
}

# ---------------------------------------------------------------------------
# COPILOT IP discovery from DHCP output
# ---------------------------------------------------------------------------

discover_copilot_from_dhcp() {
  local dhcp_out="$1"
  local srv=""
  local gw=""

  [ -n "$DEST_IP" ] && return 0

  srv="$(
    printf '%s\n' "$dhcp_out" \
      | sed -nE 's/.*DHCPACK of [^ ]+ from ([0-9.]+).*/\1/p' \
      | tail -1
  )"

  if [[ "$srv" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
    DEST_IP="$srv"
    log "COPILOT discovered from DHCPACK server address: ${DEST_IP}"
    return 0
  fi

  gw="$(
    printf '%s\n' "$dhcp_out" \
      | sed -nE 's/.*option routers[[:space:]]+([0-9.]+).*/\1/p' \
      | tail -1
  )"

  if [[ "$gw" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
    DEST_IP="$gw"
    log "COPILOT discovered from DHCP routers option: ${DEST_IP}"
    return 0
  fi
}

# ---------------------------------------------------------------------------
# ISI client loops
# ---------------------------------------------------------------------------

start_isi_loop() {
  local ns="$1"
  local file="$2"
  local name="$3"

  log "Starting persistent ISI client ${name} in ${ns} -> ${DEST_IP}:51001"

  ip netns exec "$ns" bash -lc "
    while true; do
      nc '${DEST_IP}' 51001 < '${file}' >/dev/null 2>&1 || sleep 1
    done
  " &
}

# ---------------------------------------------------------------------------
# Cleanup trap
# ---------------------------------------------------------------------------

full_cleanup() {
  cleanup_ns
  cleanup_dhcp_runtime
  teardown_bridge_for_isi
}

trap full_cleanup EXIT

# ---------------------------------------------------------------------------
# Main: gate -> bridge -> namespaces -> DHCP -> ISI loops
# ---------------------------------------------------------------------------

require_copilot_network_gate
setup_bridge_for_isi
cleanup_dhcp_runtime
cleanup_ns

for _ in {1..10}; do
  ip -br link show "$BRIDGE" | grep -q '\<UP\>' && break
  sleep 1
done

if ! ip -br link show "$BRIDGE" | grep -q '\<UP\>'; then
  log "ERROR: ${BRIDGE} did not come UP"
  exit 1
fi

log "${BRIDGE} is UP"

if ! command -v dhclient >/dev/null 2>&1; then
  log "ERROR: dhclient missing"
  exit 1
fi

if ! command -v nc >/dev/null 2>&1 && ! command -v netcat >/dev/null 2>&1; then
  log "ERROR: nc/netcat missing"
  exit 1
fi

for i in "${!NS[@]}"; do
  ns="${NS[$i]}"
  idx=$((i + 1))

  add_veth_to_br "$idx" "$ns"

  DHCP_OUT="$(request_fresh_dhcp "$ns" "veth${idx}_ns")"

  if ! printf '%s' "$DHCP_OUT" | grep -q 'DHCPACK'; then
    log "ERROR: DHCP failed in ${ns}"
    log "--- DHCP output ---"
    printf '%s\n' "$DHCP_OUT" >&2
    log "-------------------"
    exit 1
  fi

  ns_ip="$(
    ip netns exec "$ns" ip -o -4 addr show "veth${idx}_ns" \
      | awk '{print $4}' \
      | cut -d/ -f1 || true
  )"

  NS_IPS+=("${ns_ip:-}")
  log "${ns} assigned IP ${ns_ip:-unknown}"

  discover_copilot_from_dhcp "$DHCP_OUT"

  if [ -z "$DEST_IP" ]; then
    gw="$(
      ip netns exec "$ns" ip route show default 2>/dev/null \
        | awk '/^default via /{print $3; exit}'
    )"

    if [[ "$gw" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
      DEST_IP="$gw"
      log "COPILOT discovered from namespace default gateway: ${DEST_IP}"
    fi
  fi
done

if [ -z "$DEST_IP" ]; then
  log "ERROR: Could not determine COPILOT IP from DHCP server, routers option, or default gateway."
  exit 1
fi

log "COPILOT target: ${DEST_IP}"

start_isi_loop "${NS[0]}" "${ISI_FILES[0]}" "${NAMES[0]}"
start_isi_loop "${NS[1]}" "${ISI_FILES[1]}" "${NAMES[1]}"

# ---------------------------------------------------------------------------
# ZEITNEHMER loop - also does clock sync
# ---------------------------------------------------------------------------

zeit_ns="${NS[2]}"
zeit_file="${ISI_FILES[2]}"

log "ZEITNEHMER loop starting in ${zeit_ns}"

LAST_TIME_SYNC=0

while true; do
  NOW_EPOCH="$(date +%s)"

  if [ $((NOW_EPOCH - LAST_TIME_SYNC)) -ge "$TIME_SYNC_INTERVAL" ]; then
    LAST_TIME_SYNC="$NOW_EPOCH"

    log "ZEITNEHMER: polling COPILOT at ${DEST_IP}:51001"

    TIME_RESPONSE="$(
      ip netns exec "$zeit_ns" nc "$DEST_IP" 51001 -w 5 \
        <"$zeit_file" || true
    )"

    log "ZEITNEHMER: response snippet: $(printf '%s' "$TIME_RESPONSE" | tr '\n' ' ' | head -c 400)"

    ISO_DT="$(
      printf '%s\n' "$TIME_RESPONSE" \
        | grep -oE '<Time_ISO8601>[^<]+</Time_ISO8601>|[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}([.,][0-9]+)?(Z|[+-][0-9]{2}:?[0-9]{2})?' \
        | sed -E 's#</?Time_ISO8601>##g' \
        | head -n1 || true
    )"

    DT="$(
      printf '%s\n' "$TIME_RESPONSE" \
        | grep -oE '<DateTime>[^<]+</DateTime>|[0-9]{2}\.[0-9]{2}\.[0-9]{4}-[0-9]{2}:[0-9]{2}:[0-9]{2}' \
        | sed -E 's#</?DateTime>##g' \
        | head -n1 || true
    )"

    MASTER_EPOCH=0

    if [ -n "$ISO_DT" ]; then
      log "ZEITNEHMER: Time_ISO8601=${ISO_DT}"
      MASTER_EPOCH="$(date -d "$ISO_DT" +%s 2>/dev/null || echo 0)"

      if [ "$MASTER_EPOCH" -le 0 ]; then
        log "ZEITNEHMER: Time_ISO8601 was present but could not be parsed; continuing without clock adjustment"
      fi
    elif [ -n "$DT" ]; then
      log "ZEITNEHMER: DateTime=${DT}"
      dpart="${DT%%-*}"
      tpart="${DT#*-}"
      IFS='.' read -r DD MM YYYY <<<"$dpart"
      MASTER_EPOCH="$(date -d "${YYYY}-${MM}-${DD} ${tpart}" +%s 2>/dev/null || echo 0)"

      if [ "$MASTER_EPOCH" -le 0 ]; then
        log "ZEITNEHMER: DateTime was present but could not be parsed; continuing without clock adjustment"
      fi
    else
      log "ZEITNEHMER: no Time_ISO8601 or DateTime in COPILOT response; continuing"
    fi

    if [ "$MASTER_EPOCH" -gt 0 ]; then
      NOW_EPOCH="$(date +%s)"
      DIFF=$((MASTER_EPOCH - NOW_EPOCH))
      ADIFF="${DIFF#-}"
      log "ZEITNEHMER: Pi=${NOW_EPOCH} COPILOT=${MASTER_EPOCH} drift=${DIFF}s"

      if [ "$ADIFF" -gt "$DRIFT_THRESHOLD" ]; then
        log "ZEITNEHMER: drift ${ADIFF}s > ${DRIFT_THRESHOLD}s - adjusting clock"
        date -s "@${MASTER_EPOCH}" >/dev/null 2>&1 \
          || log "ZEITNEHMER: clock set failed; continuing"
      else
        log "ZEITNEHMER: drift ${ADIFF}s within threshold - no adjust"
      fi
    fi
  else
    ip netns exec "$zeit_ns" nc "$DEST_IP" 51001 \
      <"$zeit_file" >/dev/null 2>&1 \
      || log "ZEITNEHMER: nc send failed"
  fi

  sleep 1
done
RUNNER_EOF

  chmod 755 "$ISI_RUNNER"
  chown root:root "$ISI_RUNNER" 2>/dev/null || true
}

# ----------------------------------------------------------------------------
# ISI payload files
# ----------------------------------------------------------------------------

write_isi_payloads() {
  log "Writing ISI payload files"

  cat >"$ISI_PAYLOAD_1" <<'EOF'
<IsiPut><AppName>DRACHE</AppName></IsiPut>
<IsiGet><Items>CurrentSoftwareVersion</Items><Cyclic>1</Cyclic></IsiGet>
EOF

  cat >"$ISI_PAYLOAD_2" <<'EOF'
<IsiPut><AppName>NIX</AppName></IsiPut>
<IsiGet><Items>DeviceState</Items><Cyclic>1</Cyclic></IsiGet>
EOF

  cat >"$ISI_PAYLOAD_3" <<'EOF'
<IsiPut><AppName>ZEITNEHMER</AppName></IsiPut>
<IsiGet><Items>DateTime,Time_ISO8601</Items><Cyclic>5</Cyclic></IsiGet>
EOF

  chown root:root "$ISI_PAYLOAD_1" "$ISI_PAYLOAD_2" "$ISI_PAYLOAD_3" 2>/dev/null || true
  chmod 644 "$ISI_PAYLOAD_1" "$ISI_PAYLOAD_2" "$ISI_PAYLOAD_3"
}

# ----------------------------------------------------------------------------
# systemd service unit
# ----------------------------------------------------------------------------

write_isi_service() {
  log "Installing isirunall.service"

  cat >"$ISI_SERVICE_FILE" <<EOF
[Unit]
Description=ISI simulator (3 namespaces + ISI clients over br0)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
ExecStart=${ISI_RUNNER}
Restart=on-failure
RestartSec=3
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
}

restart_isi_service() {
  systemctl daemon-reload
  systemctl enable isirunall.service
  systemctl stop isirunall.service 2>/dev/null || true
}

# ----------------------------------------------------------------------------
# Install / uninstall helpers
# ----------------------------------------------------------------------------

stop_and_disable_unit() {
  local unit_name="$1"

  log "Stopping and disabling ${unit_name}"
  systemctl disable --now "$unit_name" 2>/dev/null || true
  systemctl reset-failed "$unit_name" 2>/dev/null || true
}

cleanup_runtime_network_state() {
  local link_name=""

  log "Cleaning runtime namespaces, veth links, and DHCP state"

  for _ns in ns1 ns2 ns3; do
    ip netns del "$_ns" 2>/dev/null || true
  done

  while read -r link_name; do
    [ -n "$link_name" ] && ip link del "$link_name" 2>/dev/null || true
  done < <(
    ip -o link show \
      | awk -F': ' '{print $2}' \
      | cut -d'@' -f1 \
      | grep -E '^veth[0-9]+_(host|ns)$' 2>/dev/null || true
  )

  rm -rf "$ISI_DHCP_RUNTIME_DIR" 2>/dev/null || true
}

remove_isi_files() {
  log "Removing ISI files"
  rm -f "$ISI_RUNNER" "$ISI_PAYLOAD_1" "$ISI_PAYLOAD_2" "$ISI_PAYLOAD_3" "$ISI_SERVICE_FILE"
}

# ----------------------------------------------------------------------------
# Summary printers
# ----------------------------------------------------------------------------

print_install_summary() {
  cat <<SUMMARY

ISI simulator installed
-----------------------
Service : isirunall.service
Runner  : ${ISI_RUNNER}

Safety behaviour:
  - install does not start isirunall.service
  - install does not bridge, flush, or enslave Ethernet ports
  - runtime refuses to create br0 unless a wired Ethernet port has carrier and 10.x.x.x IPv4
  - when the COPILOT gate is not passed, Ethernet is left untouched
  - when UPLINK_IF is unset, all detected wired Ethernet ports are bridged after the gate passes
  - when UPLINK_IF is set, only that interface is bridged

Key behaviours:
  - STP disabled, forward_delay 0
  - bootp-broadcast-always in dhclient config
  - deterministic veth MACs
  - fresh DHCP per namespace
  - COPILOT IP discovered from DHCP server / routers option / default gateway
  - no hardcoded COPILOT IP
  - ZEITNEHMER requests DateTime and Time_ISO8601, uses whichever COPILOT returns

Offline field-mode behaviour:
  - Debian packages are installed from ${INITBOX_PACKAGE_CACHE_DIR}
  - uninstall does not remove packages or cached .deb files
  - purge is disabled and behaves like uninstall

Check status:
  sudo systemctl status isirunall.service --no-pager
  sudo journalctl -u isirunall.service -n 100 --no-pager

Manual start when connected to COPILOT 10.x network:
  sudo systemctl restart isirunall.service
  sudo journalctl -u isirunall.service -n 100 --no-pager
SUMMARY
}

print_uninstall_summary() {
  cat <<SUMMARY

ISI simulator uninstalled
-------------------------
Removed:
  - isirunall.service
  - ${ISI_RUNNER}
  - ${ISI_PAYLOAD_1}, ${ISI_PAYLOAD_2}, ${ISI_PAYLOAD_3}
  - runtime namespaces ns1/ns2/ns3
  - runtime veth links
  - ${ISI_DHCP_RUNTIME_DIR}
  - ISI NetworkManager/dhcpcd unmanaged overrides

Not removed:
  - dependency packages
  - cached .deb files under ${INITBOX_PACKAGE_CACHE_DIR}
SUMMARY
}

# ----------------------------------------------------------------------------
# Action entry points
# ----------------------------------------------------------------------------

install_main() {
  require_root
  ensure_log_dir
  install_dependencies
  write_isi_runner
  write_isi_payloads
  write_isi_service
  restart_isi_service
  print_install_summary
  ok "ISI simulator module installed. Service is enabled but not started."
}

uninstall_main() {
  require_root
  ensure_log_dir
  stop_and_disable_unit "isirunall.service"
  cleanup_runtime_network_state
  remove_isi_network_manager_overrides
  remove_isi_files
  systemctl daemon-reload
  systemctl reset-failed 2>/dev/null || true
  print_uninstall_summary
  ok "ISI simulator module uninstalled."
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
      err "Unknown action '${ACTION}'. Use: install or uninstall."
      exit 1
      ;;
  esac
}

main "$@"
