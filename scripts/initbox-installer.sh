#!/usr/bin/env bash
# InitBox Raspberry Pi installer skeleton
#
# This script loads a hardware profile, shows supported modules,
# and lets the operator select a module.
#
# Safety mode:
#   This version does not run module scripts yet.
#   It only prints which script would be executed.

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

SUPPORTED_MODULES=()

add_supported_module() {
  local module_id="$1"

  if initbox_profile_supports_module "$module_id"; then
    SUPPORTED_MODULES+=("$module_id")
  fi
}

build_supported_module_list() {
  SUPPORTED_MODULES=()

  add_supported_module "isi"
  add_supported_module "fms"
  add_supported_module "hotspot"
  add_supported_module "web-terminal"
  add_supported_module "dashboard"
  add_supported_module "rtc"
  add_supported_module "sniffer-bridge"
}

print_header() {
  clear || true

  echo "InitBox Raspberry Pi Installer"
  echo "=============================="
  echo
  initbox_print_profile_summary
  echo

  if [ "$PROFILE_ID" = "pi-zero2w" ]; then
    echo "Pi Zero 2W policy:"
    echo "  Dashboard is intentionally disabled for this profile."
    echo "  Use Web Terminal instead."
    echo
  fi
}

print_menu() {
  local index
  local module_id
  local module_name
  local module_script

  echo "Available modules"
  echo "-----------------"

  index=1
  for module_id in "${SUPPORTED_MODULES[@]}"; do
    module_name="$(initbox_module_display_name "$module_id")"

    if module_script="$(initbox_module_script_path "$PROFILE_ID" "$module_id" "$REPO_ROOT")"; then
      if [ -f "$module_script" ]; then
        printf '  %d) %-16s %s\n' "$index" "$module_name" "[script found]"
      else
        printf '  %d) %-16s %s\n' "$index" "$module_name" "[script missing]"
      fi
    else
      printf '  %d) %-16s %s\n' "$index" "$module_name" "[not mapped]"
    fi

    index=$((index + 1))
  done

  echo "  q) Quit"
  echo
}

show_selection_result() {
  local selected_index="$1"
  local module_id
  local module_name
  local module_script

  module_id="${SUPPORTED_MODULES[$((selected_index - 1))]}"
  module_name="$(initbox_module_display_name "$module_id")"

  echo
  echo "Selected module"
  echo "---------------"
  echo "Module ID:   $module_id"
  echo "Module name: $module_name"

  initbox_require_supported_module "$module_id"

  if ! module_script="$(initbox_module_script_path "$PROFILE_ID" "$module_id" "$REPO_ROOT")"; then
    echo "ERROR: no script mapping exists for module '$module_id' on profile '$PROFILE_ID'."
    exit 1
  fi

  echo "Script:      $module_script"

  if [ ! -f "$module_script" ]; then
    echo
    echo "ERROR: module script is missing."
    echo "No installation has been performed."
    exit 1
  fi

  echo
  echo "Safety mode:"
  echo "  No installation has been performed."
  echo "  This installer would run the script above in a later step."
}

main() {
  local choice
  local max_choice

  build_supported_module_list

  if [ "${#SUPPORTED_MODULES[@]}" -eq 0 ]; then
    echo "ERROR: no supported modules found for profile '$PROFILE_ID'."
    exit 1
  fi

  while true; do
    print_header
    print_menu

    max_choice="${#SUPPORTED_MODULES[@]}"

    printf 'Select a module [1-%s] or q: ' "$max_choice"
    read -r choice

    case "$choice" in
      q|Q)
        echo "Quit."
        exit 0
        ;;
      ''|*[!0-9]*)
        echo
        echo "Invalid choice: $choice"
        echo "Press Enter to continue."
        read -r _
        ;;
      *)
        if [ "$choice" -ge 1 ] && [ "$choice" -le "$max_choice" ]; then
          show_selection_result "$choice"
          echo
          echo "Press Enter to return to the menu."
          read -r _
        else
          echo
          echo "Invalid choice: $choice"
          echo "Press Enter to continue."
          read -r _
        fi
        ;;
    esac
  done
}

main
