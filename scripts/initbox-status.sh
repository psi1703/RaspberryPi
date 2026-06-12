#!/usr/bin/env bash

# InitBox field diagnostics command
# This script prints local diagnostic information.
# It does not install packages or require Internet access.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

STATE_HELPER="$REPO_ROOT/scripts/lib/state.sh"
PACKAGES_HELPER="$REPO_ROOT/scripts/lib/packages.sh"
PACKAGES_FILE="$REPO_ROOT/scripts/packages.txt"
PACKAGE_CACHE_DIR="${INITBOX_PACKAGE_CACHE_DIR:-/opt/initbox/packages}"
TTYD_VERSION="${TTYD_VERSION:-1.7.7}"
TTYD_CACHE_DIR="$PACKAGE_CACHE_DIR/ttyd"

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
initbox-captive-http.socket
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

count_active_packages() {
  if [ ! -f "$PACKAGES_FILE" ]; then
    echo "0"
    return 0
  fi

  grep -Ec '^[[:space:]]*[^[:space:]#]' "$PACKAGES_FILE" || true
}

detect_ttyd_asset() {
  local machine=""

  machine="$(uname -m)"

  case "$machine" in
    aarch64|arm64)
      printf '%s\n' "ttyd.aarch64"
      ;;
    armv7l|armv6l)
      printf '%s\n' "ttyd.armhf"
      ;;
    arm*)
      printf '%s\n' "ttyd.arm"
      ;;
    x86_64|amd64)
      printf '%s\n' "ttyd.x86_64"
      ;;
    i386|i686)
      printf '%s\n' "ttyd.i686"
      ;;
    *)
      printf '%s\n' "unknown"
      ;;
  esac
}

print_package_file_preview() {
  local line_count

  if [ ! -f "$PACKAGES_FILE" ]; then
    echo "packages.txt not found."
    return 0
  fi

  line_count="$(count_active_packages)"

  echo "Active package count: $line_count"
  echo
  echo "Active packages:"
  echo "----------------------------------------"

  grep -Ev '^[[:space:]]*($|#)' "$PACKAGES_FILE" \
    | sed 's/[[:space:]]*#.*$//' \
    | awk '{$1=$1; print}' \
    | grep -Ev '^[[:space:]]*$' \
    | sort -u || true
}

print_offline_package_status() {
  local deb_count
  local package_count
  local ttyd_asset
  local cached_ttyd
  local status_ok

  status_ok="yes"
  deb_count="0"
  package_count="$(count_active_packages)"
  ttyd_asset="$(detect_ttyd_asset)"
  cached_ttyd="$TTYD_CACHE_DIR/${TTYD_VERSION}-${ttyd_asset}"

  print_section "Offline Package Readiness"

  echo "Repo root:       $REPO_ROOT"
  echo "Packages file:  $PACKAGES_FILE"
  echo "Package helper: $PACKAGES_HELPER"
  echo "Package cache:  $PACKAGE_CACHE_DIR"
  echo "ttyd cache dir: $TTYD_CACHE_DIR"
  echo "ttyd version:   $TTYD_VERSION"
  echo "ttyd asset:     $ttyd_asset"
  echo

  if [ -f "$PACKAGES_FILE" ]; then
    echo "[PASS] packages file exists"
  else
    echo "[FAIL] packages file missing"
    status_ok="no"
  fi

  if [ "$package_count" -gt 0 ]; then
    echo "[PASS] packages file has active packages: $package_count"
  else
    echo "[FAIL] packages file has no active package entries"
    status_ok="no"
  fi

  if [ -f "$PACKAGES_HELPER" ]; then
    echo "[PASS] package helper exists"
  else
    echo "[FAIL] package helper missing"
    status_ok="no"
  fi

  if [ -d "$PACKAGE_CACHE_DIR" ]; then
    echo "[PASS] package cache directory exists"

    deb_count="$(
      find "$PACKAGE_CACHE_DIR" -maxdepth 1 -type f -name '*.deb' 2>/dev/null \
        | wc -l \
        | tr -d '[:space:]'
    )"

    if [ "$deb_count" -gt 0 ]; then
      echo "[PASS] cached .deb files found: $deb_count"
    else
      echo "[FAIL] package cache has no .deb files"
      status_ok="no"
    fi
  else
    echo "[FAIL] package cache directory missing"
    status_ok="no"
  fi

  if [ "$ttyd_asset" = "unknown" ]; then
    echo "[WARN] could not determine ttyd asset for this CPU architecture"
  elif [ -x "$cached_ttyd" ]; then
    echo "[PASS] cached ttyd binary exists: $cached_ttyd"
  elif [ -f "$cached_ttyd" ]; then
    echo "[WARN] cached ttyd binary exists but is not executable: $cached_ttyd"
  else
    echo "[WARN] cached ttyd binary not found yet: $cached_ttyd"
    echo "       This is expected until the Web Terminal module downloads ttyd once in lab mode."
  fi

  echo
  echo "Package file preview"
  echo "----------------------------------------"
  print_package_file_preview

  echo
  echo "Cache preview"
  echo "----------------------------------------"

  if [ -d "$PACKAGE_CACHE_DIR" ]; then
    find "$PACKAGE_CACHE_DIR" -maxdepth 2 -type f \
      \( -name '*.deb' -o -name 'ttyd.*' -o -name "${TTYD_VERSION}-ttyd.*" \) \
      -printf '%p\n' 2>/dev/null \
      | sort \
      | head -n 80 || true
  else
    echo "No cache directory to preview."
  fi

  echo
  echo "Offline readiness summary"
  echo "----------------------------------------"

  if [ "$status_ok" = "yes" ]; then
    echo "[PASS] Debian package cache appears ready for offline module installs."
  else
    echo "[FAIL] Offline package cache is not ready."
    echo
    echo "In lab mode with Internet, run:"
    echo "  sudo ./scripts/initbox-installer.sh pi-zero2w p"
    echo
    echo "Then verify:"
    echo "  sudo ./scripts/initbox-installer.sh pi-zero2w v"
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
    ip link show eth0 2>/dev/null || echo "eth0 not found."
    ip link show eth1 2>/dev/null || echo "eth1 not found."
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
  print_offline_package_status
  print_network_info
  print_failed_services
  print_ports
  print_known_services

  echo
  echo "Status collection complete."
  echo
  echo "For detailed service logs, run:"
  echo "  sudo journalctl -u <service-name> -n 100 --no-pager"
  echo
  echo "For package cache setup in lab mode, run:"
  echo "  sudo ./scripts/initbox-installer.sh pi-zero2w p"
  echo "  sudo ./scripts/initbox-installer.sh pi-zero2w v"
}

main "$@"
