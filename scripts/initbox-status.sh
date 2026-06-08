#!/usr/bin/env bash

# InitBox field diagnostics command
#
# This script prints local diagnostic information.
# It does not install packages or require Internet access.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
STATE_HELPER="$REPO_ROOT/scripts/lib/state.sh"

if [ -f "$STATE_HELPER" ]; then
  # shellcheck disable=SC1091
  . "$STATE_HELPER"
fi

print_section() {
  local title="$1"

  echo
  echo "$title"
  echo "========================================"
}

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

print_command_output() {
  local description="$1"
  shift

  echo
  echo "$description"
  echo "----------------------------------------"

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

  echo
  echo "Service: $service_name"
  echo "----------------------------------------"

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

  echo
  echo "Recent log: $service_name"
  echo "----------------------------------------"

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
hostapd
dnsmasq
ttyd
nodered
pi-nodered
portal
isirunall
fms
bridge-check
wireshark-autostart
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
hostapd
dnsmasq
ttyd
nodered
pi-nodered
portal
isirunall
fms
bridge-check
wireshark-autostart
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

print_system_info() {
  print_section "System Information"

  print_command_output "Hostname" hostname

  if command_exists uname; then
    print_command_output "Kernel" uname -a
  fi

  if [ -f /etc/os-release ]; then
    echo
    echo "OS release"
    echo "----------------------------------------"
    cat /etc/os-release
  fi

  if command_exists uptime; then
    print_command_output "Uptime" uptime
  fi
}

print_network_info() {
  print_section "Network Information"

  if command_exists ip; then
    print_command_output "IP addresses" ip addr
    print_command_output "Routes" ip route
    print_command_output "Links" ip link show

    echo
    echo "Common interface checks"
    echo "----------------------------------------"
    ip addr show wlan0 2>/dev/null || echo "wlan0 not found."
    ip link show can0 2>/dev/null || echo "can0 not found."
    ip link show br0 2>/dev/null || echo "br0 not found."
  else
    echo "ip command not available."
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

main() {
  print_section "InitBox Status"
  echo "Generated at: $(date '+%Y-%m-%d %H:%M:%S %Z')"

  print_system_info
  print_initbox_state
  print_network_info
  print_failed_services
  print_ports
  print_known_services

  echo
  echo "Status collection complete."
  echo
  echo "For detailed service logs, run:"
  echo "  sudo journalctl -u <service-name> -n 100 --no-pager"
}

main "$@"
