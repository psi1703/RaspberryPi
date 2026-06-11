#!/usr/bin/env bash

# InitBox Raspberry Pi installer
#
# Loads a hardware profile, repairs required repo permissions, shows supported
# modules, runs sanity checks, and runs selected module scripts with explicit
# confirmation.
#
# Usage:
#   ./scripts/initbox-installer.sh pi-zero2w
#   ./scripts/initbox-installer.sh pi-3-4-5
#   ./scripts/initbox-installer.sh pi-zero2w c
#   ./scripts/initbox-installer.sh pi-3-4-5 c
#   ./scripts/initbox-installer.sh pi-zero2w uninstall

set -euo pipefail

REQUESTED_PROFILE_ID="${1:-}"
ACTION="${2:-menu}"

if [ -z "$REQUESTED_PROFILE_ID" ]; then
  echo "ERROR: profile id is required."
  echo
  echo "Usage:"
  echo "  ./scripts/initbox-installer.sh pi-zero2w"
  echo "  ./scripts/initbox-installer.sh pi-3-4-5"
  echo "  ./scripts/initbox-installer.sh pi-zero2w c"
  echo "  ./scripts/initbox-installer.sh pi-3-4-5 c"
  echo "  ./scripts/initbox-installer.sh pi-zero2w uninstall"
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

LOG_DIR="/var/log/initbox"
LOG_FILE="$LOG_DIR/install.log"
LEGACY_MODULE_LOG_DIR="/home/initbox/pi_logs"
LEGACY_MODULE_LOG_FILE="$LEGACY_MODULE_LOG_DIR/initbox-install.log"

PROFILE_ID=""
PROFILE_NAME=""
SUPPORTS_DASHBOARD=""
DEFAULT_MODULES=""
PRIMARY_MANAGEMENT_INTERFACE=""
MODULE_DASHBOARD=""
INITBOX_STATE_FILE="/etc/initbox/install-state.env"

bootstrap_repo_permissions() {
  local path
  local module_script
  local repo_dirs=()
  local readable_files=()
  local executable_files=()

  if [ "$(id -u)" -ne 0 ]; then
    return 0
  fi

  mkdir -p "$LOG_DIR"
  touch "$LOG_FILE"

  mkdir -p "$LEGACY_MODULE_LOG_DIR"
  touch "$LEGACY_MODULE_LOG_FILE"

  if id initbox >/dev/null 2>&1; then
    chown -R initbox:initbox "$LEGACY_MODULE_LOG_DIR" || true
  fi

  repo_dirs+=("$REPO_ROOT")
  repo_dirs+=("$REPO_ROOT/scripts")
  repo_dirs+=("$REPO_ROOT/scripts/lib")
  repo_dirs+=("$REPO_ROOT/scripts/pi-zero2w")
  repo_dirs+=("$REPO_ROOT/scripts/pi-3-4-5")
  repo_dirs+=("$REPO_ROOT/profiles")

  readable_files+=("$REPO_ROOT/scripts/lib/profile.sh")
  readable_files+=("$REPO_ROOT/scripts/lib/modules.sh")
  readable_files+=("$REPO_ROOT/scripts/lib/state.sh")
  readable_files+=("$REPO_ROOT/profiles/pi-zero2w.conf")
  readable_files+=("$REPO_ROOT/profiles/pi-3-4-5.conf")
  readable_files+=("$REPO_ROOT/profiles/README.md")
  readable_files+=("$REPO_ROOT/README.md")

  executable_files+=("$REPO_ROOT/scripts/initbox-installer.sh")
  executable_files+=("$REPO_ROOT/scripts/initbox-status.sh")

  for path in "${repo_dirs[@]}"; do
    if [ -d "$path" ]; then
      chmod 755 "$path"
    fi
  done

  for path in "${readable_files[@]}"; do
    if [ -f "$path" ]; then
      chmod 644 "$path"
    fi
  done

  for path in "${executable_files[@]}"; do
    if [ -f "$path" ]; then
      chmod 755 "$path"
    fi
  done

  for module_script in "$REPO_ROOT/scripts/pi-zero2w"/*.sh "$REPO_ROOT/scripts/pi-3-4-5"/*.sh; do
    if [ -f "$module_script" ]; then
      chmod 755 "$module_script"
    fi
  done
}

bootstrap_repo_permissions

# shellcheck disable=SC1091
. "$REPO_ROOT/scripts/lib/profile.sh"

# shellcheck disable=SC1091
. "$REPO_ROOT/scripts/lib/modules.sh"

# shellcheck disable=SC1091
. "$REPO_ROOT/scripts/lib/state.sh"

initbox_load_profile "$REQUESTED_PROFILE_ID"

SUPPORTED_MODULES=()

ensure_log_file() {
  if [ "$(id -u)" -eq 0 ]; then
    mkdir -p "$LOG_DIR"
    touch "$LOG_FILE"

    mkdir -p "$LEGACY_MODULE_LOG_DIR"
    touch "$LEGACY_MODULE_LOG_FILE"

    if id initbox >/dev/null 2>&1; then
      chown -R initbox:initbox "$LEGACY_MODULE_LOG_DIR" || true
    fi
  else
    echo "WARNING: not running as root. Log file may not be writable: $LOG_FILE"
    echo "WARNING: not running as root. Module log path may not be writable: $LEGACY_MODULE_LOG_FILE"
  fi
}

log_line() {
  local message="$1"
  local timestamp

  timestamp="$(date '+%Y-%m-%d %H:%M:%S')"

  if [ -w "$LOG_FILE" ]; then
    printf '[%s] %s\n' "$timestamp" "$message" >> "$LOG_FILE"
  fi
}

record_profile_state() {
  if [ "$(id -u)" -eq 0 ]; then
    initbox_state_record_profile "$PROFILE_ID" "$PROFILE_NAME" || true
  else
    log_line "STATE_SKIPPED not_root profile=$PROFILE_ID"
  fi
}

record_module_success_state() {
  local module_id="$1"
  local module_name="$2"

  if [ "$(id -u)" -eq 0 ]; then
    initbox_state_record_module_success "$module_id" "$module_name" || true
  else
    log_line "STATE_SKIPPED not_root module_id=$module_id status=success"
  fi
}

record_module_failure_state() {
  local module_id="$1"
  local module_name="$2"

  if [ "$(id -u)" -eq 0 ]; then
    initbox_state_record_module_failure "$module_id" "$module_name" || true
  else
    log_line "STATE_SKIPPED not_root module_id=$module_id status=failed"
  fi
}

record_module_uninstalled_state() {
  local module_id="$1"
  local module_name="$2"

  if [ "$(id -u)" -eq 0 ]; then
    if declare -F initbox_state_record_module_uninstalled >/dev/null 2>&1; then
      initbox_state_record_module_uninstalled "$module_id" "$module_name" || true
    else
      log_line "STATE_SKIPPED missing_uninstalled_helper module_id=$module_id"
    fi
  else
    log_line "STATE_SKIPPED not_root module_id=$module_id status=uninstalled"
  fi
}

pause() {
  echo
  echo "Press Enter to continue."
  read -r _
}

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

initbox_module_supports_uninstall() {
  local module_id="$1"

  case "$PROFILE_ID:$module_id" in
    pi-zero2w:web-terminal)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

print_header() {
  clear || true

  echo "InitBox Raspberry Pi Installer"
  echo "=============================="
  echo
  initbox_print_profile_summary
  echo

  echo "Lab setup reminder:"
  echo "  This installer is intended to run in the lab with Internet access."
  echo "  Field deployment should happen only after setup and verification."
  echo

  if [ "$(id -u)" -ne 0 ]; then
    echo "Root warning:"
    echo "  You are not running as root."
    echo "  Some module scripts may fail unless you run this installer with sudo."
    echo
  fi

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
  local uninstall_available

  uninstall_available="no"

  echo "Available install modules"
  echo "-------------------------"
  echo "Select a number to install or re-run that module."
  echo

  index=1
  for module_id in "${SUPPORTED_MODULES[@]}"; do
    module_name="$(initbox_module_display_name "$module_id")"

    if module_script="$(initbox_module_script_path "$PROFILE_ID" "$module_id" "$REPO_ROOT")"; then
      if [ -f "$module_script" ]; then
        printf '  %d) Install %-16s %s\n' "$index" "$module_name" "[script found]"
      else
        printf '  %d) Install %-16s %s\n' "$index" "$module_name" "[script missing]"
      fi
    else
      printf '  %d) Install %-16s %s\n' "$index" "$module_name" "[not mapped]"
    fi

    if initbox_module_supports_uninstall "$module_id"; then
      uninstall_available="yes"
    fi

    index=$((index + 1))
  done

  echo
  echo "Available actions"
  echo "-----------------"

  if [ "$uninstall_available" = "yes" ]; then
    echo "  u) Uninstall/remove module"
  fi

  echo "  c) Run sanity checks"
  echo "  l) Show install log path"
  echo "  s) Show install state"
  echo "  q) Quit"
  echo
}

show_log_info() {
  echo
  echo "Install log"
  echo "-----------"
  echo "$LOG_FILE"
  echo
  echo "Legacy module log"
  echo "-----------------"
  echo "$LEGACY_MODULE_LOG_FILE"
  echo

  if [ -f "$LOG_FILE" ]; then
    echo "Recent entries:"
    tail -n 20 "$LOG_FILE" || true
  else
    echo "Log file does not exist yet."
    echo "It will be created when running as root."
  fi
}

show_state_info() {
  echo
  initbox_state_print || true
}

sanity_pass() {
  printf '[PASS] %s\n' "$1"
}

sanity_fail() {
  printf '[FAIL] %s\n' "$1"
  return 1
}

sanity_check_file() {
  local path="$1"

  if [ -f "$REPO_ROOT/$path" ]; then
    sanity_pass "file exists: $path"
    return 0
  fi

  sanity_fail "missing file: $path"
  return 1
}

sanity_check_no_markdown_fences() {
  local path="$1"
  local file_path=""
  local backtick=""
  local markdown_fence=""

  file_path="$REPO_ROOT/$path"

  if [ ! -f "$file_path" ]; then
    return 0
  fi

  backtick="$(printf '\140')"
  markdown_fence="${backtick}${backtick}${backtick}"

  if grep -qF "$markdown_fence" "$file_path"; then
    sanity_fail "file contains Markdown fence error: $path"
    return 1
  fi

  sanity_pass "file has no error: $path"
  return 0
}

sanity_check_profile_value() {
  local label="$1"
  local value="$2"

  if [ -n "$value" ]; then
    sanity_pass "$label is set"
    return 0
  fi

  sanity_fail "$label is missing"
  return 1
}

sanity_check_module_script() {
  local module_id="$1"
  local module_name
  local module_script

  module_name="$(initbox_module_display_name "$module_id")"

  if ! initbox_profile_supports_module "$module_id"; then
    sanity_pass "module blocked by profile: $module_id ($module_name)"
    return 0
  fi

  if ! module_script="$(initbox_module_script_path "$PROFILE_ID" "$module_id" "$REPO_ROOT")"; then
    sanity_fail "supported module has no script mapping: $module_id ($module_name)"
    return 1
  fi

  if [ -f "$module_script" ]; then
    sanity_pass "supported module script exists: $module_id ($module_name)"
    return 0
  fi

  sanity_fail "supported module script missing: $module_id ($module_name) -> $module_script"
  return 1
}

run_shellcheck_if_available() {
  local shellcheck_failures
  local path
  local shellcheck_files=()

  shellcheck_failures=0

  if ! command -v shellcheck >/dev/null 2>&1; then
    echo
    echo "ShellCheck"
    echo "----------"
    echo "ShellCheck is not installed. Skipping ShellCheck validation."
    return 0
  fi

  shellcheck_files+=("$REPO_ROOT/scripts/initbox-installer.sh")
  shellcheck_files+=("$REPO_ROOT/scripts/initbox-status.sh")
  shellcheck_files+=("$REPO_ROOT/scripts/lib/profile.sh")
  shellcheck_files+=("$REPO_ROOT/scripts/lib/modules.sh")
  shellcheck_files+=("$REPO_ROOT/scripts/lib/state.sh")

  echo
  echo "ShellCheck"
  echo "----------"

  for path in "${shellcheck_files[@]}"; do
    if [ -f "$path" ]; then
      if shellcheck "$path"; then
        sanity_pass "shellcheck passed: ${path#"$REPO_ROOT/"}"
      else
        shellcheck_failures=$((shellcheck_failures + 1))
      fi
    fi
  done

  if [ "$shellcheck_failures" -eq 0 ]; then
    return 0
  fi

  return 1
}

run_sanity_checks() {
  local failures
  local module_id

  failures=0

  echo
  echo "InitBox sanity checks"
  echo "====================="
  echo
  echo "Repository root:"
  echo "$REPO_ROOT"
  echo

  bootstrap_repo_permissions

  sanity_check_file "README.md" || failures=$((failures + 1))

  sanity_check_file "profiles/README.md" || failures=$((failures + 1))
  sanity_check_file "profiles/pi-zero2w.conf" || failures=$((failures + 1))
  sanity_check_file "profiles/pi-3-4-5.conf" || failures=$((failures + 1))

  sanity_check_file "scripts/initbox-installer.sh" || failures=$((failures + 1))
  sanity_check_file "scripts/initbox-status.sh" || failures=$((failures + 1))
  sanity_check_file "scripts/lib/profile.sh" || failures=$((failures + 1))
  sanity_check_file "scripts/lib/modules.sh" || failures=$((failures + 1))
  sanity_check_file "scripts/lib/state.sh" || failures=$((failures + 1))

  sanity_check_no_markdown_fences "scripts/initbox-installer.sh" || failures=$((failures + 1))
  sanity_check_no_markdown_fences "scripts/initbox-status.sh" || failures=$((failures + 1))
  sanity_check_no_markdown_fences "scripts/lib/profile.sh" || failures=$((failures + 1))
  sanity_check_no_markdown_fences "scripts/lib/modules.sh" || failures=$((failures + 1))
  sanity_check_no_markdown_fences "scripts/lib/state.sh" || failures=$((failures + 1))

  echo
  echo "Loaded profile checks"
  echo "---------------------"

  sanity_check_profile_value "PROFILE_ID" "${PROFILE_ID:-}" || failures=$((failures + 1))
  sanity_check_profile_value "PROFILE_NAME" "${PROFILE_NAME:-}" || failures=$((failures + 1))
  sanity_check_profile_value "DEFAULT_MODULES" "${DEFAULT_MODULES:-}" || failures=$((failures + 1))
  sanity_check_profile_value "PRIMARY_MANAGEMENT_INTERFACE" "${PRIMARY_MANAGEMENT_INTERFACE:-}" || failures=$((failures + 1))

  if [ "$PROFILE_ID" = "pi-zero2w" ]; then
    if [ "${SUPPORTS_DASHBOARD:-}" = "no" ] && [ "${MODULE_DASHBOARD:-}" = "no" ]; then
      sanity_pass "Pi Zero 2W dashboard is blocked"
    else
      sanity_fail "Pi Zero 2W dashboard must be blocked"
      failures=$((failures + 1))
    fi

    if initbox_profile_supports_module "dashboard"; then
      sanity_fail "Pi Zero 2W profile incorrectly supports dashboard"
      failures=$((failures + 1))
    else
      sanity_pass "Pi Zero 2W dashboard does not appear as supported module"
    fi

    if initbox_profile_supports_module "web-terminal"; then
      sanity_pass "Pi Zero 2W supports Web Terminal"
    else
      sanity_fail "Pi Zero 2W must support Web Terminal"
      failures=$((failures + 1))
    fi
  fi

  echo
  echo "Module mapping checks"
  echo "---------------------"

  while IFS= read -r module_id; do
    [ -z "$module_id" ] && continue
    sanity_check_module_script "$module_id" || failures=$((failures + 1))
  done < <(initbox_all_known_modules)

  if ! run_shellcheck_if_available; then
    failures=$((failures + 1))
  fi

  echo
  echo "Summary"
  echo "-------"

  if [ "$failures" -eq 0 ]; then
    echo "All sanity checks passed."
    log_line "SANITY_CHECKS_PASSED profile=$PROFILE_ID"
    return 0
  fi

  echo "Sanity checks failed: $failures"
  log_line "SANITY_CHECKS_FAILED profile=$PROFILE_ID failures=$failures"
  return 1
}

confirm_module_action() {
  local action="$1"
  local module_name="$2"
  local module_script="$3"
  local confirmation_word="$4"
  local confirmation

  echo
  echo "Ready to ${action} module"
  echo "-------------------------"
  echo "Profile: $PROFILE_ID"
  echo "Module:  $module_name"
  echo "Script:  $module_script"
  echo "Log:     $LOG_FILE"
  echo "State:   ${INITBOX_STATE_FILE:-/etc/initbox/install-state.env}"
  echo

  case "$action" in
    install)
      echo "This may install packages, modify system configuration, enable services, or require reboot."
      echo "Only continue if this Pi is in the lab with Internet access."
      ;;
    uninstall)
      echo "This will remove services and files created by this module."
      echo "It will not remove shared packages."
      ;;
    purge)
      echo "This will remove services and files created by this module."
      echo "It may also remove module-owned binaries or files."
      ;;
    *)
      echo "This will run module action: $action"
      ;;
  esac

  echo
  printf 'Type %s to continue, or anything else to cancel: ' "$confirmation_word"
  read -r confirmation

  if [ "$confirmation" != "$confirmation_word" ]; then
    echo
    echo "Cancelled. No action has been performed."
    log_line "CANCELLED action=$action profile=$PROFILE_ID module=$module_name script=$module_script"
    return 1
  fi

  return 0
}

confirm_run() {
  local module_name="$1"
  local module_script="$2"

  confirm_module_action "install" "$module_name" "$module_script" "RUN"
}

run_module_install() {
  local module_script="$1"

  bash "$module_script"
}

run_module_action() {
  local module_script="$1"
  local module_action="$2"

  case "$module_action" in
    install)
      run_module_install "$module_script"
      ;;
    uninstall|remove|purge)
      bash "$module_script" "$module_action"
      ;;
    *)
      bash "$module_script" "$module_action"
      ;;
  esac
}

run_module_script() {
  local module_id="$1"
  local module_name="$2"
  local module_script="$3"
  local module_action="${4:-install}"

  echo
  echo "Running module script..."
  echo "------------------------"
  echo "Action: $module_action"
  echo "Script: $module_script"
  echo

  log_line "START action=$module_action profile=$PROFILE_ID module_id=$module_id module_name=$module_name script=$module_script"

  if [ -w "$LOG_FILE" ]; then
    if run_module_action "$module_script" "$module_action" 2>&1 | tee -a "$LOG_FILE"; then
      log_line "SUCCESS action=$module_action profile=$PROFILE_ID module_id=$module_id module_name=$module_name"

      case "$module_action" in
        install)
          record_module_success_state "$module_id" "$module_name"
          ;;
        uninstall|remove|purge)
          record_module_uninstalled_state "$module_id" "$module_name"
          ;;
      esac

      echo
      echo "Module script completed successfully."
    else
      log_line "FAILED action=$module_action profile=$PROFILE_ID module_id=$module_id module_name=$module_name"
      record_module_failure_state "$module_id" "$module_name"
      echo
      echo "ERROR: module script failed. Check log: $LOG_FILE"
      return 1
    fi
  else
    echo "WARNING: log file is not writable. Running without log capture."

    if run_module_action "$module_script" "$module_action"; then
      case "$module_action" in
        install)
          record_module_success_state "$module_id" "$module_name"
          ;;
        uninstall|remove|purge)
          record_module_uninstalled_state "$module_id" "$module_name"
          ;;
      esac

      echo
      echo "Module script completed successfully."
    else
      record_module_failure_state "$module_id" "$module_name"
      echo
      echo "ERROR: module script failed."
      return 1
    fi
  fi
}

handle_selection() {
  local selected_index="$1"
  local module_id
  local module_name
  local module_script

  module_id="${SUPPORTED_MODULES[$((selected_index - 1))]}"
  module_name="$(initbox_module_display_name "$module_id")"

  echo
  echo "Selected install module"
  echo "-----------------------"
  echo "Module ID:   $module_id"
  echo "Module name: $module_name"

  initbox_require_supported_module "$module_id"

  if ! module_script="$(initbox_module_script_path "$PROFILE_ID" "$module_id" "$REPO_ROOT")"; then
    echo "ERROR: no script mapping exists for module '$module_id' on profile '$PROFILE_ID'."
    log_line "ERROR no_mapping profile=$PROFILE_ID module_id=$module_id"
    exit 1
  fi

  echo "Script:      $module_script"

  if [ ! -f "$module_script" ]; then
    echo
    echo "ERROR: module script is missing."
    echo "No installation has been performed."
    log_line "ERROR missing_script profile=$PROFILE_ID module_id=$module_id script=$module_script"
    exit 1
  fi

  if confirm_run "$module_name" "$module_script"; then
    run_module_script "$module_id" "$module_name" "$module_script" "install"
  fi
}

print_uninstall_menu() {
  local index
  local module_id
  local module_name
  local module_script

  echo
  echo "Available uninstall modules"
  echo "---------------------------"

  index=1
  for module_id in "${SUPPORTED_MODULES[@]}"; do
    if ! initbox_module_supports_uninstall "$module_id"; then
      continue
    fi

    module_name="$(initbox_module_display_name "$module_id")"

    if module_script="$(initbox_module_script_path "$PROFILE_ID" "$module_id" "$REPO_ROOT")"; then
      if [ -f "$module_script" ]; then
        printf '  %d) Remove %-16s %s\n' "$index" "$module_name" "[script found]"
      else
        printf '  %d) Remove %-16s %s\n' "$index" "$module_name" "[script missing]"
      fi
    else
      printf '  %d) Remove %-16s %s\n' "$index" "$module_name" "[not mapped]"
    fi

    index=$((index + 1))
  done

  echo "  b) Back"
  echo
}

get_uninstall_module_by_index() {
  local requested_index="$1"
  local index
  local module_id

  index=1

  for module_id in "${SUPPORTED_MODULES[@]}"; do
    if ! initbox_module_supports_uninstall "$module_id"; then
      continue
    fi

    if [ "$index" -eq "$requested_index" ]; then
      printf '%s\n' "$module_id"
      return 0
    fi

    index=$((index + 1))
  done

  return 1
}

count_uninstall_modules() {
  local count
  local module_id

  count=0

  for module_id in "${SUPPORTED_MODULES[@]}"; do
    if initbox_module_supports_uninstall "$module_id"; then
      count=$((count + 1))
    fi
  done

  printf '%s\n' "$count"
}

handle_uninstall_selection() {
  local selected_index="$1"
  local module_id
  local module_name
  local module_script
  local uninstall_action

  if ! module_id="$(get_uninstall_module_by_index "$selected_index")"; then
    echo
    echo "Invalid uninstall choice: $selected_index"
    return 1
  fi

  module_name="$(initbox_module_display_name "$module_id")"

  echo
  echo "Selected uninstall module"
  echo "-------------------------"
  echo "Module ID:   $module_id"
  echo "Module name: $module_name"

  initbox_require_supported_module "$module_id"

  if ! initbox_module_supports_uninstall "$module_id"; then
    echo "ERROR: module '$module_id' does not support uninstall yet."
    log_line "ERROR uninstall_not_supported profile=$PROFILE_ID module_id=$module_id"
    return 1
  fi

  if ! module_script="$(initbox_module_script_path "$PROFILE_ID" "$module_id" "$REPO_ROOT")"; then
    echo "ERROR: no script mapping exists for module '$module_id' on profile '$PROFILE_ID'."
    log_line "ERROR no_mapping profile=$PROFILE_ID module_id=$module_id"
    return 1
  fi

  echo "Script:      $module_script"

  if [ ! -f "$module_script" ]; then
    echo
    echo "ERROR: module script is missing."
    echo "No uninstall has been performed."
    log_line "ERROR missing_script profile=$PROFILE_ID module_id=$module_id script=$module_script"
    return 1
  fi

  echo
  echo "Uninstall mode"
  echo "--------------"
  echo "  1) Uninstall services/config created by this module"
  echo "  2) Purge module-owned binary/files too"
  echo "  b) Back"
  echo
  printf 'Select uninstall mode [1-2] or b: '
  read -r uninstall_action

  uninstall_action="${uninstall_action//$'\r'/}"

  case "$uninstall_action" in
    1)
      if confirm_module_action "uninstall" "$module_name" "$module_script" "REMOVE"; then
        run_module_script "$module_id" "$module_name" "$module_script" "uninstall"
      fi
      ;;
    2)
      if confirm_module_action "purge" "$module_name" "$module_script" "PURGE"; then
        run_module_script "$module_id" "$module_name" "$module_script" "purge"
      fi
      ;;
    b|B)
      return 0
      ;;
    *)
      echo
      echo "Invalid uninstall mode: $uninstall_action"
      return 1
      ;;
  esac
}

handle_uninstall_menu() {
  local choice
  local max_choice

  max_choice="$(count_uninstall_modules)"

  if [ "$max_choice" -eq 0 ]; then
    echo
    echo "No modules currently support uninstall for this profile."
    return 0
  fi

  print_uninstall_menu

  printf 'Select uninstall module [1-%s] or b: ' "$max_choice"
  read -r choice

  choice="${choice//$'\r'/}"

  case "$choice" in
    b|B)
      return 0
      ;;
    ''|*[!0-9]*)
      echo
      echo "Invalid choice: $choice"
      return 1
      ;;
    *)
      if [ "$choice" -ge 1 ] && [ "$choice" -le "$max_choice" ]; then
        handle_uninstall_selection "$choice"
      else
        echo
        echo "Invalid choice: $choice"
        return 1
      fi
      ;;
  esac
}

interactive_menu() {
  local choice
  local max_choice

  while true; do
    print_header
    print_menu

    max_choice="${#SUPPORTED_MODULES[@]}"

    printf 'Select install module [1-%s], u to uninstall, c for checks, l for log, s for state, or q: ' "$max_choice"
    read -r choice

    choice="${choice//$'\r'/}"

    case "$choice" in
      q|Q)
        echo "Quit."
        log_line "INSTALLER_CLOSED profile=$PROFILE_ID"
        exit 0
        ;;
      u|U)
        handle_uninstall_menu || true
        pause
        ;;
      c|C)
        run_sanity_checks || true
        pause
        ;;
      l|L)
        show_log_info
        pause
        ;;
      s|S)
        show_state_info
        pause
        ;;
      ''|*[!0-9]*)
        echo
        echo "Invalid choice: $choice"
        pause
        ;;
      *)
        if [ "$choice" -ge 1 ] && [ "$choice" -le "$max_choice" ]; then
          handle_selection "$choice"
          pause
        else
          echo
          echo "Invalid choice: $choice"
          pause
        fi
        ;;
    esac
  done
}

main() {
  ensure_log_file
  build_supported_module_list
  record_profile_state

  log_line "INSTALLER_OPENED profile=$PROFILE_ID"

  if [ "${#SUPPORTED_MODULES[@]}" -eq 0 ]; then
    echo "ERROR: no supported modules found for profile '$PROFILE_ID'."
    log_line "ERROR no_supported_modules profile=$PROFILE_ID"
    exit 1
  fi

  case "$ACTION" in
    menu|"")
      interactive_menu
      ;;
    u|U|uninstall|remove)
      handle_uninstall_menu
      ;;
    c|C|check|checks|sanity)
      run_sanity_checks
      ;;
    l|L|log|logs)
      show_log_info
      ;;
    s|S|state)
      show_state_info
      ;;
    *)
      echo "ERROR: unknown action: $ACTION"
      echo
      echo "Usage:"
      echo "  ./scripts/initbox-installer.sh pi-zero2w"
      echo "  ./scripts/initbox-installer.sh pi-3-4-5"
      echo "  ./scripts/initbox-installer.sh pi-zero2w c"
      echo "  ./scripts/initbox-installer.sh pi-3-4-5 c"
      echo "  ./scripts/initbox-installer.sh pi-zero2w uninstall"
      exit 1
      ;;
  esac
}

main "$@"
