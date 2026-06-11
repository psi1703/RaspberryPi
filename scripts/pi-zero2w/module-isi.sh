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
ISI_DHCP_RUNTIME_DIR="/run/initbox-isi"
NM_ISI_CONF="/etc/NetworkManager/conf.d/99-initbox-isi-unmanaged.conf"
DHCPCD_CONF="/etc/dhcpcd.conf"
DHCPCD_BLOCK_START="# BEGIN InitBox ISI bridge unmanaged"
DHCPCD_BLOCK_END="# END InitBox ISI bridge unmanaged"

# ----------------------------------------------------------------------------
# Logging
# ----------------------------------------------------------------------------

ts() { date +"%Y-%m-%d %H:%M:%S"; }
log()  { echo "[ISI $(ts)] $*"        | tee -a "$LOGFILE"; }
ok()   { echo "[ISI $(ts)] [OK] $*"   | tee -a "$LOGFILE"; }
warn() { echo "[ISI $(ts)] [WARN] $*" | tee -a "$LOGFILE" >&2; }
err()  { echo "[ISI $(ts)] [ERR] $*"  | tee -a "$LOGFILE" >&2; }

apt_safe() {
  apt-get -o Dpkg::Use-Pty=0 -o Acquire::Retries=5 "$@" 2>&1 | tee -a "$LOGFILE"
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

# ----------------------------------------------------------------------------
# Dependency management
# ----------------------------------------------------------------------------

install_dependencies() {
  log "Installing ISI simulator dependencies"
  apt_safe update
  apt_safe install -y isc-dhcp-client netcat-openbsd
}

purge_isi_packages() {
  log "Purging ISI dependency packages"
  apt_safe purge -y isc-dhcp-client netcat-openbsd
  apt_safe autoremove -y
}

# ----------------------------------------------------------------------------
# Network manager configuration
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

configure_isi_network_managers() {
  log "Configuring host network managers to leave ISI bridge ports unmanaged"

  # NetworkManager
  if systemctl list-unit-files NetworkManager.service >/dev/null 2>&1; then
    mkdir -p "$(dirname "$NM_ISI_CONF")"
    cat >"$NM_ISI_CONF" <<'NM_EOF'
[keyfile]
unmanaged-devices=interface-name:eth0;interface-name:eth1;interface-name:br0;interface-name:veth*
NM_EOF
    systemctl restart NetworkManager 2>/dev/null || true
    # keyfile unmanaged is ignored when a saved connection profile exists;
    # nmcli device set is the only reliable way to release an already-managed interface.
    nmcli device set eth0 managed no 2>/dev/null || true
    nmcli device set eth1 managed no 2>/dev/null || true
  fi

  # dhcpcd
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

  # Flush any IPs the host may have grabbed on bridge-related interfaces
  for _iface in eth0 eth1 br0; do
    ip addr flush dev "$_iface" 2>/dev/null || true
  done

  while read -r _link; do
    [ -n "$_link" ] && ip addr flush dev "$_link" 2>/dev/null || true
  done < <(
    ip -o link show \
      | awk -F': ' '{print $2}' \
      | cut -d'@' -f1 \
      | grep -E '^veth[0-9]+_host$' 2>/dev/null || true
  )
}

remove_isi_network_manager_overrides() {
  log "Removing ISI network-manager overrides"
  rm -f "$NM_ISI_CONF" 2>/dev/null || true
  remove_dhcpcd_isi_block
  systemctl restart NetworkManager 2>/dev/null || true
  systemctl restart dhcpcd       2>/dev/null || true
}

# ----------------------------------------------------------------------------
# isirunall.sh — the persistent runner written to disk
# ----------------------------------------------------------------------------

write_isi_runner() {
  log "Writing ${ISI_RUNNER}"

  cat >"$ISI_RUNNER" <<'RUNNER_EOF'
#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# Runtime configuration (all overridable via environment)
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
log() { echo "[ISI $(date +%F_%T)] $*"; }

# ---------------------------------------------------------------------------
# Interface helpers
# ---------------------------------------------------------------------------

is_excluded_interface() {
  local iface="$1"
  case "$iface" in
    lo|wlan*|wifi*|br*|veth*|docker*|virbr*|tap*|tun*|wg*|tailscale*|zt* \
    |dummy*|ifb*|sit*|ip6tnl*|gre*|gretap*)
      return 0 ;;
    *) return 1 ;;
  esac
}

is_wired_ethernet_candidate() {
  local iface="$1"
  local dev_type=""

  is_excluded_interface "$iface" && return 1
  [ -r "/sys/class/net/${iface}/type" ] || return 1

  dev_type="$(cat "/sys/class/net/${iface}/type" 2>/dev/null || echo '')"
  [ "$dev_type" = "1" ] || return 1

  case "$iface" in
    eth*|en*|usb*) return 0 ;;
    *) return 1 ;;
  esac
}

detect_wired_ethernet_ports() {
  local iface_path iface
  local detected=()

  for iface_path in /sys/class/net/*; do
    iface="$(basename "$iface_path")"
    is_wired_ethernet_candidate "$iface" && detected+=("$iface")
  done

  [ "${#detected[@]}" -gt 0 ] && printf '%s\n' "${detected[@]}" | sort -V
}

detect_bridge_ports() {
  local wired_ifs=()

  if [ -n "$UPLINK_IF" ]; then
    ip link show "$UPLINK_IF" >/dev/null 2>&1 || {
      log "ERROR: UPLINK_IF=${UPLINK_IF} does not exist."
      exit 1
    }
    is_wired_ethernet_candidate "$UPLINK_IF" || {
      log "ERROR: UPLINK_IF=${UPLINK_IF} is not a valid wired Ethernet candidate."
      exit 1
    }
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
# Bridge setup / teardown
# ---------------------------------------------------------------------------

is_pi_zero_like() {
  local model
  model="$(tr -d '\0' </proc/device-tree/model 2>/dev/null || echo '')"
  case "$model" in *"Zero"*) return 0 ;; *) return 1 ;; esac
}

attach_port_to_bridge() {
  local iface="$1"
  local current_master=""

  ip link show "$iface" >/dev/null 2>&1 || {
    log "ERROR: Interface ${iface} disappeared before bridge attach."
    exit 1
  }

  current_master="$(basename "$(readlink "/sys/class/net/${iface}/master" 2>/dev/null || echo '')")"

  if [ -n "$current_master" ] && [ "$current_master" != "$BRIDGE" ]; then
    log "ERROR: ${iface} is already enslaved to ${current_master}, refusing to steal it."
    exit 1
  fi

  # Already attached to the right bridge — skip
  [ "$current_master" = "$BRIDGE" ] && return 0

  log "Adding wired port ${iface} to ${BRIDGE}"
  ip addr flush dev "$iface" 2>/dev/null || true
  ip link set "$iface" up
  ip link set "$iface" master "$BRIDGE"

  BRIDGE_PORTS_ADDED_BY_ISI+=("$iface")
}

setup_bridge_for_isi() {
  local bridge_ports=()
  local iface

  is_pi_zero_like || {
    log "ERROR: ISI auto bridge setup is only supported on Pi Zero/Zero 2W by this module."
    exit 1
  }

  mapfile -t bridge_ports < <(detect_bridge_ports)
  log "Detected wired Ethernet bridge ports: ${bridge_ports[*]}"

  if ip link show "$BRIDGE" >/dev/null 2>&1; then
    log "${BRIDGE} already exists; reusing it and ensuring all detected wired ports are attached."
  else
    log "Creating ${BRIDGE} for ISI."
    ip link add name "$BRIDGE" type bridge
    BRIDGE_CREATED_BY_ISI=1
  fi

  # KEY FIX: disable STP and set forward_delay 0 so bridge ports
  # enter forwarding state immediately — without this, the STP
  # learning phase (15-30s) causes DHCP DISCOVERs to time out.
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
  local iface

  for iface in "${BRIDGE_PORTS_ADDED_BY_ISI[@]+"${BRIDGE_PORTS_ADDED_BY_ISI[@]}"}"; do
    ip link set "$iface" nomaster 2>/dev/null || true
    ip link set "$iface" up      2>/dev/null || true
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
  local ns pid link_name

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
        "${DHCP_RUNTIME_DIR}"/dhclient-ns*.pid    \
        "${DHCP_RUNTIME_DIR}"/dhclient-ns*.conf
}

# Deterministic locally-administered MAC derived from interface name
uniq_mac() {
  local seed="$1"
  local hash
  hash="$(printf "%s" "$seed" | sha1sum | awk '{print $1}')"
  printf "02:%s:%s:%s:%s:%s\n" \
    "${hash:0:2}" "${hash:2:2}" "${hash:4:2}" "${hash:6:2}" "${hash:8:2}"
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
  ip netns exec "$ns" ip link set lo   up
  ip netns exec "$ns" ip link set "$ifn" address "$(uniq_mac "$ifn")"
  ip netns exec "$ns" ip addr flush dev "$ifn" 2>/dev/null || true
  ip netns exec "$ns" ip link set "$ifn" up
}

# ---------------------------------------------------------------------------
# DHCP inside namespace
#
# Broadcast flag via conf file:
#   "send flags 0x8000" sets the broadcast bit (bit 15) in the BOOTP flags
#   field of DHCPDISCOVER/DHCPREQUEST.  RFC 2131-compliant servers must then
#   send DHCPOFFER/DHCPACK to 255.255.255.255 instead of unicasting to the
#   client MAC.  This eliminates the FDB learning race where a unicast OFFER
#   arrives before the bridge has learned the veth MAC and gets dropped.
#
#   Note: dhclient 4.4.3-P1 on Debian Bookworm does not have the -B CLI flag
#   (stripped from the package); the conf file directive is used instead.
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

  # send flags 0x8000 sets the broadcast bit in BOOTP flags — COPILOT must
  # respond with a broadcast OFFER, avoiding the bridge FDB learning race.
  # Top-level directive (no interface block) avoids a dhclient parse warning.
  # No send host-name so the namespace stays anonymous on the COPILOT LAN.
  printf 'request subnet-mask, routers, domain-name-servers, broadcast-address;\nsend flags 0x8000;\n' \
    >"$conf_file"

  ip netns exec "$ns" ip addr flush dev "$iface" 2>/dev/null || true

  log "Requesting fresh DHCP for ${ns} on ${iface} (broadcast-mode, stable MAC, empty lease)"

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

  # Clean up dhclient daemon if it somehow stayed alive
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
  local srv="" gw=""

  [ -n "$DEST_IP" ] && return 0

  # Prefer the DHCPACK server address — that IS COPILOT
  srv="$(printf '%s\n' "$dhcp_out" \
    | sed -nE 's/.*DHCPACK of [^ ]+ from ([0-9.]+).*/\1/p' \
    | tail -1)"

  if [[ "$srv" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
    DEST_IP="$srv"
    log "COPILOT discovered from DHCPACK server address: ${DEST_IP}"
    return 0
  fi

  # Fall back to routers option
  gw="$(printf '%s\n' "$dhcp_out" \
    | sed -nE 's/.*option routers[[:space:]]+([0-9.]+).*/\1/p' \
    | tail -1)"

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

  log "Starting persistent ISI client ${name} in ${ns} → ${DEST_IP}:51001"

  ip netns exec "$ns" bash -lc "
    while true; do
      nc '${DEST_IP}' 51001 < '${file}' || sleep 1
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
# Main: bridge → namespaces → DHCP → ISI loops
# ---------------------------------------------------------------------------

setup_bridge_for_isi
cleanup_dhcp_runtime
cleanup_ns

# Wait for bridge to come UP (it should be immediate with STP disabled)
for _ in {1..10}; do
  ip -br link show "$BRIDGE" | grep -q '\<UP\>' && break
  sleep 1
done

ip -br link show "$BRIDGE" | grep -q '\<UP\>' || {
  log "ERROR: ${BRIDGE} did not come UP"
  exit 1
}

log "${BRIDGE} is UP"

command -v dhclient >/dev/null 2>&1 || { log "ERROR: dhclient missing"; exit 1; }
{ command -v nc >/dev/null 2>&1 || command -v netcat >/dev/null 2>&1; } \
  || { log "ERROR: nc/netcat missing"; exit 1; }

# Add a veth pair + namespace for each ISI client, then get a DHCP lease
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

  ns_ip="$(ip netns exec "$ns" ip -o -4 addr show "veth${idx}_ns" \
    | awk '{print $4}' | cut -d/ -f1 || true)"
  NS_IPS+=("${ns_ip:-}")
  log "${ns} assigned IP ${ns_ip:-unknown}"

  discover_copilot_from_dhcp "$DHCP_OUT"

  # Last-resort: check the default gateway inside the namespace
  if [ -z "$DEST_IP" ]; then
    gw="$(ip netns exec "$ns" ip route show default 2>/dev/null \
      | awk '/^default via /{print $3; exit}')"
    if [[ "$gw" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
      DEST_IP="$gw"
      log "COPILOT discovered from namespace default gateway: ${DEST_IP}"
    fi
  fi
done

[ -n "$DEST_IP" ] || {
  log "ERROR: Could not determine COPILOT IP from DHCP server, routers option, or default gateway."
  exit 1
}

log "COPILOT target: ${DEST_IP}"

# Start DRACHE and NIX as fire-and-forget loops
start_isi_loop "${NS[0]}" "${ISI_FILES[0]}" "${NAMES[0]}"
start_isi_loop "${NS[1]}" "${ISI_FILES[1]}" "${NAMES[1]}"

# ---------------------------------------------------------------------------
# ZEITNEHMER loop — also does clock sync
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

    TIME_RESPONSE="$(ip netns exec "$zeit_ns" nc "$DEST_IP" 51001 -w 5 \
      < "$zeit_file" || true)"

    log "ZEITNEHMER: response snippet: $(printf '%s' "$TIME_RESPONSE" \
      | tr '\n' ' ' | head -c 400)"

    # Try ISO 8601 first, then DD.MM.YYYY-HH:MM:SS
    ISO_DT="$(printf '%s\n' "$TIME_RESPONSE" \
      | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}([.,][0-9]+)?(Z|[+-][0-9]{2}:?[0-9]{2})?' \
      | head -n1 || true)"

    DT="$(printf '%s\n' "$TIME_RESPONSE" \
      | grep -oE '[0-9]{2}\.[0-9]{2}\.[0-9]{4}-[0-9]{2}:[0-9]{2}:[0-9]{2}' \
      | head -n1 || true)"

    MASTER_EPOCH=0

    if [ -n "$ISO_DT" ]; then
      log "ZEITNEHMER: Time_ISO8601=${ISO_DT}"
      MASTER_EPOCH="$(date -d "$ISO_DT" +%s 2>/dev/null || echo 0)"
    elif [ -n "$DT" ]; then
      log "ZEITNEHMER: DateTime=${DT}"
      dpart="${DT%%-*}"
      tpart="${DT#*-}"
      IFS='.' read -r DD MM YYYY <<<"$dpart"
      MASTER_EPOCH="$(date -d "${YYYY}-${MM}-${DD} ${tpart}" +%s 2>/dev/null || echo 0)"
    else
      log "ZEITNEHMER: no recognisable timestamp in response"
    fi

    if [ "$MASTER_EPOCH" -gt 0 ]; then
      NOW_EPOCH="$(date +%s)"
      DIFF=$((MASTER_EPOCH - NOW_EPOCH))
      ADIFF="${DIFF#-}"
      log "ZEITNEHMER: Pi=${NOW_EPOCH} COPILOT=${MASTER_EPOCH} drift=${DIFF}s"

      if [ "$ADIFF" -gt "$DRIFT_THRESHOLD" ]; then
        log "ZEITNEHMER: drift ${ADIFF}s > ${DRIFT_THRESHOLD}s — adjusting clock"
        date -s "@${MASTER_EPOCH}" >/dev/null 2>&1 \
          || log "ZEITNEHMER: clock set failed"
      else
        log "ZEITNEHMER: drift ${ADIFF}s within threshold — no adjust"
      fi
    elif [ -n "$ISO_DT" ] || [ -n "$DT" ]; then
      log "ZEITNEHMER: could not parse timestamp value"
    fi

  else
    # Off-cycle: just send the payload, discard response
    ip netns exec "$zeit_ns" nc "$DEST_IP" 51001 \
      < "$zeit_file" >/dev/null 2>&1 \
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
  chmod 644       "$ISI_PAYLOAD_1" "$ISI_PAYLOAD_2" "$ISI_PAYLOAD_3"
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
ExecStartPre=/usr/bin/nmcli device set eth0 managed no
ExecStartPre=/usr/bin/nmcli device set eth1 managed no
ExecStartPre=/sbin/ip addr flush dev eth0
ExecStartPre=/sbin/ip addr flush dev eth1
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
  systemctl enable  isirunall.service
  systemctl restart isirunall.service
}

# ----------------------------------------------------------------------------
# Install / uninstall / purge helpers
# ----------------------------------------------------------------------------

stop_and_disable_unit() {
  local unit_name="$1"
  log "Stopping and disabling ${unit_name}"
  systemctl disable --now "$unit_name" 2>/dev/null || true
  systemctl reset-failed  "$unit_name" 2>/dev/null || true
}

cleanup_runtime_network_state() {
  local link_name

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

Key behaviours:
  - STP disabled, forward_delay 0        → bridge ports enter forwarding immediately
  - send flags 0x8000 in dhclient conf   → OFFER delivered as broadcast, no FDB race
  - ExecStartPre releases NM eth0/eth1   → NM can't race to re-grab interfaces
  - Deterministic veth MACs        → stable across restarts
  - Fresh DHCP per namespace       → no stale lease interference
  - COPILOT IP discovered from DHCP server / routers option / default gateway
  - No hardcoded COPILOT IP

Check status:
  sudo systemctl status isirunall.service --no-pager
  sudo journalctl -u isirunall.service -n 100 --no-pager
  bridge link
  sudo ip netns exec ns1 ip -br addr
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

Not removed:
  - dependency packages (use 'purge' to remove those too)
SUMMARY
}

print_purge_summary() {
  cat <<SUMMARY

ISI simulator purged
--------------------
Removed service, files, and packages:
  - isc-dhcp-client
  - netcat-openbsd
SUMMARY
}

# ----------------------------------------------------------------------------
# Action entry points
# ----------------------------------------------------------------------------

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
    install|"")  install_main   ;;
    uninstall|remove) uninstall_main ;;
    purge)       purge_main     ;;
    *)
      err "Unknown action '${ACTION}'. Use: install, uninstall, purge."
      exit 1
      ;;
  esac
}

main "$@"
