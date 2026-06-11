#!/usr/bin/env bash
set -euo pipefail

# InitBox Pi Zero 2W ISI module
#
# Actions:
#   install   Install and enable ISI simulator.
#   uninstall Remove ISI service and files created by this module.
#   purge     Uninstall and also purge ISI dependency packages.
#
# Default action:
#   install

ACTION="${1:-install}"

: "${OWNER:=initbox}"
: "${SCRIPT_DIR:=$(cd "$(dirname "$0")" && pwd)}"
: "${LOGFILE:=/home/${OWNER}/pi_logs/initbox-install.log}"

ISI_RUNNER="/usr/local/bin/isirunall.sh"
ISI_SERVICE_FILE="/etc/systemd/system/isirunall.service"
ISI_PAYLOAD_1="/usr/local/bin/isi1.txt"
ISI_PAYLOAD_2="/usr/local/bin/isi2.txt"
ISI_PAYLOAD_3="/usr/local/bin/isi3.txt"

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

apt_safe() {
  apt-get -o Dpkg::Use-Pty=0 -o Acquire::Retries=5 "$@" 2>&1 | tee -a "$LOGFILE"
}

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

install_dependencies() {
  log "Installing ISI simulator dependencies"
  apt_safe update
  apt_safe install -y isc-dhcp-client netcat-openbsd
}

remove_dhcpcd_isi_block() {
  local tmp_file=""

  if [ ! -f "$DHCPCD_CONF" ]; then
    return 0
  fi

  tmp_file="$(mktemp)"
  awk -v start="$DHCPCD_BLOCK_START" -v end="$DHCPCD_BLOCK_END" '
    $0 == start {skip=1; next}
    $0 == end {skip=0; next}
    skip != 1 {print}
  ' "$DHCPCD_CONF" >"$tmp_file"

  cat "$tmp_file" >"$DHCPCD_CONF"
  rm -f "$tmp_file"
}

configure_isi_network_managers() {
  log "Configuring host network managers to leave ISI bridge ports unmanaged"

  if systemctl list-unit-files NetworkManager.service >/dev/null 2>&1; then
    mkdir -p "$(dirname "$NM_ISI_CONF")"

    cat >"$NM_ISI_CONF" <<'NM_EOF'
[keyfile]
unmanaged-devices=interface-name:eth0;interface-name:eth1;interface-name:br0;interface-name:veth*
NM_EOF

    systemctl restart NetworkManager 2>/dev/null || true
  fi

  if systemctl list-unit-files dhcpcd.service >/dev/null 2>&1; then
    touch "$DHCPCD_CONF"
    remove_dhcpcd_isi_block

    cat >>"$DHCPCD_CONF" <<EOF

$DHCPCD_BLOCK_START
# InitBox ISI bridge members are L2-only.
# DHCP must run only inside ISI namespaces, not on host bridge ports.
denyinterfaces eth0 eth1 br0 veth*
$DHCPCD_BLOCK_END
EOF

    systemctl restart dhcpcd 2>/dev/null || true
  fi

  ip addr flush dev eth0 2>/dev/null || true
  ip addr flush dev eth1 2>/dev/null || true
  ip addr flush dev br0 2>/dev/null || true

  while read -r link_name; do
    if [ -n "$link_name" ]; then
      ip addr flush dev "$link_name" 2>/dev/null || true
    fi
  done < <(
    ip -o link show |
      awk -F': ' '{print $2}' |
      cut -d'@' -f1 |
      grep -E '^veth[0-9]+_host$' 2>/dev/null || true
  )
}

remove_isi_network_manager_overrides() {
  log "removing ISI network-manager overrides"

  rm -f "$NM_ISI_CONF" 2>/dev/null || true
  remove_dhcpcd_isi_block

  systemctl restart NetworkManager 2>/dev/null || true
  systemctl restart dhcpcd 2>/dev/null || true
}

write_isi_runner() {
  log "Writing ${ISI_RUNNER}"

  cat >"$ISI_RUNNER" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

BRIDGE="${BRIDGE:-br0}"
DHCP_RUNTIME_DIR="${DHCP_RUNTIME_DIR:-/run/initbox-isi}"

ISI_FILES=(
  "/usr/local/bin/isi1.txt"
  "/usr/local/bin/isi2.txt"
  "/usr/local/bin/isi3.txt"
)
NAMES=(DRACHE NIX ZEITNEHMER)
NS=(ns1 ns2 ns3)

DRIFT_THRESHOLD="${DRIFT_THRESHOLD:-2}"
TIME_SYNC_INTERVAL="${TIME_SYNC_INTERVAL:-60}"

DEST_IP=""
NS_IPS=()
UPLINK_IF="${UPLINK_IF:-}"
BRIDGE_CREATED_BY_ISI=0
BRIDGE_PORTS_ADDED_BY_ISI=()

log() {
  echo "[ISI $(date +%F_%T)] $*"
}

is_pi_zero_like() {
  local model

  model="$(tr -d '\0' </proc/device-tree/model 2>/dev/null || echo '')"

  case "$model" in
    *"Zero"*) return 0 ;;
    *) return 1 ;;
  esac
}

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

  if is_excluded_interface "$iface"; then
    return 1
  fi

  if [ ! -r "/sys/class/net/${iface}/type" ]; then
    return 1
  fi

  dev_type="$(cat "/sys/class/net/${iface}/type" 2>/dev/null || echo '')"

  if [ "$dev_type" != "1" ]; then
    return 1
  fi

  case "$iface" in
    eth*|en*|usb*) return 0 ;;
    *) return 1 ;;
  esac
}

detect_wired_ethernet_ports() {
  local iface_path
  local iface
  local detected=()

  for iface_path in /sys/class/net/*; do
    iface="$(basename "$iface_path")"

    if is_wired_ethernet_candidate "$iface"; then
      detected+=("$iface")
    fi
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

cleanup_dhcp_runtime() {
  mkdir -p "$DHCP_RUNTIME_DIR"
  rm -f "${DHCP_RUNTIME_DIR}"/dhclient-ns*.leases
  rm -f "${DHCP_RUNTIME_DIR}"/dhclient-ns*.pid
  rm -f "${DHCP_RUNTIME_DIR}"/dhclient-ns*.conf
}

cleanup_ns() {
  local ns
  local pid
  local link_name

  for ns in "${NS[@]}"; do
    if ip netns pids "$ns" >/dev/null 2>&1; then
      while read -r pid; do
        if [ -n "$pid" ]; then
          kill -TERM "$pid" 2>/dev/null || true
        fi
      done < <(ip netns pids "$ns" 2>/dev/null || true)
    fi

    ip netns del "$ns" 2>/dev/null || true
  done

  while read -r link_name; do
    if [ -n "$link_name" ]; then
      ip link del "$link_name" 2>/dev/null || true
    fi
  done < <(
    ip -o link show |
      awk -F': ' '{print $2}' |
      cut -d'@' -f1 |
      grep -E '^veth[0-9]+_(host|ns)$' 2>/dev/null || true
  )
}

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
  ip addr flush dev "$ifh" || true
  ip link set "$ifh" master "$BRIDGE"
  ip link set "$ifh" up

  ip netns add "$ns"
  ip link set "$ifn" netns "$ns"
  ip netns exec "$ns" ip link set lo up
  ip netns exec "$ns" ip link set "$ifn" address "$(uniq_mac "$ifn")"
  ip netns exec "$ns" ip addr flush dev "$ifn" || true
  ip netns exec "$ns" ip link set "$ifn" up
}

attach_port_to_bridge() {
  local iface="$1"
  local current_master=""

  if ! ip link show "$iface" >/dev/null 2>&1; then
    log "ERROR: Interface ${iface} disappeared before bridge attach."
    exit 1
  fi

  current_master="$(basename "$(readlink "/sys/class/net/${iface}/master" 2>/dev/null || echo '')")"

  if [ -n "$current_master" ] && [ "$current_master" != "$BRIDGE" ]; then
    log "ERROR: ${iface} is already enslaved to ${current_master}, refusing to steal it."
    exit 1
  fi

  log "Adding wired port ${iface} to ${BRIDGE}"

  ip link set "$iface" up || true
  ip addr flush dev "$iface" || true
  ip link set "$iface" master "$BRIDGE"

  BRIDGE_PORTS_ADDED_BY_ISI+=("$iface")
}

setup_bridge_for_isi() {
  local bridge_ports=()
  local iface

  if ! is_pi_zero_like; then
    log "ERROR: ISI auto bridge setup is only supported on Pi Zero/Zero 2W by this module."
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

  ip addr flush dev "$BRIDGE" || true
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
  local iface

  if [ "${#BRIDGE_PORTS_ADDED_BY_ISI[@]}" -gt 0 ]; then
    for iface in "${BRIDGE_PORTS_ADDED_BY_ISI[@]}"; do
      ip link set "$iface" nomaster 2>/dev/null || true
      ip link set "$iface" up 2>/dev/null || true
    done
  fi

  if [ "$BRIDGE_CREATED_BY_ISI" -eq 1 ]; then
    log "Tearing down ${BRIDGE} created by ISI."
    ip link set "$BRIDGE" down 2>/dev/null || true
    ip link del "$BRIDGE" type bridge 2>/dev/null || true
  fi
}

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
  : >"$conf_file"

  ip netns exec "$ns" ip addr flush dev "$iface" || true

  log "Requesting fresh DHCP address for ${ns} on ${iface}. Stable simulator MAC, empty lease file, no cached lease, no static COPILOT IP."

  dhcp_out="$(
    ip netns exec "$ns" dhclient \
      -4 \
      -1 \
      -v \
      -d \
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

full_cleanup() {
  cleanup_ns
  cleanup_dhcp_runtime
  teardown_bridge_for_isi
}

trap full_cleanup EXIT

setup_bridge_for_isi
cleanup_dhcp_runtime

for _ in {1..20}; do
  if ip -br link show "$BRIDGE" | grep -q '\<UP\>'; then
    break
  fi
  sleep 1
done

if ! ip -br link show "$BRIDGE" | grep -q '\<UP\>'; then
  log "ERROR: ${BRIDGE} not UP"
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

cleanup_ns
cleanup_dhcp_runtime

discover_copilot_from_dhcp() {
  local dhcp_out="$1"
  local srv=""
  local gw=""

  if [ -n "$DEST_IP" ]; then
    return 0
  fi

  srv="$(printf '%s\n' "$dhcp_out" | sed -nE 's/.*DHCPACK of [^ ]+ from ([0-9.]+).*/\1/p' | tail -1)"

  if [[ "$srv" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
    DEST_IP="$srv"
    log "COPILOT candidate discovered from DHCPACK server: ${DEST_IP}"
    return 0
  fi

  gw="$(printf '%s\n' "$dhcp_out" | sed -nE 's/.*option routers[[:space:]]+([0-9.]+).*/\1/p' | tail -1)"

  if [[ "$gw" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
    DEST_IP="$gw"
    log "COPILOT candidate discovered from DHCP router option: ${DEST_IP}"
    return 0
  fi
}

for i in "${!NS[@]}"; do
  ns="${NS[$i]}"
  idx=$((i + 1))

  add_veth_to_br "$idx" "$ns"

  DHCP_OUT="$(request_fresh_dhcp "$ns" "veth${idx}_ns")"

  if ! printf '%s' "$DHCP_OUT" | grep -q 'DHCPACK'; then
    log "ERROR: DHCP failed in ${ns}"
    log "DHCP output follows:"
    printf '%s\n' "$DHCP_OUT" >&2
    exit 1
  fi

  ns_ip="$(ip netns exec "$ns" ip -o -4 addr show "veth${idx}_ns" | awk '{print $4}' | cut -d/ -f1 || true)"
  NS_IPS+=("${ns_ip:-}")
  log "${ns} got IP ${ns_ip:-unknown} via fresh DHCP"

  discover_copilot_from_dhcp "$DHCP_OUT"

  if [ -z "$DEST_IP" ]; then
    gw="$(ip netns exec "$ns" ip route show default 2>/dev/null | awk '/^default via /{print $3; exit}')"
    if [[ "$gw" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
      DEST_IP="$gw"
      log "COPILOT candidate discovered from namespace default gateway: ${DEST_IP}"
    fi
  fi
done

if [ -z "$DEST_IP" ]; then
  log "ERROR: Could not determine COPILOT IP from DHCP server, DHCP router option, or namespace gateway."
  log "ERROR: No hardcoded fallback IP is configured by design."
  exit 1
fi

log "COPILOT target discovered dynamically at ${DEST_IP}"

start_isi_loop() {
  local ns="$1"
  local file="$2"
  local name="$3"

  log "Starting persistent ISI client ${name} in ${ns}"

  ip netns exec "$ns" bash -lc '
    while true; do
      nc "'"$DEST_IP"'" 51001 < "'"$file"'" || sleep 1
    done
  ' &
}

start_isi_loop "${NS[0]}" "${ISI_FILES[0]}" "${NAMES[0]}"
start_isi_loop "${NS[1]}" "${ISI_FILES[1]}" "${NAMES[1]}"

zeit_ns="${NS[2]}"
zeit_file="${ISI_FILES[2]}"

log "ZEITNEHMER loop starting in ${zeit_ns}"

LAST_TIME_SYNC=0

while true; do
  NOW_EPOCH="$(date +%s)"

  if [ $((NOW_EPOCH - LAST_TIME_SYNC)) -ge "$TIME_SYNC_INTERVAL" ]; then
    LAST_TIME_SYNC="$NOW_EPOCH"

    log "ZEITNEHMER: requesting time from COPILOT at ${DEST_IP}"

    TIME_RESPONSE="$(ip netns exec "$zeit_ns" nc "$DEST_IP" 51001 -w 5 < "$zeit_file" || true)"
    log "ZEITNEHMER: raw response snippet: $(echo "$TIME_RESPONSE" | tr '\n' ' ' | head -c 400)"

    ISO_DT="$(
      echo "$TIME_RESPONSE" |
        grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}([.,][0-9]+)?(Z|[+-][0-9]{2}:?[0-9]{2})?' |
        head -n1 || true
    )"

    DT="$(
      echo "$TIME_RESPONSE" |
        grep -oE '[0-9]{2}\.[0-9]{2}\.[0-9]{4}-[0-9]{2}:[0-9]{2}:[0-9]{2}' |
        head -n1 || true
    )"

    MASTER_EPOCH=0

    if [ -n "$ISO_DT" ]; then
      log "ZEITNEHMER: COPILOT Time_ISO8601=${ISO_DT}"
      MASTER_EPOCH="$(date -d "$ISO_DT" +%s 2>/dev/null || echo 0)"
    elif [ -n "$DT" ]; then
      log "ZEITNEHMER: COPILOT DateTime=${DT}"
      dpart="${DT%%-*}"
      tpart="${DT#*-}"
      IFS='.' read -r DD MM YYYY <<<"$dpart"
      MASTER_EPOCH="$(date -d "${YYYY}-${MM}-${DD} ${tpart}" +%s 2>/dev/null || echo 0)"
    else
      log "ZEITNEHMER: no Time_ISO8601 or DateTime pattern in response"
    fi

    if [ "$MASTER_EPOCH" -gt 0 ]; then
      NOW_EPOCH="$(date +%s)"
      DIFF=$((MASTER_EPOCH - NOW_EPOCH))
      ADIFF="${DIFF#-}"

      log "ZEITNEHMER: current Pi epoch=${NOW_EPOCH}, COPILOT epoch=${MASTER_EPOCH}, drift=${DIFF}s"

      if [ "$ADIFF" -gt "$DRIFT_THRESHOLD" ]; then
        log "ZEITNEHMER: drift ${ADIFF}s > ${DRIFT_THRESHOLD}s; updating system clock"
        if ! date -s "@${MASTER_EPOCH}" >/dev/null 2>&1; then
          log "ZEITNEHMER: failed to set system time"
        fi
      else
        log "ZEITNEHMER: drift ${ADIFF}s <= ${DRIFT_THRESHOLD}s; no adjust"
      fi
    elif [ -n "$ISO_DT" ] || [ -n "$DT" ]; then
      log "ZEITNEHMER: could not parse COPILOT time value"
    fi
  else
    ip netns exec "$zeit_ns" nc "$DEST_IP" 51001 < "$zeit_file" >/dev/null 2>&1 ||
      log "ZEITNEHMER: nc send failed"
  fi

  sleep 1
done
EOF

  chmod 755 "$ISI_RUNNER"
  chown root:root "$ISI_RUNNER" || true
}

write_isi_payloads() {
  log "Writing ${ISI_PAYLOAD_1}"
  cat >"$ISI_PAYLOAD_1" <<'EOF'
<IsiPut><AppName>DRACHE</AppName></IsiPut>
<IsiGet><Items>CurrentSoftwareVersion</Items><Cyclic>1</Cyclic></IsiGet>
EOF

  log "Writing ${ISI_PAYLOAD_2}"
  cat >"$ISI_PAYLOAD_2" <<'EOF'
<IsiPut><AppName>NIX</AppName></IsiPut>
<IsiGet><Items>DeviceState</Items><Cyclic>1</Cyclic></IsiGet>
EOF

  log "Writing ${ISI_PAYLOAD_3}"
  cat >"$ISI_PAYLOAD_3" <<'EOF'
<IsiPut><AppName>ZEITNEHMER</AppName></IsiPut>
<IsiGet><Items>DateTime,Time_ISO8601</Items><Cyclic>5</Cyclic></IsiGet>
EOF

  chown root:root "$ISI_PAYLOAD_1" "$ISI_PAYLOAD_2" "$ISI_PAYLOAD_3" 2>/dev/null || true
  chmod 644 "$ISI_PAYLOAD_1" "$ISI_PAYLOAD_2" "$ISI_PAYLOAD_3"
}

write_isi_service() {
  log "Installing isirunall.service"

  cat >"$ISI_SERVICE_FILE" <<EOF
[Unit]
Description=ISI simulator (3ns + ISI clients over adaptive br0)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
ExecStart=${ISI_RUNNER}
Restart=on-failure
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
}

restart_isi_service() {
  systemctl daemon-reload
  systemctl enable isirunall.service
  systemctl restart isirunall.service
}

stop_and_disable_unit() {
  local unit_name="$1"

  log "stopping and disabling $unit_name if present"
  systemctl disable --now "$unit_name" 2>/dev/null || true
  systemctl reset-failed "$unit_name" 2>/dev/null || true
}

cleanup_runtime_network_state() {
  local link_name

  log "cleaning ISI runtime namespaces, veth links, DHCP runtime state, and host bridge IP state"

  ip netns del ns1 2>/dev/null || true
  ip netns del ns2 2>/dev/null || true
  ip netns del ns3 2>/dev/null || true

  while read -r link_name; do
    if [ -n "$link_name" ]; then
      ip link del "$link_name" 2>/dev/null || true
    fi
  done < <(
    ip -o link show |
      awk -F': ' '{print $2}' |
      cut -d'@' -f1 |
      grep -E '^veth[0-9]+_(host|ns)$' 2>/dev/null || true
  )

  rm -rf /run/initbox-isi 2>/dev/null || true
}

remove_isi_files() {
  log "removing ISI files"

  rm -f "$ISI_RUNNER"
  rm -f "$ISI_PAYLOAD_1"
  rm -f "$ISI_PAYLOAD_2"
  rm -f "$ISI_PAYLOAD_3"
  rm -f "$ISI_SERVICE_FILE"
}

purge_isi_packages() {
  log "purging ISI dependency packages"

  apt_safe purge -y isc-dhcp-client netcat-openbsd
  apt_safe autoremove -y
}

print_install_summary() {
  echo
  echo "ISI simulator installed"
  echo "-----------------------"
  echo "Service: isirunall.service"
  echo "Runner:  ${ISI_RUNNER}"
  echo
  echo "Bridge behavior:"
  echo "  - Detects all wired Ethernet ports dynamically"
  echo "  - Adds detected wired ports plus ISI veth ports to br0"
  echo "  - Uses fresh DHCP inside namespaces"
  echo "  - Uses random veth MACs on each service start"
  echo "  - Deletes DHCP lease/config/pid files before each namespace DHCP request"
  echo "  - Does not read global dhclient lease memory"
  echo "  - Does not use a hardcoded COPILOT IP"
  echo
  echo "Check:"
  echo "  sudo systemctl status isirunall.service --no-pager"
  echo "  sudo journalctl -u isirunall.service -n 100 --no-pager"
  echo "  bridge link"
  echo "  sudo ip netns exec ns1 ip -br addr"
  echo "  grep -n 'Time_ISO8601' ${ISI_PAYLOAD_3}"
}

print_uninstall_summary() {
  echo
  echo "ISI simulator uninstalled"
  echo "-------------------------"
  echo "Removed:"
  echo "  - isirunall.service"
  echo "  - ${ISI_RUNNER}"
  echo "  - ${ISI_PAYLOAD_1}"
  echo "  - ${ISI_PAYLOAD_2}"
  echo "  - ${ISI_PAYLOAD_3}"
  echo "  - runtime namespaces ns1/ns2/ns3 if present"
  echo "  - runtime veth links if present"
  echo "  - /run/initbox-isi DHCP runtime state if present"
  echo
  echo "Not removed:"
  echo "  - installed dependency packages"
  echo "  - existing bridge br0 if it was not deleted by the running service"
}

print_purge_summary() {
  echo
  echo "ISI simulator purged"
  echo "--------------------"
  echo "Removed ISI service/files and purged:"
  echo "  - isc-dhcp-client"
  echo "  - netcat-openbsd"
}

install_main() {
  require_root
  ensure_log_dir
  install_dependencies
  configure_isi_network_managers
  write_isi_runner
  write_isi_payloads
  write_isi_service
  restart_isi_service
  print_install_summary
  ok "ISI simulator module installed."
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

purge_main() {
  require_root
  ensure_log_dir

  stop_and_disable_unit "isirunall.service"
  cleanup_runtime_network_state
  remove_isi_network_manager_overrides
  remove_isi_files
  purge_isi_packages

  systemctl daemon-reload
  systemctl reset-failed 2>/dev/null || true

  print_purge_summary
  ok "ISI simulator module purged."
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
      purge_main
      ;;
    *)
      err "unknown action '$ACTION'. Use install, uninstall, or purge."
      exit 1
      ;;
  esac
}

main "$@"
