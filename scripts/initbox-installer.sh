#!/usr/bin/env bash
# InitBox Raspberry Pi installer skeleton
#
# This script loads a hardware profile and displays the modules allowed
# for that profile.
#
# It does not install packages yet.

set -euo pipefail

PROFILE_ID="${1:-}"

if [ -z "$PROFILE_ID" ]; then
  echo "ERROR: profile id is required."
  echo
  echo "Usage:"
  echo "  ./scripts/initbox-installer.sh pi-zero2w"
  echo "  ./scripts/initbox-installer.sh pi-3-4-5"
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=lib/profile.sh
. "$REPO_ROOT/scripts/lib/profile.sh"

initbox_load_profile "$PROFILE_ID"

clear || true

echo "InitBox Raspberry Pi Installer"
echo "=============================="
echo
initbox_print_profile_summary
echo

echo "Available modules for this profile"
echo "-----------------------------------"

AVAILABLE_MODULES=""

add_module_if_supported() {
  local module_id="$1"
  local module_name="$2"

  if initbox_profile_supports_module "$module_id"; then
    AVAILABLE_MODULES="$AVAILABLE_MODULES $module_id"
    printf '  [yes] %-16s %s\n' "$module_id" "$module_name"
  else
    printf '  [no ] %-16s %s\n' "$module_id" "$module_name"
  fi
}

add_module_if_supported "isi" "ISI"
add_module_if_supported "fms" "FMS"
add_module_if_supported "hotspot" "Hotspot"
add_module_if_supported "web-terminal" "Web Terminal"
add_module_if_supported "dashboard" "Dashboard"
add_module_if_supported "rtc" "RTC"
add_module_if_supported "sniffer-bridge" "Sniffer / Bridge"

echo
echo "Default modules:"
echo "  $DEFAULT_MODULES"
echo

if [ "$PROFILE_ID" = "pi-zero2w" ]; then
  echo "Pi Zero 2W policy:"
  echo "  Dashboard is intentionally disabled for this profile."
  echo "  Use Web Terminal instead."
  echo
fi

echo "No installation has been performed."
echo "This skeleton only validates profile loading and module filtering."
