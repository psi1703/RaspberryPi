#!/usr/bin/env bash
# InitBox unified module runner.
#
# This wrapper is the compatibility boundary between the unified installer and
# profile-specific module implementations. It detects the Raspberry Pi model,
# loads the matching profile, validates the requested module, exports the
# profile-specific package/cache paths expected by the module, and records the
# module result in /etc/initbox/install-state.env.
#
# Usage:
#   sudo scripts/lib/module-runner.sh install MODULE
#   sudo scripts/lib/module-runner.sh uninstall MODULE
#
# MODULE is one of:
#   hotspot web-terminal dashboard sniffer-bridge isi fms rtc
set -euo pipefail

ACTION="${1:-}"
MODULE_ID="${2:-}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

HARDWARE_LIB="$REPO_ROOT/scripts/lib/hardware.sh"
PROFILE_LIB="$REPO_ROOT/scripts/lib/profile.sh"
MODULES_LIB="$REPO_ROOT/scripts/lib/modules.sh"
STATE_LIB="$REPO_ROOT/scripts/lib/state.sh"

fail() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

require_root() {
  if [ "$(id -u)" -ne 0 ]; then
    fail "module runner must be run as root"
  fi
}

require_file() {
  local path="$1"

  if [ ! -f "$path" ]; then
    fail "required file is missing: $path"
  fi
}

usage() {
  cat <<'EOF_USAGE'
Usage:
  sudo scripts/lib/module-runner.sh install MODULE
  sudo scripts/lib/module-runner.sh uninstall MODULE

Actions:
  install
  uninstall
  remove      Alias for uninstall
  purge       Compatibility action; profile modules treat purge as uninstall

Modules:
  hotspot
  web-terminal
  dashboard
  sniffer-bridge
  isi
  fms
  rtc

The Raspberry Pi model is detected automatically. Unsupported modules are
blocked by the selected hardware profile.
EOF_USAGE
}

normalize_state_action() {
  case "$ACTION" in
    install)
      printf 'install\n'
      ;;
    uninstall|remove|purge)
      printf 'uninstall\n'
      ;;
    *)
      return 1
      ;;
  esac
}

main() {
  local detected_profile_id=""
  local module_script=""
  local module_name=""
  local state_action=""
  local packages_file=""
  local package_cache_root=""
  local apt_cache_dir=""

  case "$ACTION" in
    install|uninstall|remove|purge)
      ;;
    -h|--help|help|"")
      usage
      return 0
      ;;
    *)
      usage >&2
      fail "unknown action: $ACTION"
      ;;
  esac

  if [ -z "$MODULE_ID" ]; then
    usage >&2
    fail "module id is required"
  fi

  require_root
  require_file "$HARDWARE_LIB"
  require_file "$PROFILE_LIB"
  require_file "$MODULES_LIB"
  require_file "$STATE_LIB"

  # shellcheck source=/dev/null
  . "$HARDWARE_LIB"
  # shellcheck source=/dev/null
  . "$PROFILE_LIB"
  # shellcheck source=/dev/null
  . "$MODULES_LIB"
  # shellcheck source=/dev/null
  . "$STATE_LIB"

  initbox_detect_hardware
  detected_profile_id="$INITBOX_PROFILE_ID"

  initbox_load_profile "$detected_profile_id"
  initbox_validate_profile_for_hardware "$detected_profile_id"
  initbox_require_supported_module "$MODULE_ID"

  if ! module_script="$(initbox_module_script_path "$detected_profile_id" "$MODULE_ID" "$REPO_ROOT")"; then
    fail "no module implementation exists for profile '$detected_profile_id' and module '$MODULE_ID'"
  fi
  require_file "$module_script"

  module_name="$(initbox_module_display_name "$MODULE_ID")"
  state_action="$(normalize_state_action)"
  packages_file="$REPO_ROOT/scripts/packages/${detected_profile_id}.txt"
  require_file "$packages_file"

  package_cache_root="${INITBOX_PACKAGE_CACHE_ROOT:-/opt/initbox/packages}"
  apt_cache_dir="${INITBOX_APT_CACHE_DIR:-${package_cache_root}/apt}"

  # Compatibility environment for the proven profile-specific modules. Older
  # modules accepted these variables while defaulting to the former single
  # scripts/packages.txt layout. The unified runner always supplies the new
  # profile-specific allow-list and APT cache location.
  export INITBOX_REPO_ROOT="$REPO_ROOT"
  export INITBOX_PROFILE_ID="$detected_profile_id"
  export INITBOX_PACKAGES_FILE="$packages_file"
  export INITBOX_PACKAGE_CACHE_ROOT="$package_cache_root"
  export INITBOX_APT_CACHE_DIR="$apt_cache_dir"
  export INITBOX_PACKAGE_CACHE_DIR="$apt_cache_dir"
  export HOTSPOT_GATEWAY="$INITBOX_HOTSPOT_GATEWAY"

  initbox_state_record_hardware \
    "$INITBOX_HARDWARE_ID" \
    "$INITBOX_HARDWARE_NAME" \
    "$INITBOX_MODEL_RAW" \
    "$INITBOX_HOTSPOT_GATEWAY" \
    "$INITBOX_DASHBOARD_CAPABLE"
  initbox_state_record_profile "$PROFILE_ID" "$PROFILE_NAME"

  if [ "$detected_profile_id" = "pi-zero2w" ]; then
    initbox_state_record_dashboard_selection "no" "policy"
  fi

  initbox_state_record_module_started "$MODULE_ID" "$module_name" "$state_action"

  printf 'InitBox module runner\n'
  printf '%s\n' '---------------------'
  printf 'Hardware: %s\n' "$INITBOX_HARDWARE_NAME"
  printf 'Profile:  %s\n' "$detected_profile_id"
  printf 'Module:   %s (%s)\n' "$module_name" "$MODULE_ID"
  printf 'Action:   %s\n' "$ACTION"
  printf 'Script:   %s\n' "$module_script"
  printf '\n'

  if bash "$module_script" "$ACTION"; then
    if [ "$state_action" = "install" ]; then
      initbox_state_record_module_success "$MODULE_ID" "$module_name"
    else
      initbox_state_record_module_uninstalled "$MODULE_ID" "$module_name"
    fi
    return 0
  fi

  initbox_state_record_module_failure "$MODULE_ID" "$module_name"
  fail "module action failed: $MODULE_ID $ACTION"
}

main "$@"
