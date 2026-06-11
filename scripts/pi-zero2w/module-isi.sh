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

write_isi_runner() {
  log "Writing ${ISI_RUNNER}"

  cat >"$ISI_RUNNER" <<'EOF'
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
TIME_SYNC_INTERVAL="${TIME_SYNC_INTERVAL:-60}" # seconds between time syncs

DEST_IP=""                 # COPILOT IP discovered via DHCP
NS_IPS=()                  # Collected namespace IPs
UPLINK_IF="${UPLINK_IF:-}" # wired uplink; auto-detected on Zero/Zero 2W
BRIDGE_CREATED_BY_ISI=0

log() {
  echo "[ISI $(date +%F_%T)] $*"
}

is_pi_zero_like() {
  local m
  m="$(tr -d '\0' </proc/device-tree/model 2>/dev/null || echo '')"
  case "$m" in
    *"Zero"*) return 0 ;;
    *) return 1 ;;
  esac
}

cleanup_ns() {
  local ns

  for ns in "${NS[@]}"; do
    ip netns del "$ns" 2>/dev/null || true
  done

  ip -o link show |
    awk -F': ' '{print $2}' |
    cut -d'@' -f1 |
    grep -E '^veth[0-9]+_(host|ns)$' 2>/dev/null |
    xargs -r -I{} ip link del "{}" 2>/dev/null || true
}

uniq_mac() {
  local seed="$1"
  local h=""

  h="$(printf "%s" "$seed" | sha1sum | awk '{print $1}')"
  printf "02:%s:%s:%s:%s:%s\n" "${h:0:2}" "${h:2:2}" "${h:4:2}" "${h:6:2}" "${h:8:2}"
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
  ip link set "$ifh" master "$BRIDGE" || true
  ip link set "$ifh" up

  ip netns add "$ns"
  ip link set "$ifn" netns "$ns"
  ip netns exec "$ns" ip link set lo up
  ip netns exec "$ns" ip link set "$ifn" address "$(uniq_mac "$ifn")"
  ip netns exec "$ns" ip link set "$ifn" up
}

setup_bridge_for_isi() {
  local wired_ifs=()

  if ip link show "$BRIDGE" >/dev/null 2>&1; then
    log "$BRIDGE already exists; using existing L2 bridge."
    return 0
  fi

  if ! is_pi_zero_like; then
    log "ERROR: $BRIDGE not present and auto-create is only supported on Pi Zero/Zero 2W; aborting."
    exit 1
  fi

  if [ -z "$UPLINK_IF" ]; then
    mapfile -t wired_ifs < <(
      find /sys/class/net -maxdepth 1 -mindepth 1 -type l -printf '%f\n' |
        grep -E '^(eth[0-9]+|enx[0-9A-Fa-f]{12})$' |
        sort || true
    )

    if [ "${#wired_ifs[@]}" -eq 0 ]; then
      log "ERROR: No wired uplink interface found for $BRIDGE."
      exit 1
    fi

    UPLINK_IF="${wired_ifs[0]}"
  fi

  log "Creating $BRIDGE for ISI on Pi Zero, uplink=$UPLINK_IF"

  ip link add name "$BRIDGE" type bridge
  ip link set "$UPLINK_IF" up || true
  ip addr flush dev "$UPLINK_IF" || true
  ip addr flush dev "$BRIDGE" || true
  ip link set "$UPLINK_IF" master "$BRIDGE" || true
  ip link set "$BRIDGE" up || true

  BRIDGE_CREATED_BY_ISI=1
  log "$BRIDGE up with $UPLINK_IF as port."
}

teardown_bridge_for_isi() {
  if [ "$BRIDGE_CREATED_BY_ISI" -ne 1 ]; then
    return 0
  fi

  if [ -z "$UPLINK_IF" ]; then
    return 0
  fi

  log "Tearing down $BRIDGE created by ISI and releasing $UPLINK_IF"

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

setup_bridge_for_isi

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

log "$BRIDGE is UP"

if ! command -v dhclient >/dev/null 2>&1; then
  log "ERROR: dhclient missing"
  exit 1
fi

if ! command -v nc >/dev/null 2>&1 && ! command -v netcat >/dev/null 2>&1; then
  log "ERROR: nc/netcat missing"
  exit 1
fi

cleanup_ns

discover_copilot_from_dhcp() {
  local dhcp_out="$1"
  local srv=""

  if [ -z "$DEST_IP" ]; then
    srv="$(printf '%s\n' "$dhcp_out" | sed -nE 's/.*DHCPACK of [^ ]+ from ([0-9.]+).*/\1/p' | tail -1)"

    if [[ "$srv" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
      DEST_IP="$srv"
    fi
  fi
}

for i in "${!NS[@]}"; do
  ns="${NS[$i]}"
  idx=$((i + 1))

  add_veth_to_br "$idx" "$ns"

  DHCP_OUT="$(ip netns exec "$ns" dhclient -4 -1 -v "veth${idx}_ns" 2>&1 || true)"

  if ! printf '%s' "$DHCP_OUT" | grep -q 'DHCPACK'; then
    log "ERROR: DHCP failed in $ns"
    exit 1
  fi

  ip netns pids "$ns" 2>/dev/null | while read -r pid; do
    if ps -p "$pid" -o comm= 2>/dev/null | grep -qx 'dhclient'; then
      kill -TERM "$pid" 2>/dev/null || true
    fi
  done

  ns_ip="$(ip netns exec "$ns" ip -o -4 addr show "veth${idx}_ns" | awk '{print $4}' | cut -d/ -f1 || true)"
  NS_IPS+=("${ns_ip:-}")
  log "$ns got IP ${ns_ip:-unknown} via DHCP"

  discover_copilot_from_dhcp "$DHCP_OUT"

  if [ -z "$DEST_IP" ]; then
    gw="$(ip netns exec "$ns" ip route show default 2>/dev/null | awk '/^default via /{print $3; exit}')"
    if [[ "$gw" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
      DEST_IP="$gw"
    fi
  fi
done

if [ -z "$DEST_IP" ]; then
  log "ERROR: Could not determine COPILOT IP from L2 DHCP/gateway"
  exit 1
fi

log "COPILOT discovered at $DEST_IP"

start_isi_loop() {
  local ns="$1"
  local file="$2"
  local name="$3"

  log "Starting persistent ISI client $name in $ns"

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

    DT="$(
      echo "$TIME_RESPONSE" |
        grep -oE '[0-9]{2}\.[0-9]{2}\.[0-9]{4}-[0-9]{2}:[0-9]{2}:[0-9]{2}' |
        head -n1 || true
    )"

    if [ -n "$DT" ]; then
      log "ZEITNEHMER: COPILOT DateTime=$DT"
      dpart="${DT%%-*}"
      tpart="${DT#*-}"
      IFS='.' read -r DD MM YYYY <<< "$dpart"

      MASTER_EPOCH="$(date -d "${YYYY}-${MM}-${DD} ${tpart}" +%s 2>/dev/null || echo 0)"

      if [ "$MASTER_EPOCH" -gt 0 ]; then
        NOW_EPOCH="$(date +%s)"
        DIFF=$((MASTER_EPOCH - NOW_EPOCH))
        ADIFF="${DIFF#-}"

        log "ZEITNEHMER: drift=${DIFF}s"

        if [ "$ADIFF" -gt "$DRIFT_THRESHOLD" ]; then
          log "ZEITNEHMER: updating system clock"
          if ! date -s "@${MASTER_EPOCH}" >/dev/null 2>&1; then
            log "ZEITNEHMER: failed to set system time"
          fi
        else
          log "ZEITNEHMER: drift within threshold"
        fi
      else
        log "ZEITNEHMER: cannot parse DateTime '$DT'"
      fi
    else
      log "ZEITNEHMER: no DateTime pattern in response"
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
<IsiGet><Items>DateTime</Items><Cyclic>5</Cyclic></IsiGet>
EOF

  chown root:root "$ISI_PAYLOAD_1" "$ISI_PAYLOAD_2" "$ISI_PAYLOAD_3" 2>/dev/null || true
  chmod 644 "$ISI_PAYLOAD_1" "$ISI_PAYLOAD_2" "$ISI_PAYLOAD_3"
}

write_isi_service() {
  log "Installing isirunall.service"

  cat >"$ISI_SERVICE_FILE" <<EOF
[Unit]
Description=ISI simulator (3ns + ISI clients over br0)
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
  log "cleaning ISI runtime namespaces and veth links"

  ip netns del ns1 2>/dev/null || true
  ip netns del ns2 2>/dev/null || true
  ip netns del ns3 2>/dev/null || true

  ip -o link show |
    awk -F': ' '{print $2}' |
    cut -d'@' -f1 |
    grep -E '^veth[0-9]+_(host|ns)$' 2>/dev/null |
    xargs -r -I{} ip link del "{}" 2>/dev/null || true
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
  echo "Check:"
  echo "  sudo systemctl status isirunall.service --no-pager"
  echo "  sudo journalctl -u isirunall.service -n 100 --no-pager"
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
  echo
  echo "Not removed:"
  echo "  - installed dependency packages"
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
