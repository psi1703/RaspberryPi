#!/usr/bin/env bash
# InitBox Pi Zero W / Zero 2W ISI module
#
# Actions:
#   install    Install and enable ISI simulator service, but do not start it.
#   uninstall  Remove ISI service and files created by this module.
#   remove     Alias for uninstall.
#   purge      Compatibility alias for uninstall. It does not purge packages.
#
# Offline field-mode policy:
#   - Debian packages are installed from the InitBox local package cache.
#   - Uninstall removes services/config/runtime files only.
#   - Purge is disabled and behaves like uninstall.
#   - Installed packages and cached .deb files are kept.
#
# COPILOT network safety policy:
#   - Installing this module must not bridge Ethernet immediately.
#   - isirunall.service is enabled but stopped after install.
#   - At runtime, the runner waits until a wired Ethernet interface has carrier
#     and a 10.x.x.x IPv4 address before creating br0.
#   - If the COPILOT 10.x network is not ready at boot, the runner retries
#     without changing Ethernet bridge state.
#   - After br0 is created, all bridge member interfaces are kept L2-only.
#
# Config policy:
#   - No NetworkManager drop-ins.
#   - No systemd drop-ins.
#   - No dnsmasq drop-ins.
#   - This module owns only:
#       /usr/local/bin/isirunall.sh
#       /etc/systemd/system/isirunall.service
#       /usr/local/bin/isi1.txt
#       /usr/local/bin/isi2.txt
#       /usr/local/bin/isi3.txt

set -euo pipefail

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

OLD_NM_ISI_CONF="/etc/NetworkManager/conf.d/99-initbox-isi-unmanaged.conf"
DHCPCD_CONF="/etc/dhcpcd.conf"
DHCPCD_BLOCK_START="# BEGIN InitBox ISI bridge unmanaged"
DHCPCD_BLOCK_END="# END InitBox ISI bridge unmanaged"

ts() {
  date '+%Y-%m-%d %H:%M:%S'
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

die() {
  err "$*"
  exit 1
}

require_root() {
  if [ "$(id -u)" -ne 0 ]; then
    die "this module must be run as root"
  fi
}

ensure_log_dir() {
  install -d -m 0755 "$(dirname "$LOGFILE")"
  touch "$LOGFILE"
  chown "$OWNER:$OWNER" "$LOGFILE" 2>/dev/null || true
}

load_package_helper() {
  if [ ! -f "$PACKAGES_LIB_FILE" ]; then
    die "package helper missing: $PACKAGES_LIB_FILE"
  fi

  # shellcheck disable=SC1090
  . "$PACKAGES_LIB_FILE"

  if ! declare -F initbox_packages_install >/dev/null 2>&1; then
    die "package helper does not define initbox_packages_install"
  fi
}

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

remove_old_dhcpcd_isi_block() {
  local tmp_file=""

  [ -f "$DHCPCD_CONF" ] || return 0

  if ! grep -qF "$DHCPCD_BLOCK_START" "$DHCPCD_CONF"; then
    return 0
  fi

  log "Removing old InitBox ISI dhcpcd block from ${DHCPCD_CONF}"

  tmp_file="$(mktemp)"
  awk -v start="$DHCPCD_BLOCK_START" -v end="$DHCPCD_BLOCK_END" '
    $0 == start { skip=1; next }
    $0 == end { skip=0; next }
    skip != 1 { print }
  ' "$DHCPCD_CONF" >"$tmp_file"

  cat "$tmp_file" >"$DHCPCD_CONF"
  rm -f "$tmp_file"
}

remove_old_isi_network_dropins() {
  log "Removing old ISI network drop-ins, if present"

  rm -f "$OLD_NM_ISI_CONF" 2>/dev/null || true
  remove_old_dhcpcd_isi_block

  systemctl reload NetworkManager.service 2>/dev/null || true
  systemctl restart NetworkManager.service 2>/dev/null || true
  systemctl restart dhcpcd.service 2>/dev/null || true
}

write_isi_runner() {
  log "Writing ${ISI_RUNNER}"

  cat >"$ISI_RUNNER" <<'RUNNER_EOF'
#!/usr/bin/env bash
set -euo pipefail

BRIDGE="${BRIDGE:-br0}"
DHCP_RUNTIME_DIR="${DHCP_RUNTIME_DIR:-/run/initbox-isi}"
DRIFT_THRESHOLD="${DRIFT_THRESHOLD:-5}"
TIME_SYNC_INTERVAL="${TIME_SYNC_INTERVAL:-60}"
TIME_SYNC_RETRY_INTERVAL="${TIME_SYNC_RETRY_INTERVAL:-30}"
MAX_COPILOT_TIME_JUMP="${MAX_COPILOT_TIME_JUMP:-172800}"
COPILOT_GATE_RETRY_SECONDS="${COPILOT_GATE_RETRY_SECONDS:-5}"
BRIDGE_IP_CLEAN_INTERVAL="${BRIDGE_IP_CLEAN_INTERVAL:-2}"
UPLINK_IF="${UPLINK_IF:-}"

ISI_FILES=(
  "/usr/local/bin/isi1.txt"
  "/usr/local/bin/isi2.txt"
  "/usr/local/bin/isi3.txt"
)

NAMES=(
  "DRACHE"
  "NIX"
  "ZEITNEHMER"
)

NS=(
  "ns1"
  "ns2"
  "ns3"
)

DEST_IP=""
NS_IPS=()
BRIDGE_CREATED_BY_ISI=0
BRIDGE_PORTS_ADDED_BY_ISI=()
IP_CLEANER_PID=""
NM_UNMANAGED_BY_ISI=()
L2_PREPARED_BY_ISI=()
DHCP_CLIENT_PIDS=()

log() {
  echo "[ISI $(date '+%F_%T')] $*"
}

is_positive_integer() {
  local value="$1"

  [[ "$value" =~ ^[0-9]+$ ]] && [ "$value" -gt 0 ]
}

array_contains() {
  local needle="$1"
  shift
  local item=""

  for item in "$@"; do
    [ "$item" = "$needle" ] && return 0
  done

  return 1
}

sanitize_runtime_settings() {
  if ! is_positive_integer "$COPILOT_GATE_RETRY_SECONDS"; then
    log "WARN: invalid COPILOT_GATE_RETRY_SECONDS=${COPILOT_GATE_RETRY_SECONDS}; using 5."
    COPILOT_GATE_RETRY_SECONDS="5"
  fi

  if ! is_positive_integer "$BRIDGE_IP_CLEAN_INTERVAL"; then
    log "WARN: invalid BRIDGE_IP_CLEAN_INTERVAL=${BRIDGE_IP_CLEAN_INTERVAL}; using 2."
    BRIDGE_IP_CLEAN_INTERVAL="2"
  fi
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

  is_excluded_interface "$iface" && return 1
  [ -r "/sys/class/net/${iface}/type" ] || return 1

  dev_type="$(cat "/sys/class/net/${iface}/type" 2>/dev/null || printf '')"
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

interface_has_carrier() {
  local iface="$1"

  [ -r "/sys/class/net/${iface}/carrier" ] || return 1
  [ "$(cat "/sys/class/net/${iface}/carrier" 2>/dev/null || printf '0')" = "1" ]
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
      log "Gate: ${iface} has no carrier; retrying later." >&2
      continue
    fi

    if interface_has_10_network "$iface"; then
      log "Gate: COPILOT candidate detected on ${iface}; IPv4 is in 10.x.x.x." >&2
      printf '%s\n' "$iface"
      return 0
    fi

    log "Gate: ${iface} has carrier but no 10.x.x.x IPv4 address yet; retrying later." >&2
  done < <(detect_wired_ethernet_ports)

  return 1
}

require_copilot_network_gate() {
  local gate_port=""

  while true; do
    if gate_port="$(detect_copilot_gate_port)"; then
      log "COPILOT network gate passed on ${gate_port}."

      if [ -n "$UPLINK_IF" ]; then
        log "Operator supplied UPLINK_IF=${UPLINK_IF}; only that interface will be bridged."
      else
        log "UPLINK_IF is not set; all detected wired Ethernet ports will be bridged."
        log "This supports Pi-in-the-middle mode, for example eth0 to COPILOT and eth1 to switch."
      fi

      return 0
    fi

    log "COPILOT network gate not passed yet."
    log "Waiting for wired Ethernet carrier and 10.x.x.x IPv4 before creating ${BRIDGE}."
    log "Ethernet is still untouched. Retrying in ${COPILOT_GATE_RETRY_SECONDS}s."
    sleep "$COPILOT_GATE_RETRY_SECONDS"
  done
}

is_pi_zero_like() {
  local model=""

  model="$(tr -d '\0' </proc/device-tree/model 2>/dev/null || printf '')"

  case "$model" in
    *"Zero"*)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

release_dhcp_on_interface() {
  local iface="$1"

  if command -v dhclient >/dev/null 2>&1; then
    dhclient -r "$iface" >/dev/null 2>&1 || true
  fi
}

stop_dhcpcd_on_interface() {
  local iface="$1"

  if command -v dhcpcd >/dev/null 2>&1; then
    dhcpcd -k "$iface" >/dev/null 2>&1 || true
  fi
}

interface_has_any_ip_address() {
  local iface="$1"

  ip -o addr show dev "$iface" 2>/dev/null | grep -q .
}

flush_interface_addresses() {
  local iface="$1"

  ip -4 addr flush dev "$iface" 2>/dev/null || true
  ip -6 addr flush dev "$iface" 2>/dev/null || true
  ip -4 route flush dev "$iface" 2>/dev/null || true
  ip -6 route flush dev "$iface" 2>/dev/null || true
}

set_interface_ipv6_disabled() {
  local iface="$1"

  if [ -w "/proc/sys/net/ipv6/conf/${iface}/accept_ra" ]; then
    printf '0\n' >"/proc/sys/net/ipv6/conf/${iface}/accept_ra" 2>/dev/null || true
  fi

  if [ -w "/proc/sys/net/ipv6/conf/${iface}/autoconf" ]; then
    printf '0\n' >"/proc/sys/net/ipv6/conf/${iface}/autoconf" 2>/dev/null || true
  fi

  if [ -w "/proc/sys/net/ipv6/conf/${iface}/disable_ipv6" ]; then
    printf '1\n' >"/proc/sys/net/ipv6/conf/${iface}/disable_ipv6" 2>/dev/null || true
  fi
}

set_interface_ipv6_enabled() {
  local iface="$1"

  if [ -w "/proc/sys/net/ipv6/conf/${iface}/disable_ipv6" ]; then
    printf '0\n' >"/proc/sys/net/ipv6/conf/${iface}/disable_ipv6" 2>/dev/null || true
  fi
}

mark_nm_unmanaged_runtime() {
  local iface="$1"

  if ! command -v nmcli >/dev/null 2>&1; then
    return 0
  fi

  if ! array_contains "$iface" "${NM_UNMANAGED_BY_ISI[@]+"${NM_UNMANAGED_BY_ISI[@]}"}"; then
    NM_UNMANAGED_BY_ISI+=("$iface")
  fi

  nmcli device set "$iface" managed no >/dev/null 2>&1 || true
  nmcli device disconnect "$iface" >/dev/null 2>&1 || true
}

restore_nm_managed_runtime() {
  local iface=""

  if ! command -v nmcli >/dev/null 2>&1; then
    return 0
  fi

  for iface in "${NM_UNMANAGED_BY_ISI[@]+"${NM_UNMANAGED_BY_ISI[@]}"}"; do
    [ -n "$iface" ] || continue
    nmcli device set "$iface" managed yes >/dev/null 2>&1 || true
  done

  NM_UNMANAGED_BY_ISI=()
}

prepare_l2_runtime_once() {
  local iface="$1"

  if array_contains "$iface" "${L2_PREPARED_BY_ISI[@]+"${L2_PREPARED_BY_ISI[@]}"}"; then
    return 0
  fi

  L2_PREPARED_BY_ISI+=("$iface")
  mark_nm_unmanaged_runtime "$iface"
  stop_dhcpcd_on_interface "$iface"
  release_dhcp_on_interface "$iface"
  set_interface_ipv6_disabled "$iface"
  flush_interface_addresses "$iface"
}

prepare_port_for_bridge() {
  local iface="$1"

  ip link set "$iface" up 2>/dev/null || true
  prepare_l2_runtime_once "$iface"
}

attach_port_to_bridge() {
  local iface="$1"
  local current_master=""

  if ! ip link show "$iface" >/dev/null 2>&1; then
    log "WARN: Interface ${iface} disappeared before bridge attach; skipping it."
    return 0
  fi

  current_master="$(basename "$(readlink "/sys/class/net/${iface}/master" 2>/dev/null || printf '')")"

  if [ -n "$current_master" ] && [ "$current_master" != "$BRIDGE" ]; then
    log "ERROR: ${iface} is already enslaved to ${current_master}, refusing to steal it."
    exit 1
  fi

  prepare_port_for_bridge "$iface"

  if [ "$current_master" != "$BRIDGE" ]; then
    log "Adding wired port ${iface} to ${BRIDGE}"
    ip link set "$iface" master "$BRIDGE"
    BRIDGE_PORTS_ADDED_BY_ISI+=("$iface")
  fi

  ip link set "$iface" up 2>/dev/null || true
  flush_interface_addresses "$iface"
}

bridge_member_interfaces() {
  ip -o link show master "$BRIDGE" 2>/dev/null \
    | awk -F': ' '{print $2}' \
    | cut -d'@' -f1 \
    | while IFS= read -r iface; do
        [ -n "$iface" ] || continue

        case "$iface" in
          lo|wlan*|wifi*|br*|docker*|virbr*|tap*|tun*|wg*|tailscale*|zt*|dummy*|ifb*|sit*|ip6tnl*|gre*|gretap*)
            continue
            ;;
          veth[0-9]*_host|eth*|en*|usb*)
            printf '%s\n' "$iface"
            ;;
          *)
            printf '%s\n' "$iface"
            ;;
        esac
      done
}

enforce_l2_only_on_interface() {
  local iface="$1"
  local still_has_address=0

  prepare_l2_runtime_once "$iface"

  if ! interface_has_any_ip_address "$iface"; then
    return 0
  fi

  flush_interface_addresses "$iface"

  if interface_has_any_ip_address "$iface"; then
    sleep 1
    flush_interface_addresses "$iface"
  fi

  if interface_has_any_ip_address "$iface"; then
    still_has_address=1
  fi

  if [ "$still_has_address" -eq 1 ]; then
    log "WARN: ${iface} still has an IP address after L2-only cleanup."
    ip -o addr show dev "$iface" 2>/dev/null || true
  else
    log "Removed IP address from ${BRIDGE} member ${iface}; kept it L2-only."
  fi
}

flush_bridge_member_ips_once() {
  local iface=""

  while IFS= read -r iface; do
    [ -n "$iface" ] || continue
    enforce_l2_only_on_interface "$iface"
  done < <(bridge_member_interfaces)
}

keep_bridge_members_ip_free() {
  log "Starting ${BRIDGE} member IP cleaner; interval=${BRIDGE_IP_CLEAN_INTERVAL}s."

  while true; do
    flush_bridge_member_ips_once
    sleep "$BRIDGE_IP_CLEAN_INTERVAL"
  done
}

start_bridge_ip_cleaner() {
  if [ -n "$IP_CLEANER_PID" ] && kill -0 "$IP_CLEANER_PID" 2>/dev/null; then
    return 0
  fi

  flush_bridge_member_ips_once
  keep_bridge_members_ip_free &
  IP_CLEANER_PID="$!"
}

stop_bridge_ip_cleaner() {
  if [ -n "$IP_CLEANER_PID" ]; then
    kill -TERM "$IP_CLEANER_PID" 2>/dev/null || true
    wait "$IP_CLEANER_PID" 2>/dev/null || true
    IP_CLEANER_PID=""
  fi
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

  set_interface_ipv6_disabled "$BRIDGE"
  ip link set "$BRIDGE" type bridge stp_state 0 forward_delay 0 2>/dev/null || true
  ip addr flush dev "$BRIDGE" 2>/dev/null || true
  ip link set "$BRIDGE" up

  for iface in "${bridge_ports[@]}"; do
    attach_port_to_bridge "$iface"
  done

  ip link set "$BRIDGE" up
  flush_bridge_member_ips_once
  start_bridge_ip_cleaner

  log "${BRIDGE} is ready with wired ports: ${bridge_ports[*]}"
  log "Current bridge membership:"
  bridge link 2>/dev/null || true
}

teardown_bridge_for_isi() {
  local iface=""

  stop_bridge_ip_cleaner

  for iface in "${BRIDGE_PORTS_ADDED_BY_ISI[@]+"${BRIDGE_PORTS_ADDED_BY_ISI[@]}"}"; do
    ip link set "$iface" nomaster 2>/dev/null || true
    set_interface_ipv6_enabled "$iface"
    ip link set "$iface" up 2>/dev/null || true
  done

  set_interface_ipv6_enabled "$BRIDGE"
  L2_PREPARED_BY_ISI=()
  restore_nm_managed_runtime

  if [ "$BRIDGE_CREATED_BY_ISI" -eq 1 ]; then
    log "Tearing down ${BRIDGE} created by ISI."
    ip link set "$BRIDGE" down 2>/dev/null || true
    ip link del "$BRIDGE" type bridge 2>/dev/null || true
  fi
}

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

  hash="$(printf '%s' "$seed" | sha1sum | awk '{print $1}')"

  printf '02:%s:%s:%s:%s:%s\n' \
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
  prepare_l2_runtime_once "$ifh"
  ip link set "$ifh" master "$BRIDGE"
  ip link set "$ifh" up
  flush_interface_addresses "$ifh"

  ip netns add "$ns"
  ip link set "$ifn" netns "$ns"
  ip netns exec "$ns" ip link set lo up
  ip netns exec "$ns" ip link set "$ifn" address "$(uniq_mac "$ifn")"
  ip netns exec "$ns" ip addr flush dev "$ifn" 2>/dev/null || true
  ip netns exec "$ns" ip link set "$ifn" up

  flush_bridge_member_ips_once
}

cleanup_dhcp_clients() {
  local pid=""

  for pid in "${DHCP_CLIENT_PIDS[@]+"${DHCP_CLIENT_PIDS[@]}"}"; do
    [ -n "$pid" ] || continue
    kill -TERM "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  done

  DHCP_CLIENT_PIDS=()

  pkill -f 'dhclient .*veth[0-9]+_ns' 2>/dev/null || true
}

write_minimal_dhclient_script() {
  local script_file="$1"

  cat >"$script_file" <<'EOF_DHCLIENT_SCRIPT'
#!/usr/bin/env bash
set -euo pipefail

mask_to_prefix() {
  local mask="${1:-255.255.255.0}"
  local old_ifs="$IFS"
  local octet=""
  local binary=""
  local prefix=0

  IFS='.'
  for octet in $mask; do
    case "$octet" in
      255) binary="${binary}11111111" ;;
      254) binary="${binary}11111110" ;;
      252) binary="${binary}11111100" ;;
      248) binary="${binary}11111000" ;;
      240) binary="${binary}11110000" ;;
      224) binary="${binary}11100000" ;;
      192) binary="${binary}11000000" ;;
      128) binary="${binary}10000000" ;;
      0) binary="${binary}00000000" ;;
      *) binary="${binary}11111111" ;;
    esac
  done
  IFS="$old_ifs"

  prefix="${binary%%0*}"
  printf '%s\n' "${#prefix}"
}

first_word() {
  local value="${1:-}"

  set -- $value
  printf '%s\n' "${1:-}"
}

case "${reason:-}" in
  BOUND|RENEW|REBIND|REBOOT)
    prefix="$(mask_to_prefix "${new_subnet_mask:-255.255.255.0}")"
    router="$(first_word "${new_routers:-}")"

    ip addr flush dev "$interface" 2>/dev/null || true
    ip addr add "${new_ip_address}/${prefix}" dev "$interface"
    ip link set "$interface" up

    if [ -n "$router" ]; then
      ip route replace default via "$router" dev "$interface" 2>/dev/null || true
    fi
    ;;
  EXPIRE|FAIL|RELEASE|STOP)
    ip addr flush dev "$interface" 2>/dev/null || true
    ;;
  *)
    ;;
esac

exit 0
EOF_DHCLIENT_SCRIPT

  chmod 0755 "$script_file"
  chown root:root "$script_file" 2>/dev/null || true
}

request_fresh_dhcp() {
  local ns="$1"
  local iface="$2"
  local lease_file="${DHCP_RUNTIME_DIR}/dhclient-${ns}.leases"
  local pid_file="${DHCP_RUNTIME_DIR}/dhclient-${ns}.pid"
  local conf_file="${DHCP_RUNTIME_DIR}/dhclient-${ns}.conf"
  local script_file="/usr/local/sbin/initbox-isi-dhclient-script.sh"
  local dhcp_out=""
  local dhcp_pid=""
  local status=0

  mkdir -p "$DHCP_RUNTIME_DIR"
  rm -f "$lease_file" "$pid_file" "$conf_file"
  : >"$lease_file"

  printf 'bootp-broadcast-always;\nrequest subnet-mask, routers, domain-name-servers, broadcast-address;\n' >"$conf_file"
  write_minimal_dhclient_script "$script_file"

  ip netns exec "$ns" ip addr flush dev "$iface" 2>/dev/null || true

  log "Requesting fresh DHCP for ${ns} on ${iface} (broadcast-mode, stable MAC, minimal script)"

  dhcp_out="$(
    set +e
    timeout 35s ip netns exec "$ns" dhclient \
      -4 \
      -1 \
      -d \
      -v \
      -sf "$script_file" \
      -cf "$conf_file" \
      -lf "$lease_file" \
      -pf "$pid_file" \
      "$iface" 2>&1
    status="$?"

    if [ -f "$pid_file" ]; then
      dhcp_pid="$(cat "$pid_file" 2>/dev/null || true)"
      if [ -n "$dhcp_pid" ]; then
        kill -TERM "$dhcp_pid" 2>/dev/null || true
        wait "$dhcp_pid" 2>/dev/null || true
      fi
      rm -f "$pid_file"
    fi

    exit "$status"
  )" || status="$?"

  if [ -f "$pid_file" ]; then
    dhcp_pid="$(cat "$pid_file" 2>/dev/null || true)"
    if [ -n "$dhcp_pid" ]; then
      kill -TERM "$dhcp_pid" 2>/dev/null || true
      wait "$dhcp_pid" 2>/dev/null || true
    fi
    rm -f "$pid_file"
  fi

  rm -f "$lease_file" "$conf_file"

  if [ "$status" -eq 124 ]; then
    printf '%s\n' "$dhcp_out"
    printf '%s\n' "DHCP timeout after 35 seconds"
    return 0
  fi

  printf '%s\n' "$dhcp_out"
}

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

full_cleanup() {
  stop_bridge_ip_cleaner
  cleanup_dhcp_clients
  cleanup_ns
  cleanup_dhcp_runtime
  teardown_bridge_for_isi
}

trap full_cleanup EXIT

sanitize_runtime_settings
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

flush_bridge_member_ips_once

start_isi_loop "${NS[0]}" "${ISI_FILES[0]}" "${NAMES[0]}"
start_isi_loop "${NS[1]}" "${ISI_FILES[1]}" "${NAMES[1]}"
start_isi_loop "${NS[2]}" "${ISI_FILES[2]}" "${NAMES[2]}"

zeit_ns="${NS[2]}"

build_zeitnehmer_payload() {
  local item_name="$1"

  cat <<EOF_PAYLOAD
<IsiPut><AppName>ZEITNEHMER</AppName></IsiPut>
<IsiGet><Items>${item_name}</Items><Cyclic>0</Cyclic></IsiGet>
EOF_PAYLOAD
}

request_copilot_time_item() {
  local item_name="$1"
  local payload_file=""
  local response=""

  payload_file="$(mktemp)"
  build_zeitnehmer_payload "$item_name" >"$payload_file"

  response="$({
    timeout 10s ip netns exec "$zeit_ns" nc -w 5 "$DEST_IP" 51001 <"$payload_file"
  } 2>/dev/null || true)"

  rm -f "$payload_file"

  printf '%s\n' "$response"
}

parse_iso_time() {
  local response="$1"

  printf '%s\n' "$response" \
    | grep -oE '<Time_ISO8601>[^<]+</Time_ISO8601>|[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}([.,][0-9]+)?([Zz]|[+-][0-9]{2}:?[0-9]{2})?' \
    | sed -E 's#</?Time_ISO8601>##g' \
    | head -n 1 || true
}

parse_legacy_datetime() {
  local response="$1"

  printf '%s\n' "$response" \
    | grep -oE '<DateTime>[^<]+</DateTime>|[0-9]{2}\.[0-9]{2}\.[0-9]{4}-[0-9]{2}:[0-9]{2}:[0-9]{2}' \
    | sed -E 's#</?DateTime>##g' \
    | head -n 1 || true
}

epoch_from_iso() {
  local iso_dt="$1"

  date -d "$iso_dt" +%s 2>/dev/null || printf '0\n'
}

epoch_from_legacy_datetime() {
  local legacy_dt="$1"
  local dpart=""
  local tpart=""
  local dd=""
  local mm=""
  local yyyy=""

  dpart="${legacy_dt%%-*}"
  tpart="${legacy_dt#*-}"

  IFS='.' read -r dd mm yyyy <<EOF_DT
$dpart
EOF_DT

  date -d "${yyyy}-${mm}-${dd} ${tpart}" +%s 2>/dev/null || printf '0\n'
}

set_system_time_from_epoch() {
  local epoch="$1"

  if command -v timedatectl >/dev/null 2>&1; then
    timedatectl set-time "@${epoch}" >/dev/null 2>&1 || date -s "@${epoch}" >/dev/null 2>&1
  else
    date -s "@${epoch}" >/dev/null 2>&1
  fi
}

apply_copilot_epoch_if_needed() {
  local master_epoch="$1"
  local source_name="$2"
  local now_epoch=0
  local diff=0
  local adiff=0

  if [ "$master_epoch" -le 0 ]; then
    log "ZEITNEHMER: ${source_name} was present but could not be parsed; continuing without clock adjustment"
    return 1
  fi

  now_epoch="$(date +%s)"
  diff=$((master_epoch - now_epoch))
  adiff="${diff#-}"

  log "ZEITNEHMER: Pi=${now_epoch} COPILOT=${master_epoch} drift=${diff}s source=${source_name}"

  if [ "$adiff" -le "$DRIFT_THRESHOLD" ]; then
    log "ZEITNEHMER: drift ${adiff}s <= ${DRIFT_THRESHOLD}s; no adjust"
    return 0
  fi

  if [ "$adiff" -gt "$MAX_COPILOT_TIME_JUMP" ]; then
    log "ZEITNEHMER: drift ${adiff}s exceeds MAX_COPILOT_TIME_JUMP=${MAX_COPILOT_TIME_JUMP}; rejecting COPILOT time"
    return 1
  fi

  log "ZEITNEHMER: drift ${adiff}s > ${DRIFT_THRESHOLD}s; adjusting system clock from ${source_name}"

  if set_system_time_from_epoch "$master_epoch"; then
    log "ZEITNEHMER: system clock adjusted from ${source_name}"
    return 0
  fi

  log "ZEITNEHMER: clock set failed; continuing"
  return 1
}

sync_time_from_copilot() {
  local response=""
  local value=""
  local master_epoch=0

  response="$(request_copilot_time_item "Time_ISO8601")"
  value="$(parse_iso_time "$response")"

  if [ -n "$value" ]; then
    log "ZEITNEHMER: COPILOT Time_ISO8601=${value}"
    master_epoch="$(epoch_from_iso "$value")"
    apply_copilot_epoch_if_needed "$master_epoch" "Time_ISO8601"
    return $?
  fi

  log "ZEITNEHMER: no usable Time_ISO8601 returned; trying DateTime."

  response="$(request_copilot_time_item "DateTime")"
  value="$(parse_legacy_datetime "$response")"

  if [ -n "$value" ]; then
    log "ZEITNEHMER: COPILOT DateTime=${value}"
    master_epoch="$(epoch_from_legacy_datetime "$value")"
    apply_copilot_epoch_if_needed "$master_epoch" "DateTime"
    return $?
  fi

  log "ZEITNEHMER: no COPILOT Time_ISO8601 or DateTime found."
  return 1
}

log "ZEITNEHMER loop starting in ${zeit_ns}; sync interval=${TIME_SYNC_INTERVAL}s; retry interval=${TIME_SYNC_RETRY_INTERVAL}s."

NEXT_TIME_SYNC=0

while true; do
  NOW_EPOCH="$(date +%s)"

  if [ "$NOW_EPOCH" -ge "$NEXT_TIME_SYNC" ]; then
    if sync_time_from_copilot; then
      NEXT_TIME_SYNC=$((NOW_EPOCH + TIME_SYNC_INTERVAL))
    else
      NEXT_TIME_SYNC=$((NOW_EPOCH + TIME_SYNC_RETRY_INTERVAL))
    fi
  fi

  sleep 1
done
RUNNER_EOF

  chmod 0755 "$ISI_RUNNER"
  chown root:root "$ISI_RUNNER" 2>/dev/null || true
}

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
<IsiGet><Items>Time_ISO8601</Items><Cyclic>1</Cyclic></IsiGet>
EOF

  chown root:root "$ISI_PAYLOAD_1" "$ISI_PAYLOAD_2" "$ISI_PAYLOAD_3" 2>/dev/null || true
  chmod 0644 "$ISI_PAYLOAD_1" "$ISI_PAYLOAD_2" "$ISI_PAYLOAD_3"
}

write_isi_service() {
  log "Installing isirunall.service"

  cat >"$ISI_SERVICE_FILE" <<EOF
[Unit]
Description=ISI simulator (3 namespaces + persistent ISI clients over br0)
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

enable_but_do_not_start_isi_service() {
  systemctl daemon-reload
  systemctl enable isirunall.service
  systemctl stop isirunall.service 2>/dev/null || true
}

stop_and_disable_unit() {
  local unit_name="$1"

  log "Stopping and disabling ${unit_name}"
  systemctl disable --now "$unit_name" 2>/dev/null || true
  systemctl reset-failed "$unit_name" 2>/dev/null || true
}

cleanup_runtime_network_state() {
  local link_name=""
  local ns=""

  log "Cleaning runtime namespaces, veth links, and DHCP state"

  for ns in ns1 ns2 ns3; do
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

  rm -rf "$ISI_DHCP_RUNTIME_DIR" 2>/dev/null || true
}

remove_isi_files() {
  log "Removing ISI files"

  rm -f "$ISI_RUNNER" \
    "$ISI_PAYLOAD_1" \
    "$ISI_PAYLOAD_2" \
    "$ISI_PAYLOAD_3" \
    "$ISI_SERVICE_FILE"
}

print_install_summary() {
  cat <<SUMMARY

ISI simulator installed
-----------------------
Service : isirunall.service
Runner  : ${ISI_RUNNER}

Safety behaviour:
  - install does not start isirunall.service
  - install does not bridge, flush, or enslave Ethernet ports
  - runtime waits until a wired Ethernet port has carrier and 10.x.x.x IPv4
  - while COPILOT gate is not ready, Ethernet is left untouched and the service retries
  - when UPLINK_IF is unset, all detected wired Ethernet ports are bridged after the gate passes
  - when UPLINK_IF is set, only that interface is bridged
  - physical bridge ports and host-side veth ports are kept L2-only

Config policy:
  - no NetworkManager drop-ins
  - no systemd drop-ins
  - no dnsmasq drop-ins
  - stale old ISI NetworkManager/dhcpcd overrides are removed if found

Key behaviours:
  - STP disabled, forward_delay 0
  - bootp-broadcast-always in dhclient config
  - deterministic veth MACs
  - fresh DHCP per namespace
  - COPILOT IP discovered from DHCP server / routers option / default gateway
  - no hardcoded COPILOT IP
  - DRACHE, NIX, and ZEITNEHMER are started as persistent ISI clients
  - ZEITNEHMER time sync still requests Time_ISO8601 first, then DateTime fallback
  - Pi Zero system clock is corrected from COPILOT only when drift exceeds threshold
  - COPILOT gate retry interval defaults to 5 seconds
  - bridge member IP cleanup interval defaults to 2 seconds

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
  - stale old ISI NetworkManager/dhcpcd overrides, if present

Not removed:
  - dependency packages
  - cached .deb files under ${INITBOX_PACKAGE_CACHE_DIR}
SUMMARY
}

install_main() {
  require_root
  ensure_log_dir
  install_dependencies
  remove_old_isi_network_dropins
  write_isi_runner
  write_isi_payloads
  write_isi_service
  enable_but_do_not_start_isi_service
  print_install_summary
  ok "ISI simulator module installed. Service is enabled but not started."
}

uninstall_main() {
  require_root
  ensure_log_dir
  stop_and_disable_unit "isirunall.service"
  cleanup_runtime_network_state
  remove_old_isi_network_dropins
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
      die "unknown action '${ACTION}'. Use install or uninstall."
      ;;
  esac
}

main "$@"
