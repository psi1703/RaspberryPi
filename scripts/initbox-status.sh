#!/usr/bin/env bash

# InitBox Raspberry Pi 3 / 4 / 5 field diagnostics command
#
# This script prints local diagnostic information.
# It does not install packages, change services, or require Internet access.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
STATE_HELPER="$REPO_ROOT/scripts/lib/state.sh"

ROLE_FILE="${ROLE_FILE:-/etc/pi_roles.conf}"
BOXNO_FILE="${BOXNO_FILE:-/etc/pi-boxno}"
MODS_FILE="${MODS_FILE:-/etc/initbox-mods.conf}"
TRACE_DIR="${TRACE_DIR:-/usr/tracefiles}"
LOG_FILE="${LOG_FILE:-/var/log/initbox/install.log}"
LEGACY_LOG_FILE="${LEGACY_LOG_FILE:-/home/initbox/pi_logs/initbox-install.log}"

if [ -f "$STATE_HELPER" ]; then
  # shellcheck disable=SC1090
  . "$STATE_HELPER"
fi

print_section() {
  local title="$1"

  echo
  echo "$title"
  echo "========================================"
}

print_subsection() {
  local title="$1"

  echo
  echo "$title"
  echo "----------------------------------------"
}

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

print_command_output() {
  local description="$1"
  shift

  print_subsection "$description"

  if "$@"; then
    true
  else
    echo "Command failed: $*"
  fi
}

service_exists() {
  local service_name="$1"

  systemctl list-unit-files "$service_name" >/dev/null 2>&1
}

print_service_status() {
  local service_name="$1"

  print_subsection "Service: $service_name"

  if ! command_exists systemctl; then
    echo "systemctl not available."
    return 0
  fi

  if service_exists "$service_name"; then
    systemctl status "$service_name" --no-pager || true
  else
    echo "Service not found."
  fi
}

print_recent_service_log() {
  local service_name="$1"

  print_subsection "Recent log: $service_name"

  if ! command_exists journalctl; then
    echo "journalctl not available."
    return 0
  fi

  journalctl -u "$service_name" -n 40 --no-pager || true
}

print_known_services() {
  local service_name
  local services

  services="
dhcpcd
hostapd
dnsmasq
ttyd
nodered
pi-nodered
portal
pi-servsync
isirunall
fms
bridge-check
wireshark-autostart
rtc-sync
rtc-sync.timer
"

  print_section "Known Service Status"

  while IFS= read -r service_name; do
    [ -z "$service_name" ] && continue
    print_service_status "$service_name"
  done <<EOF
$services
EOF
}

print_known_logs() {
  local service_name
  local services

  services="
dhcpcd
hostapd
dnsmasq
ttyd
nodered
pi-nodered
portal
pi-servsync
isirunall
fms
bridge-check
wireshark-autostart
rtc-sync
"

  print_section "Recent Known Service Logs"

  while IFS= read -r service_name; do
    [ -z "$service_name" ] && continue

    if command_exists systemctl && service_exists "$service_name"; then
      print_recent_service_log "$service_name"
    fi
  done <<EOF
$services
EOF
}

print_initbox_state() {
  print_section "Install State"

  if declare -F initbox_state_print >/dev/null 2>&1; then
    initbox_state_print || true
  else
    echo "State helper not found."
    echo "Expected: $STATE_HELPER"
  fi
}

print_file_if_exists() {
  local label="$1"
  local path="$2"

  print_subsection "$label"

  if [ -f "$path" ]; then
    echo "Path: $path"
    echo
    sed -n '1,120p' "$path" || true
  else
    echo "Missing: $path"
  fi
}

print_system_info() {
  print_section "System Information"

  print_command_output "Hostname" hostname

  if command_exists uname; then
    print_command_output "Kernel" uname -a
  fi

  if [ -f /proc/device-tree/model ]; then
    print_subsection "Raspberry Pi model"
    tr -d '\0' </proc/device-tree/model || true
    echo
  fi

  if [ -f /etc/os-release ]; then
    print_subsection "OS release"
    cat /etc/os-release
  fi

  if command_exists uptime; then
    print_command_output "Uptime" uptime
  fi

  if command_exists date; then
    print_command_output "System date" date
  fi
}

print_config_files() {
  print_section "InitBox Configuration Files"

  print_file_if_exists "Role file" "$ROLE_FILE"
  print_file_if_exists "Box number" "$BOXNO_FILE"
  print_file_if_exists "Module flags" "$MODS_FILE"
  print_file_if_exists "hostapd config" "/etc/hostapd/hostapd.conf"
  print_file_if_exists "dnsmasq InitBox drop-in" "/etc/dnsmasq.d/initbox-hotspot.conf"
}

print_network_info() {
  print_section "Network Information"

  if command_exists ip; then
    print_command_output "IP addresses" ip addr
    print_command_output "Routes" ip route
    print_command_output "Links" ip link show

    print_subsection "Common interface checks"
    ip addr show wlan0 2>/dev/null || echo "wlan0 not found."
    echo
    ip addr show br0 2>/dev/null || echo "br0 not found."
    echo
    ip link show can0 2>/dev/null || echo "can0 not found."
    echo

    print_subsection "Wired interface carrier state"
    for iface_path in /sys/class/net/eth* /sys/class/net/enx* /sys/class/net/enp* /sys/class/net/end*; do
      [ -e "$iface_path" ] || continue
      iface="${iface_path##*/}"
      carrier="unknown"
      operstate="unknown"

      if [ -r "$iface_path/carrier" ]; then
        carrier="$(cat "$iface_path/carrier" 2>/dev/null || echo unknown)"
      fi

      if [ -r "$iface_path/operstate" ]; then
        operstate="$(cat "$iface_path/operstate" 2>/dev/null || echo unknown)"
      fi

      printf '%-16s carrier=%s operstate=%s\n' "$iface" "$carrier" "$operstate"
    done
  else
    echo "ip command not available."
  fi
}

print_bridge_info() {
  print_section "Bridge Information"

  if ! command_exists bridge; then
    echo "bridge command not available."
    return 0
  fi

  print_command_output "Bridge links" bridge link
  print_command_output "Bridge vlan show" bridge vlan show
}

print_can_info() {
  print_section "CAN / FMS Information"

  if command_exists ip; then
    print_command_output "can0 details" ip -details link show can0
  fi

  if command_exists cansend; then
    echo
    echo "cansend: $(command -v cansend)"
  else
    echo
    echo "cansend not found."
  fi

  if [ -f /usr/local/bin/CAN.trc ]; then
    print_subsection "CAN trace file"
    ls -lh /usr/local/bin/CAN.trc || true
    head -n 10 /usr/local/bin/CAN.trc || true
  else
    print_subsection "CAN trace file"
    echo "Missing: /usr/local/bin/CAN.trc"
  fi
}

print_rtc_info() {
  print_section "RTC / Time Information"

  if command_exists timedatectl; then
    print_command_output "timedatectl" timedatectl
  fi

  if command_exists hwclock; then
    print_command_output "hwclock read" hwclock -r
  else
    echo "hwclock not available."
  fi

  if command_exists i2cdetect; then
    print_command_output "i2cdetect bus 1" i2cdetect -y 1
  else
    echo "i2cdetect not available."
  fi

  if [ -e /dev/rtc0 ]; then
    echo
    echo "/dev/rtc0 exists."
  else
    echo
    echo "/dev/rtc0 not found."
  fi
}

print_dashboard_info() {
  print_section "Dashboard / Web Terminal Information"

  if command_exists node-red; then
    print_command_output "Node-RED version" node-red --version
  else
    echo "node-red not found."
  fi

  if command_exists ttyd; then
    echo
    echo "ttyd: $(command -v ttyd)"
  else
    echo
    echo "ttyd not found."
  fi

  if [ -d /home/initbox/.node-red ]; then
    print_subsection "Node-RED directory"
    ls -la /home/initbox/.node-red || true
  fi
}

print_sniffer_info() {
  print_section "Sniffer / Trace Files"

  if command_exists tshark; then
    print_command_output "tshark version" tshark --version
  else
    echo "tshark not found."
  fi

  if command_exists dumpcap; then
    print_command_output "dumpcap capabilities" getcap "$(command -v dumpcap)"
  else
    echo "dumpcap not found."
  fi

  if [ -d "$TRACE_DIR" ]; then
    print_subsection "Trace directory"
    ls -lah "$TRACE_DIR" || true
  else
    echo "Trace directory not found: $TRACE_DIR"
  fi
}

print_failed_services() {
  print_section "Failed Services"

  if command_exists systemctl; then
    systemctl --failed --no-pager || true
  else
    echo "systemctl not available."
  fi
}

print_ports() {
  print_section "Listening Ports"

  if command_exists ss; then
    ss -tulpn || true
  else
    echo "ss command not available."
  fi
}

print_logs_summary() {
  print_section "Installer Logs"

  if [ -f "$LOG_FILE" ]; then
    print_subsection "$LOG_FILE"
    tail -n 60 "$LOG_FILE" || true
  else
    echo "Missing: $LOG_FILE"
  fi

  if [ -f "$LEGACY_LOG_FILE" ]; then
    print_subsection "$LEGACY_LOG_FILE"
    tail -n 60 "$LEGACY_LOG_FILE" || true
  else
    echo "Missing: $LEGACY_LOG_FILE"
  fi
}

main() {
  print_section "InitBox Pi 3/4/5 Status"
  echo "Generated at: $(date '+%Y-%m-%d %H:%M:%S %Z')"
  echo "Repository root: $REPO_ROOT"

  print_system_info
  print_initbox_state
  print_config_files
  print_network_info
  print_bridge_info
  print_can_info
  print_rtc_info
  print_dashboard_info
  print_sniffer_info
  print_failed_services
  print_ports
  print_known_services
  print_logs_summary

  echo
  echo "Status collection complete."
  echo
  echo "For detailed service logs, run:"
  echo "  sudo journalctl -u <service-name> -n 100 --no-pager"
  echo
  echo "To include service logs in this status output, run:"
  echo "  sudo ./scripts/initbox-status.sh logs"
}

case "${1:-}" in
  logs|--logs)
    main
    print_known_logs
    ;;
  -h|--help|help)
    cat <<'EOF'
Usage:
  ./scripts/initbox-status.sh
  ./scripts/initbox-status.sh logs

This command is read-only. It prints diagnostics for:
  - Pi 3/4/5 dashboard
  - hotspot
  - role file
  - ISI
  - FMS/CAN
  - sniffer bridge
  - RTC
EOF
    ;;
  *)
    main
    ;;
esac
