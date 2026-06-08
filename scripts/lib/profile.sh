#!/usr/bin/env bash

# InitBox profile helper
#
# This file loads and validates Raspberry Pi hardware profiles.
# It does not install packages or modify the system.

set -euo pipefail

INITBOX_PROFILE_LOADED="no"

PROFILE_ID=""
PROFILE_NAME=""
PROFILE_DESCRIPTION=""
PROFILE_NOTES=""
REQUIRES_LAB_INTERNET=""
FIELD_INSTALL_ALLOWED=""
SUPPORTS_DASHBOARD=""
SUPPORTS_WEB_TERMINAL=""
DEFAULT_MODULES=""
PRIMARY_MANAGEMENT_INTERFACE=""

initbox_repo_root() {
  local script_dir

  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  cd "$script_dir/../.." >/dev/null 2>&1
  pwd
}

initbox_profile_path() {
  local profile_id="$1"
  local repo_root

  repo_root="$(initbox_repo_root)"
  printf '%s/profiles/%s.conf\n' "$repo_root" "$profile_id"
}

initbox_load_profile() {
  local requested_profile_id="$1"
  local profile_file

  if [ -z "$requested_profile_id" ]; then
    echo "ERROR: profile id is required." >&2
    return 1
  fi

  profile_file="$(initbox_profile_path "$requested_profile_id")"

  if [ ! -f "$profile_file" ]; then
    echo "ERROR: profile file not found: $profile_file" >&2
    return 1
  fi

  # Profile files are maintained by this repository and must contain
  # simple shell-compatible variable assignments only.
  # shellcheck source=/dev/null
  . "$profile_file"

  INITBOX_PROFILE_LOADED="yes"

  initbox_validate_loaded_profile

  if [ "$PROFILE_ID" != "$requested_profile_id" ]; then
    echo "ERROR: loaded profile id '$PROFILE_ID' does not match requested profile '$requested_profile_id'." >&2
    return 1
  fi
}

initbox_validate_loaded_profile() {
  if [ "${INITBOX_PROFILE_LOADED:-no}" != "yes" ]; then
    echo "ERROR: no InitBox profile has been loaded." >&2
    return 1
  fi

  initbox_require_var PROFILE_ID
  initbox_require_var PROFILE_NAME
  initbox_require_var REQUIRES_LAB_INTERNET
  initbox_require_var FIELD_INSTALL_ALLOWED
  initbox_require_var SUPPORTS_DASHBOARD
  initbox_require_var SUPPORTS_WEB_TERMINAL
  initbox_require_var DEFAULT_MODULES
  initbox_require_var PRIMARY_MANAGEMENT_INTERFACE

  case "$REQUIRES_LAB_INTERNET" in
    yes|no) ;;
    *)
      echo "ERROR: REQUIRES_LAB_INTERNET must be yes or no." >&2
      return 1
      ;;
  esac

  case "$FIELD_INSTALL_ALLOWED" in
    yes|no) ;;
    *)
      echo "ERROR: FIELD_INSTALL_ALLOWED must be yes or no." >&2
      return 1
      ;;
  esac

  case "$SUPPORTS_DASHBOARD" in
    yes|no) ;;
    *)
      echo "ERROR: SUPPORTS_DASHBOARD must be yes or no." >&2
      return 1
      ;;
  esac

  case "$SUPPORTS_WEB_TERMINAL" in
    yes|no) ;;
    *)
      echo "ERROR: SUPPORTS_WEB_TERMINAL must be yes or no." >&2
      return 1
      ;;
  esac
}

initbox_require_var() {
  local var_name="$1"

  if [ -z "${!var_name:-}" ]; then
    echo "ERROR: required profile variable is missing: $var_name" >&2
    return 1
  fi
}

initbox_module_var_name() {
  local module_id="$1"
  local upper

  upper="$(printf '%s' "$module_id" | tr '[:lower:]-' '[:upper:]_')"
  printf 'MODULE_%s\n' "$upper"
}

initbox_profile_supports_module() {
  local module_id="$1"
  local var_name
  local value

  if [ "${INITBOX_PROFILE_LOADED:-no}" != "yes" ]; then
    echo "ERROR: no InitBox profile has been loaded." >&2
    return 1
  fi

  if [ -z "$module_id" ]; then
    echo "ERROR: module id is required." >&2
    return 1
  fi

  var_name="$(initbox_module_var_name "$module_id")"
  value="${!var_name:-no}"

  case "$value" in
    yes)
      return 0
      ;;
    no|"")
      return 1
      ;;
    *)
      echo "ERROR: invalid module support value for $var_name: $value" >&2
      return 1
      ;;
  esac
}

initbox_require_supported_module() {
  local module_id="$1"
  local loaded_profile_id="${PROFILE_ID:-unknown}"
  local loaded_profile_name="${PROFILE_NAME:-unknown}"

  if initbox_profile_supports_module "$module_id"; then
    return 0
  fi

  echo "ERROR: module '$module_id' is not supported by profile '$loaded_profile_id' ($loaded_profile_name)." >&2
  return 1
}

initbox_print_profile_summary() {
  if [ "${INITBOX_PROFILE_LOADED:-no}" != "yes" ]; then
    echo "ERROR: no InitBox profile has been loaded." >&2
    return 1
  fi

  cat <<EOF
InitBox profile loaded
----------------------
Profile ID:      $PROFILE_ID
Profile name:    $PROFILE_NAME
Description:     ${PROFILE_DESCRIPTION:-}
Lab Internet:    $REQUIRES_LAB_INTERNET
Field install:   $FIELD_INSTALL_ALLOWED
Dashboard:       $SUPPORTS_DASHBOARD
Web Terminal:    $SUPPORTS_WEB_TERMINAL
Default modules: $DEFAULT_MODULES
Primary UI:      $PRIMARY_MANAGEMENT_INTERFACE
Notes:           ${PROFILE_NOTES:-}
EOF
}
