```bash
#!/usr/bin/env bash
# InitBox Raspberry Pi installer
#
# Loads a hardware profile, shows supported modules,
# and runs selected module scripts with explicit confirmation.
#
# Usage:
#   ./scripts/initbox-installer.sh pi-zero2w
#   ./scripts/initbox-installer.sh pi-3-4-5
#
# Lab model:
#   Raspberry Pi devices are configured in the lab while Internet access
#   is available. Field deployment assumes setup is already complete.

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

LOG_DIR="/var/log/initbox"
LOG_FILE="$LOG_DIR/install.log"

# shellcheck source=lib/profile.sh
. "$REPO_ROOT/scripts/lib/profile.sh"

# shellcheck source=lib/modules.sh
. "$REPO_ROOT/scripts/lib/modules.sh"

initbox_load_profile "$PROFILE_ID"

SUPPORTED_MODULES=()

ensure_log_file() {
  if [ "$(id -u)" -eq 0 ]; then
    mkdir -p "$LOG_DIR"
    touch "$LOG_FILE"
  else
    echo "WARNING: not running as root. Log file may not be writable: $LOG_FILE"
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

  echo "  l) Show install log path"
  echo "  q) Quit"
  echo
}

show_log_info() {
  echo
  echo "Install log"
  echo "-----------"
  echo "$LOG_FILE"
  echo

  if [ -f "$LOG_FILE" ]; then
    echo "Recent entries:"
    tail -n 20 "$LOG_FILE" || true
  else
    echo "Log file does not exist yet."
    echo "It will be created when running as root."
  fi
}

confirm_run() {
  local module_name="$1"
  local module_script="$2"
  local confirmation

  echo
  echo "Ready to run module"
  echo "-------------------"
  echo "Profile: $PROFILE_ID"
  echo "Module:  $module_name"
  echo "Script:  $module_script"
  echo "Log:     $LOG_FILE"
  echo
  echo "This may install packages, modify system configuration, enable services, or require reboot."
  echo "Only continue if this Pi is in the lab with Internet access."
  echo
  printf 'Type RUN to continue, or anything else to cancel: '
  read -r confirmation

  if [ "$confirmation" != "RUN" ]; then
    echo
    echo "Cancelled. No installation has been performed."
    log_line "CANCELLED profile=$PROFILE_ID module=$module_name script=$module_script"
    return 1
  fi

  return 0
}

run_module_script() {
  local module_id="$1"
  local module_name="$2"
  local module_script="$3"

  echo
  echo "Running module script..."
  echo "------------------------"
  echo "$module_script"
  echo

  log_line "START profile=$PROFILE_ID module_id=$module_id module_name=$module_name script=$module_script"

  if [ -w "$LOG_FILE" ]; then
    if bash "$module_script" 2>&1 | tee -a "$LOG_FILE"; then
      log_line "SUCCESS profile=$PROFILE_ID module_id=$module_id module_name=$module_name"
      echo
      echo "Module script completed successfully."
    else
      log_line "FAILED profile=$PROFILE_ID module_id=$module_id module_name=$module_name"
      echo
      echo "ERROR: module script failed. Check log: $LOG_FILE"
      return 1
    fi
  else
    echo "WARNING: log file is not writable. Running without log capture."
    if bash "$module_script"; then
      echo
      echo "Module script completed successfully."
    else
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
  echo "Selected module"
  echo "---------------"
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
    run_module_script "$module_id" "$module_name" "$module_script"
  fi
}

main() {
  local choice
  local max_choice

  ensure_log_file
  build_supported_module_list

  log_line "INSTALLER_OPENED profile=$PROFILE_ID"

  if [ "${#SUPPORTED_MODULES[@]}" -eq 0 ]; then
    echo "ERROR: no supported modules found for profile '$PROFILE_ID'."
    log_line "ERROR no_supported_modules profile=$PROFILE_ID"
    exit 1
  fi

  while true; do
    print_header
    print_menu

    max_choice="${#SUPPORTED_MODULES[@]}"

    printf 'Select a module [1-%s], l for log, or q: ' "$max_choice"
    read -r choice

    case "$choice" in
      q|Q)
        echo "Quit."
        log_line "INSTALLER_CLOSED profile=$PROFILE_ID"
        exit 0
        ;;
      l|L)
        show_log_info
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

main
```
