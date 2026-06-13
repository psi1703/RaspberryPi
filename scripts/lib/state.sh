#!/usr/bin/env bash
# InitBox install-state helper
#
# Records lab installation state for field diagnostics.
# Also records dashboard module availability flags in /etc/initbox-mods.conf.
#
# This helper does not install packages or run modules.

set -euo pipefail

INITBOX_STATE_DIR="/etc/initbox"
INITBOX_STATE_FILE="$INITBOX_STATE_DIR/install-state.env"
INITBOX_MODS_FILE="${INITBOX_MODS_FILE:-/etc/initbox-mods.conf}"

initbox_state_can_write() {
  [ "$(id -u)" -eq 0 ]
}

initbox_state_ensure_file() {
  if ! initbox_state_can_write; then
    echo "WARNING: install state requires root access: $INITBOX_STATE_FILE" >&2
    return 1
  fi

  mkdir -p "$INITBOX_STATE_DIR"

  if [ ! -f "$INITBOX_STATE_FILE" ]; then
    cat >"$INITBOX_STATE_FILE" <<'EOF'
# InitBox install state
# This file is generated during lab setup.
EOF
  fi
}

initbox_mods_ensure_file() {
  if ! initbox_state_can_write; then
    echo "WARNING: module flags require root access: $INITBOX_MODS_FILE" >&2
    return 1
  fi

  mkdir -p "$(dirname "$INITBOX_MODS_FILE")"

  if [ ! -f "$INITBOX_MODS_FILE" ]; then
    cat >"$INITBOX_MODS_FILE" <<'EOF'
# InitBox dashboard module availability flags
# 1 means the module/control is available in the dashboard.
# 0 means hide or disable the related dashboard control.
ISI=0
FMS=0
WSBR0=0
HOTSPOT=0
DASHBOARD=0
RTC=0
EOF
  fi

  chmod 0644 "$INITBOX_MODS_FILE"
  chown root:root "$INITBOX_MODS_FILE" 2>/dev/null || true
}

initbox_state_set_value() {
  local key="$1"
  local value="$2"
  local tmp_file=""

  if ! initbox_state_ensure_file; then
    return 1
  fi

  tmp_file="$(mktemp)"

  if grep -q "^${key}=" "$INITBOX_STATE_FILE"; then
    grep -v "^${key}=" "$INITBOX_STATE_FILE" >"$tmp_file"
  else
    cat "$INITBOX_STATE_FILE" >"$tmp_file"
  fi

  printf '%s="%s"\n' "$key" "$value" >>"$tmp_file"
  cat "$tmp_file" >"$INITBOX_STATE_FILE"
  rm -f "$tmp_file"

  chmod 0644 "$INITBOX_STATE_FILE"
  chown root:root "$INITBOX_STATE_FILE" 2>/dev/null || true
}

initbox_mods_set_value() {
  local key="$1"
  local value="$2"
  local tmp_file=""

  if ! initbox_mods_ensure_file; then
    return 1
  fi

  tmp_file="$(mktemp)"

  if grep -q "^${key}=" "$INITBOX_MODS_FILE"; then
    grep -v "^${key}=" "$INITBOX_MODS_FILE" >"$tmp_file"
  else
    cat "$INITBOX_MODS_FILE" >"$tmp_file"
  fi

  printf '%s=%s\n' "$key" "$value" >>"$tmp_file"
  cat "$tmp_file" >"$INITBOX_MODS_FILE"
  rm -f "$tmp_file"

  chmod 0644 "$INITBOX_MODS_FILE"
  chown root:root "$INITBOX_MODS_FILE" 2>/dev/null || true
}

initbox_module_to_mod_key() {
  local module_id="$1"

  case "$module_id" in
    isi)
      printf '%s\n' "ISI"
      ;;
    fms)
      printf '%s\n' "FMS"
      ;;
    sniffer-bridge|ws-br0|wsbr0|eth-sniffer|ethsniffer|sniff)
      printf '%s\n' "WSBR0"
      ;;
    hotspot)
      printf '%s\n' "HOTSPOT"
      ;;
    dashboard)
      printf '%s\n' "DASHBOARD"
      ;;
    rtc)
      printf '%s\n' "RTC"
      ;;
    *)
      return 1
      ;;
  esac
}

initbox_state_module_key_prefix() {
  local module_id="$1"

  printf '%s' "$module_id" | tr '[:lower:]-' '[:upper:]_'
}

initbox_state_record_profile() {
  local profile_id="$1"
  local profile_name="$2"
  local timestamp=""

  timestamp="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

  initbox_state_set_value "PROFILE_ID" "$profile_id"
  initbox_state_set_value "PROFILE_NAME" "$profile_name"
  initbox_state_set_value "LAB_SETUP_STARTED_AT" "$timestamp"
  initbox_mods_ensure_file || true
}

initbox_state_record_module_success() {
  local module_id="$1"
  local module_name="$2"
  local timestamp=""
  local key_prefix=""
  local mod_key=""

  timestamp="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  key_prefix="$(initbox_state_module_key_prefix "$module_id")"

  initbox_state_set_value "MODULE_${key_prefix}_STATUS" "installed"
  initbox_state_set_value "MODULE_${key_prefix}_NAME" "$module_name"
  initbox_state_set_value "MODULE_${key_prefix}_INSTALLED_AT" "$timestamp"

  if mod_key="$(initbox_module_to_mod_key "$module_id")"; then
    initbox_mods_set_value "$mod_key" "1"
  fi
}

initbox_state_record_module_failure() {
  local module_id="$1"
  local module_name="$2"
  local timestamp=""
  local key_prefix=""
  local mod_key=""

  timestamp="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  key_prefix="$(initbox_state_module_key_prefix "$module_id")"

  initbox_state_set_value "MODULE_${key_prefix}_STATUS" "failed"
  initbox_state_set_value "MODULE_${key_prefix}_NAME" "$module_name"
  initbox_state_set_value "MODULE_${key_prefix}_FAILED_AT" "$timestamp"

  if mod_key="$(initbox_module_to_mod_key "$module_id")"; then
    initbox_mods_set_value "$mod_key" "0"
  fi
}

initbox_state_record_module_uninstalled() {
  local module_id="$1"
  local module_name="$2"
  local timestamp=""
  local key_prefix=""
  local mod_key=""

  timestamp="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  key_prefix="$(initbox_state_module_key_prefix "$module_id")"

  initbox_state_set_value "MODULE_${key_prefix}_STATUS" "uninstalled"
  initbox_state_set_value "MODULE_${key_prefix}_NAME" "$module_name"
  initbox_state_set_value "MODULE_${key_prefix}_UNINSTALLED_AT" "$timestamp"

  if mod_key="$(initbox_module_to_mod_key "$module_id")"; then
    initbox_mods_set_value "$mod_key" "0"
  fi
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

  echo
  echo "InitBox dashboard module flags"
  echo "------------------------------"

  if [ -f "$INITBOX_MODS_FILE" ]; then
    cat "$INITBOX_MODS_FILE"
  else
    echo "No InitBox module flags found."
    echo "Expected path: $INITBOX_MODS_FILE"
  fi
}
