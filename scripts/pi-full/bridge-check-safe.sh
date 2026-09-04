#!/usr/bin/env bash
# InitBox Pi-full field bridge manager.
#
# Management model:
#   wlan0 hotspot = management plane
#   eth0/eth1     = field bridge/data plane when ISI or Sniffer is enabled
#
# Safety rule:
#   Do not attach a wired interface to br0 when that same interface currently
#   carries an active SSH session. A default route on eth0 is not enough to
#   block field bridging because field management is expected through wlan0.

set -euo pipefail

BR="${BRIDGE:-br0}"
ROLE_FILE="${ROLE_FILE:-/etc/pi_roles.conf}"
LOOP_SLEEP_ACTIVE="${LOOP_SLEEP_ACTIVE:-3}"
LOOP_SLEEP_STEADY="${LOOP_SLEEP_STEADY:-15}"
NM_UNMANAGED_FILE="${NM_UNMANAGED_FILE:-/etc/NetworkManager/conf.d/99-initbox-bridge-unmanaged.conf}"
BRIDGE_LAST_STATE_FILE="${BRIDGE_LAST_STATE_FILE:-/run/initbox-bridge-last-state}"
PROTECT_ACTIVE_SSH_IFACES="${PROTECT_ACTIVE_SSH_IFACES:-1}"
PROTECT_DEFAULT_ROUTE_IFACES="${PROTECT_DEFAULT_ROUTE_IFACES:-0}"
ALLOW_MANAGEMENT_BRIDGE="${ALLOW_MANAGEMENT_BRIDGE:-0}"
ROLE_INVALID_STATE_DIR="${ROLE_INVALID_STATE_DIR:-/run/initbox-bridge-invalid-roles}"
INVALID_ROLE_GRACE_SECONDS="${INVALID_ROLE_GRACE_SECONDS:-3}"

log() {
  echo "[BRIDGE $(date +%F_%T)] $*"
}

state_once() {
  local key="$1"
  local message="$2"
  local last=""

  mkdir -p "$(dirname "$BRIDGE_LAST_STATE_FILE")"
  last="$(cat "$BRIDGE_LAST_STATE_FILE" 2>/dev/null || true)"
  if [ "$last" != "$key" ]; then
    log "$message"
    printf '%s\n' "$key" >"$BRIDGE_LAST_STATE_FILE"
  fi
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

role_enabled() {
  local wanted="$1"
  local role=""

  for role in $(read_roles); do
    case "$wanted:$role" in
      isi:isi)
        return 0
        ;;
      sniff:sniff|sniff:wireshark|sniff:sniffer|sniff:sniffer-bridge|sniff:ethsniffer)
        return 0
        ;;
    esac
  done

  return 1
}

write_roles_text() {
  local new_roles="$1"
  local tmp=""

  install -d -m 0755 "$(dirname "$ROLE_FILE")"
  tmp="$(mktemp "$(dirname "$ROLE_FILE")/.roles.XXXXXX")"
  printf 'ROLES="%s"\n' "$new_roles" >"$tmp"
  install -m 0664 "$tmp" "$ROLE_FILE"
  rm -f "$tmp"
}

remove_role_group() {
  local group="$1"
  local reason="$2"
  local role=""
  local kept=""
  local removed=0

  for role in $(read_roles); do
    case "$group:$role" in
      isi:isi)
        removed=1
        continue
        ;;
      sniff:sniff|sniff:wireshark|sniff:sniffer|sniff:sniffer-bridge|sniff:ethsniffer)
        removed=1
        continue
        ;;
    esac

    kept="${kept:+$kept }$role"
  done

  if [ "$removed" -eq 1 ]; then
    write_roles_text "$kept"
    log "Auto-disabled ${group} role: ${reason}. New roles='${kept}'."
    case "$group" in
      isi)
        systemctl stop isirunall.service >/dev/null 2>&1 || true
        ;;
      sniff)
        systemctl stop wireshark-autostart.service >/dev/null 2>&1 || true
        ;;
    esac
  fi
}

invalid_role_elapsed() {
  local group="$1"
  local reason="$2"
  local now=""
  local first=""
  local marker=""

  mkdir -p "$ROLE_INVALID_STATE_DIR"
  marker="${ROLE_INVALID_STATE_DIR}/${group}.first"
  now="$(date +%s)"

  if [ ! -f "$marker" ]; then
    printf '%s\n' "$now" >"$marker"
    log "${group} role blocked; starting ${INVALID_ROLE_GRACE_SECONDS}s auto-clear timer: ${reason}."
    return 1
  fi

  first="$(cat "$marker" 2>/dev/null || echo "$now")"
  [ $((now - first)) -ge "$INVALID_ROLE_GRACE_SECONDS" ]
}

maybe_disable_invalid_role() {
  local group="$1"
  local reason="$2"

  if invalid_role_elapsed "$group" "$reason"; then
    remove_role_group "$group" "$reason"
    rm -f "${ROLE_INVALID_STATE_DIR}/${group}.first" 2>/dev/null || true
  fi
}

is_wired_iface() {
  printf '%s\n' "$1" | grep -Eq '^(eth[0-9]+|enx[0-9A-Fa-f]{12}|enp[0-9a-zA-Z]+|end[0-9]+)$'
}

carrier_is_up() {
  local iface="$1"
  local carrier="0"

  if [ -r "/sys/class/net/${iface}/carrier" ]; then
    IFS= read -r carrier <"/sys/class/net/${iface}/carrier" || carrier="0"
    [ "$carrier" = "1" ]
    return
  fi

  ip link show "$iface" 2>/dev/null | grep -q 'LOWER_UP'
}

all_wired_ifaces() {
  local path=""
  local iface=""

  for path in /sys/class/net/eth[0-9]* /sys/class/net/enx* /sys/class/net/enp* /sys/class/net/end[0-9]*; do
    [ -e "$path" ] || continue
    iface="${path##*/}"
    is_wired_iface "$iface" && printf '%s\n' "$iface"
  done | sort -u
}

default_route_ifaces() {
  ip route show default 2>/dev/null | awk '{for (i=1; i<=NF; i++) if ($i == "dev") print $(i+1)}' | sort -u
}

iface_for_ipv4() {
  local ipaddr="$1"

  ip -o -4 addr show 2>/dev/null | awk -v ip="$ipaddr" '$4 ~ "^" ip "/" {print $2}' | sort -u
}

active_ssh_ifaces() {
  local local_addr=""
  local local_ip=""

  command -v ss >/dev/null 2>&1 || return 0

  while IFS= read -r local_addr; do
    [ -n "$local_addr" ] || continue
    local_ip="${local_addr%:*}"
    local_ip="${local_ip#[}"
    local_ip="${local_ip%]}"
    case "$local_ip" in
      *.*)
        iface_for_ipv4 "$local_ip"
        ;;
    esac
  done < <(ss -Htn state established '( sport = :22 )' 2>/dev/null | awk '{print $4}') | sort -u
}

protected_bridge_ifaces() {
  if [ "$ALLOW_MANAGEMENT_BRIDGE" = "1" ]; then
    return 0
  fi

  if [ "$PROTECT_ACTIVE_SSH_IFACES" = "1" ]; then
    active_ssh_ifaces
  fi

  if [ "$PROTECT_DEFAULT_ROUTE_IFACES" = "1" ]; then
    default_route_ifaces
  fi
}

is_protected_bridge_iface() {
  local iface="$1"
  local protected=""

  while IFS= read -r protected; do
    [ -n "$protected" ] || continue
    [ "$protected" = "$iface" ] && return 0
  done < <(protected_bridge_ifaces | sort -u)

  return 1
}

bridge_safe_wired_ifaces() {
  local iface=""

  while IFS= read -r iface; do
    [ -n "$iface" ] || continue
    carrier_is_up "$iface" || continue

    if is_protected_bridge_iface "$iface"; then
      state_once "protect:${iface}" "Preserving ${iface}; active SSH/default-route protection keeps it out of ${BR}."
      continue
    fi

    printf '%s\n' "$iface"
  done < <(all_wired_ifaces)
}

veth_host_ports() {
  local path=""

  for path in /sys/class/net/veth*_host; do
    [ -e "$path" ] || continue
    printf '%s\n' "${path##*/}"
  done
}

list_bridge_ports() {
  ip -o link show master "$BR" 2>/dev/null | awk -F': ' '{print $2}' | cut -d'@' -f1
}

iface_has_ipv4() {
  ip -4 addr show dev "$1" 2>/dev/null | grep -q 'inet '
}

write_nm_policy_active() {
  local iface=""
  local policy=""

  if ! command -v nmcli >/dev/null 2>&1 && ! systemctl cat NetworkManager.service >/dev/null 2>&1; then
    return 0
  fi

  mkdir -p "$(dirname "$NM_UNMANAGED_FILE")"
  policy="interface-name:${BR};interface-name:veth*;interface-name:veth*_host"

  for iface in "$@"; do
    [ -n "$iface" ] || continue
    policy="${policy};interface-name:${iface}"
  done

  cat >"$NM_UNMANAGED_FILE" <<EOF_NM
[keyfile]
unmanaged-devices=${policy}
EOF_NM

  nmcli general reload >/dev/null 2>&1 || true
  nmcli device set "$BR" managed no >/dev/null 2>&1 || true

  for iface in "$@"; do
    nmcli device set "$iface" managed no >/dev/null 2>&1 || true
  done
}

write_nm_policy_lab() {
  if ! command -v nmcli >/dev/null 2>&1 && ! systemctl cat NetworkManager.service >/dev/null 2>&1; then
    return 0
  fi

  mkdir -p "$(dirname "$NM_UNMANAGED_FILE")"
  cat >"$NM_UNMANAGED_FILE" <<EOF_NM
[keyfile]
unmanaged-devices=interface-name:${BR};interface-name:veth*;interface-name:veth*_host
EOF_NM

  nmcli general reload >/dev/null 2>&1 || true
}

restore_non_bridge_wired_ifaces() {
  local iface=""

  if ! command -v nmcli >/dev/null 2>&1; then
    return 0
  fi

  while IFS= read -r iface; do
    [ -n "$iface" ] || continue
    if ip link show master "$BR" 2>/dev/null | awk -F': ' '{print $2}' | cut -d'@' -f1 | grep -qx "$iface"; then
      continue
    fi
    ip link set "$iface" nomaster 2>/dev/null || true
    ip link set "$iface" up 2>/dev/null || true
    nmcli device set "$iface" managed yes >/dev/null 2>&1 || true
    if ! iface_has_ipv4 "$iface"; then
      nmcli device reapply "$iface" >/dev/null 2>&1 || nmcli device connect "$iface" >/dev/null 2>&1 || true
    fi
  done < <({ all_wired_ifaces; active_ssh_ifaces; } | sort -u)
}

cleanup_veth_and_namespaces() {
  local port=""
  local ns=""

  while IFS= read -r port; do
    [ -n "$port" ] || continue
    ip link delete "$port" 2>/dev/null || true
  done < <(veth_host_ports)

  for ns in ns1 ns2 ns3; do
    ip netns delete "$ns" 2>/dev/null || true
  done
}

teardown_bridge() {
  local port=""

  if ip link show "$BR" >/dev/null 2>&1; then
    while IFS= read -r port; do
      [ -n "$port" ] || continue
      ip link set "$port" nomaster 2>/dev/null || true
      ip link set "$port" up 2>/dev/null || true
    done < <(list_bridge_ports)

    ip addr flush dev "$BR" 2>/dev/null || true
    ip link set "$BR" down 2>/dev/null || true
    ip link delete "$BR" type bridge 2>/dev/null || true
    log "Removed ${BR}."
  fi

  cleanup_veth_and_namespaces
  write_nm_policy_lab
  restore_non_bridge_wired_ifaces
  rm -f "$BRIDGE_LAST_STATE_FILE" 2>/dev/null || true
}

ensure_bridge_for_ports() {
  local port=""
  local attached=0

  [ "$#" -gt 0 ] || return 1

  write_nm_policy_active "$@"

  if ! ip link show "$BR" >/dev/null 2>&1; then
    ip link add name "$BR" type bridge
    log "Created ${BR}."
  fi

  ip addr flush dev "$BR" 2>/dev/null || true
  ip link set "$BR" up 2>/dev/null || true

  while IFS= read -r port; do
    [ -n "$port" ] || continue
    if ! printf '%s\n' "$@" | grep -qx "$port" && is_wired_iface "$port"; then
      ip link set "$port" nomaster 2>/dev/null || true
      ip link set "$port" up 2>/dev/null || true
    fi
  done < <(list_bridge_ports)

  for port in "$@"; do
    if is_protected_bridge_iface "$port"; then
      log "Refusing to attach protected active-SSH interface ${port} to ${BR}."
      continue
    fi

    ip addr flush dev "$port" 2>/dev/null || true
    ip link set "$port" up 2>/dev/null || true
    ip link set "$port" master "$BR" 2>/dev/null || true
    ip addr flush dev "$port" 2>/dev/null || true
    attached=$((attached + 1))
  done

  while IFS= read -r port; do
    [ -n "$port" ] || continue
    ip addr flush dev "$port" 2>/dev/null || true
    ip link set "$port" up 2>/dev/null || true
    ip link set "$port" master "$BR" 2>/dev/null || true
    ip addr flush dev "$port" 2>/dev/null || true
  done < <(veth_host_ports)

  if [ "$attached" -eq 0 ]; then
    return 1
  fi

  state_once "active:$*" "${BR} active with field bridge ports: $*"
}

run_once() {
  local isi_wanted=0
  local sniff_wanted=0
  local safe_ports=()

  role_enabled isi && isi_wanted=1
  role_enabled sniff && sniff_wanted=1

  mapfile -t safe_ports < <(bridge_safe_wired_ifaces)

  if [ "$isi_wanted" -eq 0 ] && [ "$sniff_wanted" -eq 0 ]; then
    teardown_bridge
    state_once "idle" "No ISI/sniff role active; ${BR} is idle. Hotspot management is preserved."
    return 0
  fi

  if [ "$sniff_wanted" -eq 1 ] && [ "${#safe_ports[@]}" -lt 2 ]; then
    maybe_disable_invalid_role sniff "need two wired field interfaces not carrying active SSH; found ${#safe_ports[@]}"
    sniff_wanted=0
  fi

  if [ "$isi_wanted" -eq 1 ] && [ "${#safe_ports[@]}" -lt 1 ]; then
    maybe_disable_invalid_role isi "need one wired field interface not carrying active SSH; found ${#safe_ports[@]}"
    isi_wanted=0
  fi

  if [ "$isi_wanted" -eq 0 ] && [ "$sniff_wanted" -eq 0 ]; then
    teardown_bridge
    return 0
  fi

  ensure_bridge_for_ports "${safe_ports[@]}"
}

case "${1:-run}" in
  cleanup)
    teardown_bridge
    log "cleanup action completed"
    exit 0
    ;;
  run|"")
    ;;
  *)
    log "unknown action: ${1:-}"
    exit 2
    ;;
esac

trap 'teardown_bridge; exit 0' TERM INT HUP

while true; do
  run_once
  if role_enabled isi || role_enabled sniff; then
    sleep "$LOOP_SLEEP_ACTIVE"
  else
    sleep "$LOOP_SLEEP_STEADY"
  fi
done
