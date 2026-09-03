#!/usr/bin/env bash
# InitBox unified install-state helper.
#
# Source this file; do not execute it directly.
# It records detected hardware, selected profile, Dashboard choice, and module
# installation state. It does not install packages, enable services, or modify
# module runtime configuration.

set -euo pipefail

INITBOX_STATE_DIR="${INITBOX_STATE_DIR:-/etc/initbox}"
INITBOX_STATE_FILE="${INITBOX_STATE_FILE:-$INITBOX_STATE_DIR/install-state.env}"

initbox_state_can_write() {
  [ "$(id -u)" -eq 0 ]
}

initbox_state_timestamp() {
  date -u '+%Y-%m-%dT%H:%M:%SZ'
}

initbox_state_key_valid() {
  local key="$1"

  case "$key" in
    ""|*[!A-Z0-9_]*|[0-9]*)
      return 1
      ;;
    *)
      return 0
      ;;
  esac
}

initbox_state_escape_value() {
  local value="$1"

  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  value="${value//$'\n'/ }"
  value="${value//$'\r'/ }"

  printf '%s\n' "$value"
}

initbox_state_unescape_value() {
  local value="$1"

  value="${value//\\\"/\"}"
  value="${value//\\\\/\\}"

  printf '%s\n' "$value"
}

initbox_state_ensure_file() {
  if ! initbox_state_can_write; then
    echo "WARNING: InitBox install state requires root access: $INITBOX_STATE_FILE" >&2
    return 1
  fi

  install -d -m 0755 "$INITBOX_STATE_DIR"

  if [ ! -f "$INITBOX_STATE_FILE" ]; then
    cat >"$INITBOX_STATE_FILE" <<'EOF_STATE'
# InitBox install state
# Generated during InitBox setup. Do not edit while the installer is running.
EOF_STATE
  fi

  chmod 0644 "$INITBOX_STATE_FILE"
  chown root:root "$INITBOX_STATE_FILE" 2>/dev/null || true
}

initbox_state_set_value() {
  local key="$1"
  local value="$2"
  local escaped_value=""
  local tmp_file=""

  if ! initbox_state_key_valid "$key"; then
    echo "ERROR: invalid InitBox state key: $key" >&2
    return 1
  fi

  initbox_state_ensure_file

  escaped_value="$(initbox_state_escape_value "$value")"
  tmp_file="$(mktemp)"

  grep -v "^${key}=" "$INITBOX_STATE_FILE" >"$tmp_file" || true
  printf '%s="%s"\n' "$key" "$escaped_value" >>"$tmp_file"

  install -o root -g root -m 0644 "$tmp_file" "$INITBOX_STATE_FILE"
  rm -f "$tmp_file"
}

initbox_state_unset_value() {
  local key="$1"
  local tmp_file=""

  if ! initbox_state_key_valid "$key"; then
    echo "ERROR: invalid InitBox state key: $key" >&2
    return 1
  fi

  initbox_state_ensure_file
  tmp_file="$(mktemp)"

  grep -v "^${key}=" "$INITBOX_STATE_FILE" >"$tmp_file" || true
  install -o root -g root -m 0644 "$tmp_file" "$INITBOX_STATE_FILE"
  rm -f "$tmp_file"
}

initbox_state_get_value() {
  local key="$1"
  local line=""
  local value=""

  if ! initbox_state_key_valid "$key"; then
    echo "ERROR: invalid InitBox state key: $key" >&2
    return 1
  fi

  if [ ! -f "$INITBOX_STATE_FILE" ]; then
    return 1
  fi

  line="$(grep -m 1 "^${key}=" "$INITBOX_STATE_FILE" 2>/dev/null || true)"
  if [ -z "$line" ]; then
    return 1
  fi

  value="${line#*=}"
  case "$value" in
    \"*\")
      value="${value#\"}"
      value="${value%\"}"
      ;;
  esac

  initbox_state_unescape_value "$value"
}

initbox_state_module_key_prefix() {
  local module_id="$1"
  local key_prefix=""

  key_prefix="$(printf '%s' "$module_id" | tr '[:lower:]-' '[:upper:]_')"
  if ! initbox_state_key_valid "$key_prefix"; then
    echo "ERROR: invalid module id for state key: $module_id" >&2
    return 1
  fi

  printf '%s\n' "$key_prefix"
}

initbox_state_clear_module_timestamps() {
  local module_id="$1"
  local key_prefix=""

  key_prefix="$(initbox_state_module_key_prefix "$module_id")"
  initbox_state_unset_value "MODULE_${key_prefix}_INSTALLED_AT" || true
  initbox_state_unset_value "MODULE_${key_prefix}_FAILED_AT" || true
  initbox_state_unset_value "MODULE_${key_prefix}_UNINSTALLED_AT" || true
}

initbox_state_record_hardware() {
  local hardware_id="$1"
  local hardware_name="$2"
  local model_raw="$3"
  local hotspot_gateway="$4"
  local dashboard_capable="$5"
  local timestamp=""

  timestamp="$(initbox_state_timestamp)"

  initbox_state_set_value "HARDWARE_ID" "$hardware_id"
  initbox_state_set_value "HARDWARE_NAME" "$hardware_name"
  initbox_state_set_value "HARDWARE_MODEL_RAW" "$model_raw"
  initbox_state_set_value "HOTSPOT_GATEWAY" "$hotspot_gateway"
  initbox_state_set_value "DASHBOARD_CAPABLE" "$dashboard_capable"
  initbox_state_set_value "HARDWARE_RECORDED_AT" "$timestamp"
}

initbox_state_record_profile() {
  local profile_id="$1"
  local profile_name="$2"
  local timestamp=""

  timestamp="$(initbox_state_timestamp)"

  initbox_state_set_value "PROFILE_ID" "$profile_id"
  initbox_state_set_value "PROFILE_NAME" "$profile_name"
  initbox_state_set_value "PROFILE_RECORDED_AT" "$timestamp"

  if ! initbox_state_get_value "LAB_SETUP_STARTED_AT" >/dev/null 2>&1; then
    initbox_state_set_value "LAB_SETUP_STARTED_AT" "$timestamp"
  fi
}

initbox_state_record_dashboard_selection() {
  local selected="$1"
  local source="${2:-operator}"
  local timestamp=""

  case "$selected" in
    yes|no)
      ;;
    *)
      echo "ERROR: Dashboard selection must be yes or no. Current value: $selected" >&2
      return 1
      ;;
  esac

  case "$source" in
    operator|policy)
      ;;
    *)
      echo "ERROR: Dashboard selection source must be operator or policy. Current value: $source" >&2
      return 1
      ;;
  esac

  timestamp="$(initbox_state_timestamp)"
  initbox_state_set_value "DASHBOARD_SELECTED" "$selected"
  initbox_state_set_value "DASHBOARD_SELECTION_SOURCE" "$source"
  initbox_state_set_value "DASHBOARD_SELECTION_AT" "$timestamp"
}

initbox_state_get_dashboard_selection() {
  local selected=""

  if ! selected="$(initbox_state_get_value "DASHBOARD_SELECTED")"; then
    return 1
  fi

  case "$selected" in
    yes|no)
      printf '%s\n' "$selected"
      ;;
    *)
      echo "ERROR: invalid stored Dashboard selection: $selected" >&2
      return 1
      ;;
  esac
}

initbox_state_record_module_started() {
  local module_id="$1"
  local module_name="$2"
  local action="${3:-install}"
  local key_prefix=""
  local timestamp=""

  case "$action" in
    install|uninstall)
      ;;
    *)
      echo "ERROR: unsupported module action for state: $action" >&2
      return 1
      ;;
  esac

  key_prefix="$(initbox_state_module_key_prefix "$module_id")"
  timestamp="$(initbox_state_timestamp)"

  initbox_state_set_value "MODULE_${key_prefix}_STATUS" "${action}_started"
  initbox_state_set_value "MODULE_${key_prefix}_NAME" "$module_name"
  initbox_state_set_value "MODULE_${key_prefix}_LAST_ACTION_AT" "$timestamp"
  initbox_state_set_value "LAST_MODULE_ID" "$module_id"
  initbox_state_set_value "LAST_MODULE_NAME" "$module_name"
  initbox_state_set_value "LAST_MODULE_STATUS" "${action}_started"
  initbox_state_set_value "LAST_MODULE_ACTION_AT" "$timestamp"
}

initbox_state_record_module_success() {
  local module_id="$1"
  local module_name="$2"
  local key_prefix=""
  local timestamp=""

  key_prefix="$(initbox_state_module_key_prefix "$module_id")"
  timestamp="$(initbox_state_timestamp)"

  initbox_state_clear_module_timestamps "$module_id"
  initbox_state_set_value "MODULE_${key_prefix}_STATUS" "installed"
  initbox_state_set_value "MODULE_${key_prefix}_NAME" "$module_name"
  initbox_state_set_value "MODULE_${key_prefix}_INSTALLED_AT" "$timestamp"
  initbox_state_set_value "MODULE_${key_prefix}_LAST_ACTION_AT" "$timestamp"
  initbox_state_set_value "LAST_MODULE_ID" "$module_id"
  initbox_state_set_value "LAST_MODULE_NAME" "$module_name"
  initbox_state_set_value "LAST_MODULE_STATUS" "installed"
  initbox_state_set_value "LAST_MODULE_ACTION_AT" "$timestamp"
}

initbox_state_record_module_failure() {
  local module_id="$1"
  local module_name="$2"
  local key_prefix=""
  local timestamp=""

  key_prefix="$(initbox_state_module_key_prefix "$module_id")"
  timestamp="$(initbox_state_timestamp)"

  initbox_state_clear_module_timestamps "$module_id"
  initbox_state_set_value "MODULE_${key_prefix}_STATUS" "failed"
  initbox_state_set_value "MODULE_${key_prefix}_NAME" "$module_name"
  initbox_state_set_value "MODULE_${key_prefix}_FAILED_AT" "$timestamp"
  initbox_state_set_value "MODULE_${key_prefix}_LAST_ACTION_AT" "$timestamp"
  initbox_state_set_value "LAST_MODULE_ID" "$module_id"
  initbox_state_set_value "LAST_MODULE_NAME" "$module_name"
  initbox_state_set_value "LAST_MODULE_STATUS" "failed"
  initbox_state_set_value "LAST_MODULE_ACTION_AT" "$timestamp"
}

initbox_state_record_module_uninstalled() {
  local module_id="$1"
  local module_name="$2"
  local key_prefix=""
  local timestamp=""

  key_prefix="$(initbox_state_module_key_prefix "$module_id")"
  timestamp="$(initbox_state_timestamp)"

  initbox_state_clear_module_timestamps "$module_id"
  initbox_state_set_value "MODULE_${key_prefix}_STATUS" "uninstalled"
  initbox_state_set_value "MODULE_${key_prefix}_NAME" "$module_name"
  initbox_state_set_value "MODULE_${key_prefix}_UNINSTALLED_AT" "$timestamp"
  initbox_state_set_value "MODULE_${key_prefix}_LAST_ACTION_AT" "$timestamp"
  initbox_state_set_value "LAST_MODULE_ID" "$module_id"
  initbox_state_set_value "LAST_MODULE_NAME" "$module_name"
  initbox_state_set_value "LAST_MODULE_STATUS" "uninstalled"
  initbox_state_set_value "LAST_MODULE_ACTION_AT" "$timestamp"
}

initbox_state_print() {
  if [ ! -f "$INITBOX_STATE_FILE" ]; then
    echo "No InitBox install state found."
    echo "Expected path: $INITBOX_STATE_FILE"
    return 1
  fi

  echo "InitBox install state"
  echo "---------------------"
  cat "$INITBOX_STATE_FILE"
}
