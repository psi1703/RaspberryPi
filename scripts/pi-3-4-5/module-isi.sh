#!/usr/bin/env bash
set -euo pipefail

: "${OWNER:=initbox}"
: "${SCRIPT_DIR:=$(cd "$(dirname "$0")" && pwd)}"
: "${LOGFILE:=/home/${OWNER}/pi_logs/initbox-install.log}"

ts(){ date +"%Y-%m-%d %H:%M:%S"; }
log(){  echo "[ISI $(ts)] $*" | tee -a "$LOGFILE"; }
ok(){   echo "[ISI $(ts)] [OK] $*" | tee -a "$LOGFILE"; }
warn(){ echo "[ISI  $(ts)] [WARN] $*" | tee -a "$LOGFILE" >&2; }
err(){  echo "[ISI  $(ts)] [ERR] $*"  | tee -a "$LOGFILE" >&2; }

apt_safe(){
  apt-get -o Dpkg::Use-Pty=0 -o Acquire::Retries=5 "$@" 2>&1 | tee -a "$LOGFILE"
}

log "Installing ISI simulator dependencies …"
apt_safe update -y
apt_safe install -y isc-dhcp-client netcat-openbsd

log "Writing isirunall.sh"
cat >/usr/local/bin/isirunall.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

# Config ----------
BRIDGE="${BRIDGE:-br0}"

# DRACHE, NIX, ZEITNEHMER
ISI_FILES=(
  "/usr/local/bin/isi1.txt"
  "/usr/local/bin/isi2.txt"
  "/usr/local/bin/isi3.txt"
)
NAMES=(DRACHE NIX ZEITNEHMER)
NS=(ns1 ns2 ns3)

# Time sync behaviour
DRIFT_THRESHOLD="${DRIFT_THRESHOLD:-2}"        # seconds
TIME_SYNC_INTERVAL="${TIME_SYNC_INTERVAL:-3600}" # seconds between time syncs

DEST_IP=""                 # COPILOT IP discovered via DHCP
NS_IPS=()                  # Collected namespace IPs
UPLINK_IF="${UPLINK_IF:-}" # wired uplink; auto-detected on Zero/Zero 2W
BRIDGE_CREATED_BY_ISI=0

log() {
  echo "[ISI $(date +%F_%T)] $*"
}

# Helpers ----------
is_pi_zero_like() {
  local m
  m="$(tr -d '\0' </proc/device-tree/model 2>/dev/null || echo '')"
  case "$m" in
    *"Zero"*)  return 0 ;;  # includes Zero, Zero W, Zero 2 W
    *)         return 1 ;;
  esac
}

cleanup_ns() {
  local ns
  for ns in "${NS[@]}"; do
    ip netns del "$ns" 2>/dev/null || true
  done

  # Drop any leftover veths we created
  ip -o link show | awk -F': ' '{print $2}' | cut -d'@' -f1 |
    grep -E '^veth[0-9]+_(host|ns)$' 2>/dev/null |
    xargs -r -I{} ip link del "{}" 2>/dev/null || true
}

uniq_mac() {
  local seed="$1"
  local h
  h="$(printf "%s" "$seed" | sha1sum | awk '{print $1}')"
  printf "02:%s:%s:%s:%s:%s\n" "${h:0:2}" "${h:2:2}" "${h:4:2}" "${h:6:2}" "${h:8:2}"
}

add_veth_to_br() {
  local idx="$1" ns="$2"
  local ifh="veth${idx}_host"
  local ifn="veth${idx}_ns"

  ip link del "$ifh" 2>/dev/null || true
  ip link del "$ifn" 2>/dev/null || true

  ip link add "$ifh" type veth peer name "$ifn"
  ip link set "$ifh" address "$(uniq_mac "$ifh")"
  ip link set "$ifh" master "$BRIDGE" || true
  ip link set "$ifh" up

  ip netns add "$ns"
  ip link set "$ifn" netns "$ns"
  ip netns exec "$ns" ip link set lo up
  ip netns exec "$ns" ip link set "$ifn" address "$(uniq_mac "$ifn")"
  ip netns exec "$ns" ip link set "$ifn" up
}

setup_bridge_for_isi() {
  # If bridge already exists (e.g. EthSniff on bigger Pis), just use it.
  if ip link show "$BRIDGE" &>/dev/null; then
    log "$BRIDGE already exists; using existing L2 bridge."
    return 0
  fi

  # Only auto-create on Pi Zero / Zero 2W
  if ! is_pi_zero_like; then
    log "ERROR: $BRIDGE not present and auto-create is only supported on Pi Zero/Zero 2W; aborting."
    exit 1
  fi
  
  # Detect single wired NIC (USB eth / enx…)
  if [[ -z "$UPLINK_IF" ]]; then
    local WIRED_IFS=()
    mapfile -t WIRED_IFS < <(
      find /sys/class/net -maxdepth 1 -mindepth 1 -type l -printf '%f\n' \
        | grep -E '^(eth[0-9]+|enx[0-9A-Fa-f]{12})$' \
        | sort || true
    )
    if ((${#WIRED_IFS[@]} == 0)); then
      log "ERROR: No wired uplink interface found for $BRIDGE (expected USB NIC)."
      exit 1
    fi
    UPLINK_IF="${WIRED_IFS[0]}"
  fi

  log "Creating $BRIDGE for ISI on Pi Zero, uplink=$UPLINK_IF …"

  ip link add name "$BRIDGE" type bridge

  # Make uplink L2-only: drop IPs on uplink and bridge
  ip link set "$UPLINK_IF" up || true
  ip addr flush dev "$UPLINK_IF" || true
  ip addr flush dev "$BRIDGE" || true

  ip link set "$UPLINK_IF" master "$BRIDGE" || true
  ip link set "$BRIDGE" up || true

  BRIDGE_CREATED_BY_ISI=1
  log "$BRIDGE up with $UPLINK_IF as port (pure L2, no host IP)."
}

teardown_bridge_for_isi() {
  if (( BRIDGE_CREATED_BY_ISI != 1 )); then
    return 0
  fi

  if [[ -z "$UPLINK_IF" ]]; then
    return 0
  fi

  log "Tearing down $BRIDGE created by ISI and releasing $UPLINK_IF …"

  ip link set "$UPLINK_IF" nomaster 2>/dev/null || true
  ip link set "$BRIDGE" down 2>/dev/null || true
  ip link del "$BRIDGE" type bridge 2>/dev/null || true

  ip link set "$UPLINK_IF" up 2>/dev/null || true
}

full_cleanup() {
  cleanup_ns
  teardown_bridge_for_isi
}
trap full_cleanup EXIT

# Bridge + prerequisite checks ------------------
setup_bridge_for_isi

# Wait up to 20s for BRIDGE to be UP
for _ in {1..20}; do
  if ip -br link show "$BRIDGE" | grep -q '\<UP\>'; then
    break
  fi
  sleep 1
done
if ! ip -br link show "$BRIDGE" | grep -q '\<UP\>'; then
  log "ERROR: $BRIDGE not UP"
  exit 1
fi
log "$BRIDGE is UP (pure L2 path for ISI; host IP not used here)"

if ! command -v dhclient >/dev/null 2>&1; then
  log "ERROR: dhclient (isc-dhcp-client) missing"
  exit 1
fi
if ! command -v nc >/dev/null 2>&1 && ! command -v netcat >/dev/null 2>&1; then
  log "ERROR: nc/netcat missing"
  exit 1
fi

# Namespaces + DHCP + COPILOT discovery ----------
cleanup_ns

discover_copilot_from_dhcp() {
  local dhcp_out="$1"
  local srv
  if [[ -z "$DEST_IP" ]]; then
    srv="$(printf '%s\n' "$dhcp_out" | sed -nE 's/.*DHCPACK of [^ ]+ from ([0-9.]+).*/\1/p' | tail -1)"
    if [[ "$srv" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
      DEST_IP="$srv"
    fi
  fi
}

for i in "${!NS[@]}"; do
  ns="${NS[$i]}"
  idx=$((i+1))

  add_veth_to_br "$idx" "$ns"

  # One-shot DHCP inside namespace
  DHCP_OUT="$(ip netns exec "$ns" dhclient -4 -1 -v "veth${idx}_ns" 2>&1 || true)"
  if ! printf '%s' "$DHCP_OUT" | grep -q 'DHCPACK'; then
    log "ERROR: DHCP failed in $ns"
    exit 1
  fi

  # Kill any lingering dhclient in that ns
  ip netns pids "$ns" 2>/dev/null | while read -r pid; do
    if ps -p "$pid" -o comm= 2>/dev/null | grep -qx 'dhclient'; then
      kill -TERM "$pid" 2>/dev/null || true
    fi
  done

  ns_ip="$(ip netns exec "$ns" ip -o -4 addr show "veth${idx}_ns" | awk '{print $4}' | cut -d/ -f1 || true)"
  NS_IPS+=("${ns_ip:-}")
  log "$ns got IP ${ns_ip:-unknown} via DHCP"

  discover_copilot_from_dhcp "$DHCP_OUT"

  # Fallback: if no server IP yet, try default gateway inside ns
  if [[ -z "$DEST_IP" ]]; then
    gw="$(ip netns exec "$ns" ip route show default 2>/dev/null | awk '/^default via /{print $3; exit}')"
    if [[ "$gw" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
      DEST_IP="$gw"
    fi
  fi
done

if [[ -z "$DEST_IP" ]]; then
  log "ERROR: Could not determine COPILOT IP from L2 DHCP/gateway"
  exit 1
fi
log "COPILOT discovered at $DEST_IP (pure L2 path)"

# Persistent ISI: DRACHE + NIX ----------
start_isi_loop() {
  local ns="$1" file="$2" name="$3" idx="$4"
  log "Starting persistent ISI client $name in $ns (veth${idx}_ns, $file)"
  ip netns exec "$ns" bash -lc '
    while true; do
      nc "'"$DEST_IP"'" 51001 < "'"$file"'" || sleep 1
    done
  ' &
}

# ns1 -> DRACHE, ns2 -> NIX
start_isi_loop "${NS[0]}" "${ISI_FILES[0]}" "${NAMES[0]}" 1
start_isi_loop "${NS[1]}" "${ISI_FILES[1]}" "${NAMES[1]}" 2

# ZEITNEHMER combined loop (ISI + time sync) ----------
zeit_ns="${NS[2]}"
zeit_file="${ISI_FILES[2]}"

log "ZEITNEHMER loop starting in ${zeit_ns} (ISI + time sync; interval=${TIME_SYNC_INTERVAL}s)"

LAST_TIME_SYNC=0

while true; do
  NOW_EPOCH="$(date +%s)"
  if (( NOW_EPOCH - LAST_TIME_SYNC >= TIME_SYNC_INTERVAL )); then
    LAST_TIME_SYNC=$NOW_EPOCH

    log "ZEITNEHMER: requesting time from COPILOT at ${DEST_IP}..."
    log "ZEITNEHMER: using request file $zeit_file"
    log "ZEITNEHMER: request payload: $(tr '\n' ' ' < "$zeit_file")"

    TIME_RESPONSE="$(ip netns exec "$zeit_ns" nc "$DEST_IP" 51001 -w 5 < "$zeit_file" || true)"

    log "ZEITNEHMER: raw response snippet: $(echo "$TIME_RESPONSE" | tr '\n' ' ' | head -c 400)"

    # Extract the first occurrence of DD.MM.YYYY-HH:MM:SS
    DT="$(echo "$TIME_RESPONSE" \
      | grep -oE '[0-9]{2}\.[0-9]{2}\.[0-9]{4}-[0-9]{2}:[0-9]{2}:[0-9]{2}' \
      | head -n1 || true)"

    if [[ -n "$DT" ]]; then
      log "ZEITNEHMER: COPILOT DateTime=$DT → delegating to rtc-sync.sh (DRIFT_THRESHOLD=${DRIFT_THRESHOLD}s)"
      
      if DRIFT_THRESHOLD="$DRIFT_THRESHOLD" /usr/local/bin/rtc-sync.sh --datetime "$DT"; then
        log "ZEITNEHMER: rtc-sync.sh completed successfully"
      else
        rc=$?
        log "ZEITNEHMER: rtc-sync.sh returned non-zero exit code $rc (see rtc-sync logs)"
      fi
   else
     log "ZEITNEHMER: no DateTime pattern (DD.MM.YYYY-HH:MM:SS) in response; skipping"
   fi
 else
   # Non-sync phase: still send request but ignore reply
   ip netns exec "$zeit_ns" nc "$DEST_IP" 51001 < "$zeit_file" >/dev/null 2>&1 \
    || log "ZEITNEHMER: nc send failed (non-sync phase)"
fi

  sleep 1
done
EOF

chmod 755 /usr/local/bin/isirunall.sh
chown root:root /usr/local/bin/isirunall.sh || true

# Write ISI payload files ----------
log "Writing isi1.txt …"
cat >/usr/local/bin/isi1.txt <<'EOF'
<IsiPut><AppName>DRACHE</AppName></IsiPut>
<IsiGet><Items>CurrentSoftwareVersion</Items><Cyclic>1</Cyclic></IsiGet>
EOF

log "Writing isi2.txt …"
cat >/usr/local/bin/isi2.txt <<'EOF'
<IsiPut><AppName>NIX</AppName></IsiPut>
<IsiGet><Items>DeviceState</Items><Cyclic>1</Cyclic></IsiGet>
EOF

log "Writing isi3.txt …"
cat >/usr/local/bin/isi3.txt <<'EOF'
<IsiPut><AppName>ZEITNEHMER</AppName></IsiPut>
<IsiGet><Items>DateTime</Items><Cyclic>1</Cyclic></IsiGet>
EOF

# Service ----------
log "Installing isirunall.service …"
cat >/etc/systemd/system/isirunall.service <<'EOF'
[Unit]
Description=ISI simulator (ISI simulator 3 clients over br0)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
ExecStart=/usr/local/bin/isirunall.sh
Restart=on-failure
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable isirunall.service
systemctl restart isirunall.service

log "ISI simulator module installed. Check 'journalctl -u isirunall.service' for logs."
