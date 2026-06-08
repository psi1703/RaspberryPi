#!/usr/bin/env bash
# InitBox install-state helper
#
# Records lab installation state for field diagnostics.
# This helper does not install packages or run modules.

set -euo pipefail

INITBOX_STATE_DIR="/etc/initbox"
INITBOX_STATE_FILE="$INITBOX_STATE_DIR/install-state.env"

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
    cat > "$INITBOX_STATE_FILE" <<'EOF'
# InitBox install state
# This file is generated during lab setup.
EOF
  fi
}

initbox_state_set_value() {
  local key="$1"
  local value="$2"
  local tmp_file

  if ! initbox_state_ensure_file; then
    return 1
  fi

  tmp_file="$(mktemp)"

  if grep -q "^${key}=" "$INITBOX_STATE_FILE"; then
    grep -v "^${key}=" "$INITBOX_STATE_FILE" > "$tmp_file"
  else
    cat "$INITBOX_STATE_FILE" > "$tmp_file"
  fi

  printf '%s="%s"\n' "$key" "$value" >> "$tmp_file"
  cat "$tmp_file" > "$INITBOX_STATE_FILE"
  rm -f "$tmp_file"
}

initbox_state_record_profile() {
  local profile_id="$1"
  local profile_name="$2"
  local timestamp

  timestamp="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

  initbox_state_set_value "PROFILE_ID" "$profile_id"
  initbox_state_set_value "PROFILE_NAME" "$profile_name"
  initbox_state_set_value "LAB_SETUP_STARTED_AT" "$timestamp"
}

initbox_state_record_module_success() {
  local module_id="$1"
  local module_name="$2"
  local timestamp
  local key_prefix

  timestamp="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  key_prefix="$(printf '%s' "$module_id" | tr '[:lower:]-' '[:upper:]_')"

  initbox_state_set_value "MODULE_${key_prefix}_STATUS" "installed"
  initbox_state_set_value "MODULE_${key_prefix}_NAME" "$module_name"
  initbox_state_set_value "MODULE_${key_prefix}_INSTALLED_AT" "$timestamp"
}

initbox_state_record_module_failure() {
  local module_id="$1"
  local module_name="$2"
  local timestamp
  local key_prefix

  timestamp="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  key_prefix="$(printf '%s' "$module_id" | tr '[:lower:]-' '[:upper:]_')"

  initbox_state_set_value "MODULE_${key_prefix}_STATUS" "failed"
  initbox_state_set_value "MODULE_${key_prefix}_NAME" "$module_name"
  initbox_state_set_value "MODULE_${key_prefix}_FAILED_AT" "$timestamp"
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
