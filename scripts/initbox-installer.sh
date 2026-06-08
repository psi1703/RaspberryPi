#!/usr/bin/env bash
# InitBox Raspberry Pi installer skeleton
#
# This script loads a hardware profile and displays the modules allowed
# for that profile.
#
# It also checks whether the expected existing module scripts are present.
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

# shellcheck source=lib/modules.sh
. "$REPO_ROOT/scripts/lib/modules.sh"

initbox_load_profile "$PROFILE_ID"

clear || true

echo "InitBox Raspberry Pi Installer"
echo "=============================="
echo
initbox_print_profile_summary
echo

echo "Available modules for this profile"
echo "-----------------------------------"

while IFS= read -r module_id; do
  module_name="$(initbox_module_display_name "$module_id")"

  if initbox_profile_supports_module "$module_id"; then
    if initbox_module_script_exists "$PROFILE_ID" "$module_id" "$REPO_ROOT"; then
      printf '  [yes/found]   %-16s %s\n' "$module_id" "$module_name"
    else
      printf '  [yes/missing] %-16s %s\n' "$module_id" "$module_name"
    fi
  else
    printf '  [no]          %-16s %s\n' "$module_id" "$module_name"
  fi
done < <(initbox_all_known_modules)

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

initbox_print_module_registry "$PROFILE_ID" "$REPO_ROOT"

echo
echo "No installation has been performed."
echo "This skeleton only validates profile loading, module filtering, and module script paths."
