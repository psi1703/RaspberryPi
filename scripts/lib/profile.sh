#!/usr/bin/env bash
# InitBox profile helper.
#
# Source this file; do not execute it directly.
# It loads and validates the hardware profile selected by hardware.sh.

set -euo pipefail

INITBOX_PROFILE_LOADED="no"
INITBOX_MODULE_IDS="hotspot runtime-control web-terminal dashboard sniffer-bridge isi fms rtc"

PROFILE_ID=""
PROFILE_NAME=""
PROFILE_DESCRIPTION=""
PROFILE_NOTES=""
REQUIRES_LAB_INTERNET=""
FIELD_INSTALL_ALLOWED=""
SUPPORTS_DASHBOARD=""
SUPPORTS_WEB_TERMINAL=""
DASHBOARD_INSTALL_POLICY=""
DEFAULT_MODULES=""
PRIMARY_MANAGEMENT_INTERFACE=""

initbox_repo_root() {
  local script_dir=""

  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  cd "$script_dir/../.." >/dev/null 2>&1
  pwd
}

initbox_profile_path() {
  local profile_id="$1"
  local repo_root=""

  repo_root="$(initbox_repo_root)"
  printf '%s/profiles/%s.conf\n' "$repo_root" "$profile_id"
}

initbox_require_var() {
  local var_name="$1"

  if [ -z "${!var_name:-}" ]; then
    echo "ERROR: required profile variable is missing: $var_name" >&2
    return 1
  fi
}

initbox_require_yes_no_var() {
  local var_name="$1"
  local value=""

  initbox_require_var "$var_name"
  value="${!var_name}"

  case "$value" in
    yes|no)
      ;;
    *)
      echo "ERROR: $var_name must be yes or no. Current value: $value" >&2
      return 1
      ;;
  esac
}

initbox_module_var_name() {
  local module_id="$1"
  local upper=""

  upper="$(printf '%s' "$module_id" | tr '[:lower:]-' '[:upper:]_')"
  printf 'MODULE_%s\n' "$upper"
}

initbox_module_id_valid() {
  local requested_module_id="$1"
  local module_id=""

  for module_id in $INITBOX_MODULE_IDS; do
    if [ "$module_id" = "$requested_module_id" ]; then
      return 0
    fi
  done

  return 1
}

initbox_validate_module_flags() {
  local module_id=""
  local var_name=""
  local value=""

  for module_id in $INITBOX_MODULE_IDS; do
    var_name="$(initbox_module_var_name "$module_id")"
    initbox_require_var "$var_name"
    value="${!var_name}"

    case "$value" in
      yes|no)
        ;;
      *)
        echo "ERROR: $var_name must be yes or no. Current value: $value" >&2
        return 1
        ;;
    esac
  done
}

initbox_validate_default_modules() {
  local module_id=""
  local var_name=""
  local value=""
  local seen_modules=" "
  local -a default_modules=()

  read -r -a default_modules <<< "$DEFAULT_MODULES"

  for module_id in "${default_modules[@]}"; do
    if ! initbox_module_id_valid "$module_id"; then
      echo "ERROR: DEFAULT_MODULES contains unknown module: $module_id" >&2
      return 1
    fi

    case "$seen_modules" in
      *" $module_id "*)
        echo "ERROR: DEFAULT_MODULES contains duplicate module: $module_id" >&2
        return 1
        ;;
    esac

    seen_modules="${seen_modules}${module_id} "
    var_name="$(initbox_module_var_name "$module_id")"
    value="${!var_name}"

    if [ "$value" != "yes" ]; then
      echo "ERROR: module '$module_id' is in DEFAULT_MODULES but $var_name is '$value'." >&2
      return 1
    fi
  done
}

initbox_default_modules_contains() {
  local requested_module_id="$1"
  local module_id=""
  local -a default_modules=()

  read -r -a default_modules <<< "$DEFAULT_MODULES"

  for module_id in "${default_modules[@]}"; do
    if [ "$module_id" = "$requested_module_id" ]; then
      return 0
    fi
  done

  return 1
}

initbox_validate_pi_zero_policy() {
  if [ "$PROFILE_ID" != "pi-zero2w" ]; then
    return 0
  fi

  if [ "$SUPPORTS_DASHBOARD" != "no" ]; then
    echo "ERROR: pi-zero2w must set SUPPORTS_DASHBOARD=no." >&2
    return 1
  fi

  if [ "$MODULE_DASHBOARD" != "no" ]; then
    echo "ERROR: pi-zero2w must set MODULE_DASHBOARD=no." >&2
    return 1
  fi

  if [ "$DASHBOARD_INSTALL_POLICY" != "disabled" ]; then
    echo "ERROR: pi-zero2w must set DASHBOARD_INSTALL_POLICY=disabled." >&2
    return 1
  fi

  if [ "$SUPPORTS_WEB_TERMINAL" != "yes" ] || [ "$MODULE_WEB_TERMINAL" != "yes" ]; then
    echo "ERROR: pi-zero2w must support the Web Terminal." >&2
    return 1
  fi

  if [ "$PRIMARY_MANAGEMENT_INTERFACE" != "web-terminal" ]; then
    echo "ERROR: pi-zero2w must use web-terminal as its primary management interface." >&2
    return 1
  fi

  if [ "$MODULE_RTC" != "no" ]; then
    echo "ERROR: pi-zero2w must set MODULE_RTC=no." >&2
    return 1
  fi

  if [ "$MODULE_RUNTIME_CONTROL" != "no" ]; then
    echo "ERROR: pi-zero2w must set MODULE_RUNTIME_CONTROL=no." >&2
    return 1
  fi

  if initbox_default_modules_contains dashboard; then
    echo "ERROR: pi-zero2w DEFAULT_MODULES must not include dashboard." >&2
    return 1
  fi

  if initbox_default_modules_contains rtc; then
    echo "ERROR: pi-zero2w DEFAULT_MODULES must not include rtc." >&2
    return 1
  fi
}

initbox_validate_pi_full_policy() {
  if [ "$PROFILE_ID" != "pi-full" ]; then
    return 0
  fi

  if [ "$SUPPORTS_DASHBOARD" != "yes" ] || [ "$MODULE_DASHBOARD" != "yes" ]; then
    echo "ERROR: pi-full must support the React Dashboard." >&2
    return 1
  fi

  if [ "$DASHBOARD_INSTALL_POLICY" != "prompt" ]; then
    echo "ERROR: pi-full must set DASHBOARD_INSTALL_POLICY=prompt." >&2
    return 1
  fi

  if [ "$SUPPORTS_WEB_TERMINAL" != "yes" ] || [ "$MODULE_WEB_TERMINAL" != "yes" ]; then
    echo "ERROR: pi-full must support the Web Terminal independently of the dashboard." >&2
    return 1
  fi

  if [ "$PRIMARY_MANAGEMENT_INTERFACE" != "web-terminal" ]; then
    echo "ERROR: pi-full baseline management interface must be web-terminal." >&2
    return 1
  fi

  if [ "$MODULE_RUNTIME_CONTROL" != "yes" ]; then
    echo "ERROR: pi-full must include the shared Runtime Control module." >&2
    return 1
  fi

  if ! initbox_default_modules_contains runtime-control; then
    echo "ERROR: pi-full DEFAULT_MODULES must include runtime-control." >&2
    return 1
  fi

  if initbox_default_modules_contains dashboard; then
    echo "ERROR: pi-full DEFAULT_MODULES must not include dashboard; the installer must ask explicitly." >&2
    return 1
  fi
}

initbox_validate_loaded_profile() {
  if [ "$INITBOX_PROFILE_LOADED" != "yes" ]; then
    echo "ERROR: no InitBox profile has been loaded." >&2
    return 1
  fi

  initbox_require_var PROFILE_ID
  initbox_require_var PROFILE_NAME
  initbox_require_var PROFILE_DESCRIPTION
  initbox_require_var PROFILE_NOTES
  initbox_require_yes_no_var REQUIRES_LAB_INTERNET
  initbox_require_yes_no_var FIELD_INSTALL_ALLOWED
  initbox_require_yes_no_var SUPPORTS_DASHBOARD
  initbox_require_yes_no_var SUPPORTS_WEB_TERMINAL
  initbox_require_var DASHBOARD_INSTALL_POLICY
  initbox_require_var DEFAULT_MODULES
  initbox_require_var PRIMARY_MANAGEMENT_INTERFACE

  case "$PROFILE_ID" in
    pi-zero2w|pi-full)
      ;;
    *)
      echo "ERROR: unsupported InitBox profile id: $PROFILE_ID" >&2
      return 1
      ;;
  esac

  case "$DASHBOARD_INSTALL_POLICY" in
    disabled|prompt)
      ;;
    *)
      echo "ERROR: DASHBOARD_INSTALL_POLICY must be disabled or prompt." >&2
      return 1
      ;;
  esac

  initbox_validate_module_flags
  initbox_validate_default_modules
  initbox_validate_pi_zero_policy
  initbox_validate_pi_full_policy
}

initbox_load_profile() {
  local requested_profile_id="$1"
  local profile_file=""

  if [ -z "$requested_profile_id" ]; then
    echo "ERROR: profile id is required." >&2
    return 1
  fi

  profile_file="$(initbox_profile_path "$requested_profile_id")"

  if [ ! -f "$profile_file" ]; then
    echo "ERROR: profile file not found: $profile_file" >&2
    return 1
  fi

  # Profile files are repository-maintained shell-compatible assignments.
  # shellcheck source=/dev/null
  . "$profile_file"

  INITBOX_PROFILE_LOADED="yes"
  initbox_validate_loaded_profile

  if [ "$PROFILE_ID" != "$requested_profile_id" ]; then
    echo "ERROR: loaded profile '$PROFILE_ID' does not match requested profile '$requested_profile_id'." >&2
    return 1
  fi
}

initbox_validate_profile_for_hardware() {
  local detected_profile_id="$1"

  if [ "$INITBOX_PROFILE_LOADED" != "yes" ]; then
    echo "ERROR: no InitBox profile has been loaded." >&2
    return 1
  fi

  if [ -z "$detected_profile_id" ]; then
    echo "ERROR: detected hardware profile id is required." >&2
    return 1
  fi

  if [ "$PROFILE_ID" != "$detected_profile_id" ]; then
    echo "ERROR: profile '$PROFILE_ID' does not match detected hardware profile '$detected_profile_id'." >&2
    return 1
  fi
}

initbox_profile_supports_module() {
  local module_id="$1"
  local var_name=""
  local value=""

  if [ "$INITBOX_PROFILE_LOADED" != "yes" ]; then
    echo "ERROR: no InitBox profile has been loaded." >&2
    return 1
  fi

  if ! initbox_module_id_valid "$module_id"; then
    echo "ERROR: unknown module id: $module_id" >&2
    return 1
  fi

  var_name="$(initbox_module_var_name "$module_id")"
  value="${!var_name}"

  [ "$value" = "yes" ]
}

initbox_require_supported_module() {
  local module_id="$1"

  if initbox_profile_supports_module "$module_id"; then
    return 0
  fi

  echo "ERROR: module '$module_id' is not supported by profile '$PROFILE_ID' ($PROFILE_NAME)." >&2
  return 1
}

initbox_print_profile_summary() {
  if [ "$INITBOX_PROFILE_LOADED" != "yes" ]; then
    echo "ERROR: no InitBox profile has been loaded." >&2
    return 1
  fi

  cat <<EOF_SUMMARY
InitBox profile loaded
----------------------
Profile ID:        $PROFILE_ID
Profile name:      $PROFILE_NAME
Description:       $PROFILE_DESCRIPTION
Lab Internet:      $REQUIRES_LAB_INTERNET
Field install:     $FIELD_INSTALL_ALLOWED
Dashboard support: $SUPPORTS_DASHBOARD
Dashboard policy:  $DASHBOARD_INSTALL_POLICY
Web Terminal:      $SUPPORTS_WEB_TERMINAL
Default modules:   $DEFAULT_MODULES
Baseline UI:       $PRIMARY_MANAGEMENT_INTERFACE
Notes:             $PROFILE_NOTES
EOF_SUMMARY
}
