#!/usr/bin/env bash

# InitBox Raspberry Pi installer
# Loads a hardware profile, repairs required repo permissions, shows supported
# modules, runs sanity checks, handles offline package preseed, and runs selected
# module scripts with explicit confirmation.
#
# Usage:
#   ./scripts/initbox-installer.sh pi-zero2w
#   ./scripts/initbox-installer.sh pi-zero2w c
#   ./scripts/initbox-installer.sh pi-zero2w p
#   ./scripts/initbox-installer.sh pi-zero2w v
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
  echo "  ./scripts/initbox-installer.sh pi-zero2w p"
  echo "  ./scripts/initbox-installer.sh pi-zero2w v"
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

PACKAGES_FILE="$REPO_ROOT/scripts/packages.txt"
PACKAGES_LIB_FILE="$REPO_ROOT/scripts/lib/packages.sh"
PACKAGE_CACHE_DIR="/opt/initbox/packages"

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
  repo_dirs+=("$REPO_ROOT/profiles")

  readable_files+=("$REPO_ROOT/scripts/packages.txt")
  readable_files+=("$REPO_ROOT/scripts/lib/profile.sh")
  readable_files+=("$REPO_ROOT/scripts/lib/modules.sh")
  readable_files+=("$REPO_ROOT/scripts/lib/state.sh")
  readable_files+=("$REPO_ROOT/scripts/lib/packages.sh")
  readable_files+=("$REPO_ROOT/profiles/pi-zero2w.conf")
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

# -----------------------------------------------------------------------------
# Early privilege and baseline package bootstrap
# -----------------------------------------------------------------------------

is_system_action() {
  case "$ACTION" in
    menu|""|u|U|uninstall|remove|p|P|preseed|packages|v|V|verify|verify-packages|baseline|upgrade)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

detect_operator_user() {
  local candidate=""

  candidate="${INITBOX_SUDO_USER:-}"

  if [ -z "$candidate" ] && [ -n "${SUDO_USER:-}" ] && [ "${SUDO_USER:-}" != "root" ]; then
    candidate="$SUDO_USER"
  fi

  if [ -z "$candidate" ] && [ -n "${USER:-}" ] && [ "${USER:-}" != "root" ]; then
    candidate="$USER"
  fi

  if [ -z "$candidate" ] && id initbox >/dev/null 2>&1; then
    candidate="initbox"
  fi

  if [ -z "$candidate" ]; then
    return 1
  fi

  if ! id "$candidate" >/dev/null 2>&1; then
    return 1
  fi

  printf '%s\n' "$candidate"
}

require_root_for_system_action() {
  if ! is_system_action; then
    return 0
  fi

  if [ "$(id -u)" -eq 0 ]; then
    return 0
  fi

  echo "ERROR: this installer action must run as root."
  echo
  echo "Run:"
  echo "  sudo ./scripts/initbox-installer.sh $REQUESTED_PROFILE_ID $ACTION"
  exit 1
}

ensure_passwordless_sudo() {
  local sudo_user=""
  local sudoers_file=""

  if ! is_system_action; then
    return 0
  fi

  if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: passwordless sudo bootstrap must run as root."
    echo
    echo "Run:"
    echo "  sudo ./scripts/initbox-installer.sh $REQUESTED_PROFILE_ID $ACTION"
    exit 1
  fi

  if ! sudo_user="$(detect_operator_user)"; then
    echo "ERROR: could not determine operator user for passwordless sudo."
    echo "Set INITBOX_SUDO_USER=<username> and rerun with sudo."
    exit 1
  fi

  sudoers_file="/etc/sudoers.d/010-initbox-${sudo_user}"

  echo "Granting passwordless sudo to user: ${sudo_user}"
  log_line "SUDO_BOOTSTRAP_START user=${sudo_user} file=${sudoers_file}"

  install -d -m 0755 /etc/sudoers.d
  printf '%s ALL=(ALL) NOPASSWD:ALL\n' "$sudo_user" >"$sudoers_file"
  chmod 0440 "$sudoers_file"

  if command -v visudo >/dev/null 2>&1; then
    if ! visudo -cf "$sudoers_file" >/dev/null; then
      rm -f "$sudoers_file"
      echo "ERROR: generated sudoers file failed validation; removed: $sudoers_file"
      log_line "SUDO_BOOTSTRAP_FAILED user=${sudo_user} reason=visudo"
      exit 1
    fi
  fi

  log_line "SUDO_BOOTSTRAP_DONE user=${sudo_user} file=${sudoers_file}"
}

run_baseline_apt_update_upgrade() {
  if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: baseline apt-get update/upgrade must run as root."
    exit 1
  fi

  echo
  echo "Baseline package update"
  echo "-----------------------"
  echo "Running apt-get update."
  log_line "BASELINE_APT_UPDATE_START profile=$PROFILE_ID"

  if ! apt-get -o Dpkg::Use-Pty=0 -o Acquire::Retries=5 update 2>&1 | tee -a "$LOG_FILE"; then
    log_line "BASELINE_APT_UPDATE_FAILED profile=$PROFILE_ID"
    echo "ERROR: baseline apt-get update failed. Check log: $LOG_FILE"
    exit 1
  fi

  echo
  echo "Running apt-get upgrade."
  log_line "BASELINE_APT_UPGRADE_START profile=$PROFILE_ID"

  export DEBIAN_FRONTEND=noninteractive

  if ! apt-get -o Dpkg::Use-Pty=0 -o Acquire::Retries=5 upgrade -y 2>&1 | tee -a "$LOG_FILE"; then
    log_line "BASELINE_APT_UPGRADE_FAILED profile=$PROFILE_ID"
    echo "ERROR: baseline apt-get upgrade failed. Check log: $LOG_FILE"
    exit 1
  fi

  log_line "BASELINE_APT_DONE profile=$PROFILE_ID"
}

load_package_helper() {
  if [ ! -f "$PACKAGES_LIB_FILE" ]; then
    echo "ERROR: package helper is missing:"
    echo "  $PACKAGES_LIB_FILE"
    echo
    echo "Create scripts/lib/packages.sh before using package preseed or verification."
    return 1
  fi

  # shellcheck disable=SC1090
  . "$PACKAGES_LIB_FILE"
}

run_package_preseed() {
  echo
  echo "Offline package preseed"
  echo "-----------------------"
  echo "Packages file: $PACKAGES_FILE"
  echo "Cache dir:     $PACKAGE_CACHE_DIR"
  echo

  if [ "$PROFILE_ID" != "pi-zero2w" ]; then
    echo "ERROR: package preseed is currently intended for the Pi Zero W / Zero 2W profile."
    return 1
  fi

  if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: package preseed must run as root."
    return 1
  fi

  if [ ! -f "$PACKAGES_FILE" ]; then
    echo "ERROR: packages file is missing:"
    echo "  $PACKAGES_FILE"
    return 1
  fi

  load_package_helper

  if ! declare -F initbox_packages_preseed >/dev/null 2>&1; then
    echo "ERROR: scripts/lib/packages.sh must define initbox_packages_preseed."
    return 1
  fi

  log_line "PACKAGE_PRESEED_START profile=$PROFILE_ID packages_file=$PACKAGES_FILE cache_dir=$PACKAGE_CACHE_DIR"

  if initbox_packages_preseed "$PACKAGES_FILE" "$PACKAGE_CACHE_DIR" 2>&1 | tee -a "$LOG_FILE"; then
    log_line "PACKAGE_PRESEED_DONE profile=$PROFILE_ID packages_file=$PACKAGES_FILE cache_dir=$PACKAGE_CACHE_DIR"
    echo
    echo "Package preseed completed."
    return 0
  fi

  log_line "PACKAGE_PRESEED_FAILED profile=$PROFILE_ID packages_file=$PACKAGES_FILE cache_dir=$PACKAGE_CACHE_DIR"
  echo
  echo "ERROR: package preseed failed. Check log: $LOG_FILE"
  return 1
}

run_package_verify() {
  echo
  echo "Offline package cache verification"
  echo "----------------------------------"
  echo "Packages file: $PACKAGES_FILE"
  echo "Cache dir:     $PACKAGE_CACHE_DIR"
  echo

  if [ "$PROFILE_ID" != "pi-zero2w" ]; then
    echo "ERROR: package cache verification is currently intended for the Pi Zero W / Zero 2W profile."
    return 1
  fi

  if [ ! -f "$PACKAGES_FILE" ]; then
    echo "ERROR: packages file is missing:"
    echo "  $PACKAGES_FILE"
    return 1
  fi

  load_package_helper

  if ! declare -F initbox_packages_verify >/dev/null 2>&1; then
    echo "ERROR: scripts/lib/packages.sh must define initbox_packages_verify."
    return 1
  fi

  log_line "PACKAGE_VERIFY_START profile=$PROFILE_ID packages_file=$PACKAGES_FILE cache_dir=$PACKAGE_CACHE_DIR"

  if initbox_packages_verify "$PACKAGES_FILE" "$PACKAGE_CACHE_DIR" 2>&1 | tee -a "$LOG_FILE"; then
    log_line "PACKAGE_VERIFY_DONE profile=$PROFILE_ID packages_file=$PACKAGES_FILE cache_dir=$PACKAGE_CACHE_DIR"
    echo
    echo "Offline package cache verification passed."
    return 0
  fi

  log_line "PACKAGE_VERIFY_FAILED profile=$PROFILE_ID packages_file=$PACKAGES_FILE cache_dir=$PACKAGE_CACHE_DIR"
  echo
  echo "ERROR: offline package cache verification failed. Check log: $LOG_FILE"
  return 1
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
    pi-zero2w:isi|pi-zero2w:fms|pi-zero2w:hotspot|pi-zero2w:web-terminal|pi-zero2w:sniffer-bridge)
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

  echo "Lab / field package model:"
  echo "  Lab mode: run package preseed while Internet is available."
  echo "  Field mode: install modules from the local package cache."
  echo "  Package list: $PACKAGES_FILE"
  echo "  Package cache: $PACKAGE_CACHE_DIR"
  echo

  if [ "$(id -u)" -ne 0 ]; then
    echo "Root warning:"
    echo "  You are not running as root."
    echo "  Package preseed and module scripts may fail unless you run this installer with sudo."
    echo
  fi

  if [ "$PROFILE_ID" = "pi-zero2w" ]; then
    echo "Pi Zero W / Zero 2W policy:"
    echo "  Dashboard is intentionally disabled for this profile."
    echo "  Use Web Terminal instead."
    echo "  Module uninstall does not purge shared packages."
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
  echo "  p) Preseed/download package cache"
  echo "  v) Verify offline package cache"
  echo "  b) Run baseline apt-get update/upgrade"

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

  sanity_pass "file has no Markdown fence error: $path"
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

sanity_check_package_file() {
  local package_count

  if [ ! -f "$PACKAGES_FILE" ]; then
    sanity_fail "missing package list: scripts/packages.txt"
    return 1
  fi

  if [ ! -s "$PACKAGES_FILE" ]; then
    sanity_fail "package list is empty: scripts/packages.txt"
    return 1
  fi

  package_count="$(
    grep -Ec '^[[:space:]]*[^[:space:]#]' "$PACKAGES_FILE" || true
  )"

  if [ "$package_count" -gt 0 ]; then
    sanity_pass "package list has packages: scripts/packages.txt ($package_count)"
    return 0
  fi

  sanity_fail "package list has no active package names: scripts/packages.txt"
  return 1
}

sanity_check_package_helper() {
  if [ ! -f "$PACKAGES_LIB_FILE" ]; then
    sanity_fail "missing package helper: scripts/lib/packages.sh"
    return 1
  fi

  # shellcheck disable=SC1090
  . "$PACKAGES_LIB_FILE"

  if ! declare -F initbox_packages_preseed >/dev/null 2>&1; then
    sanity_fail "package helper missing function: initbox_packages_preseed"
    return 1
  fi

  if ! declare -F initbox_packages_verify >/dev/null 2>&1; then
    sanity_fail "package helper missing function: initbox_packages_verify"
    return 1
  fi

  if ! declare -F initbox_packages_install >/dev/null 2>&1; then
    sanity_fail "package helper missing function: initbox_packages_install"
    return 1
  fi

  sanity_pass "package helper functions exist: scripts/lib/packages.sh"
  return 0
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
  shellcheck_files+=("$REPO_ROOT/scripts/lib/packages.sh")

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

  sanity_check_file "scripts/packages.txt" || failures=$((failures + 1))
  sanity_check_file "scripts/initbox-installer.sh" || failures=$((failures + 1))
  sanity_check_file "scripts/initbox-status.sh" || failures=$((failures + 1))
  sanity_check_file "scripts/lib/profile.sh" || failures=$((failures + 1))
  sanity_check_file "scripts/lib/modules.sh" || failures=$((failures + 1))
  sanity_check_file "scripts/lib/state.sh" || failures=$((failures + 1))
  sanity_check_file "scripts/lib/packages.sh" || failures=$((failures + 1))

  sanity_check_no_markdown_fences "scripts/packages.txt" || failures=$((failures + 1))
  sanity_check_no_markdown_fences "scripts/initbox-installer.sh" || failures=$((failures + 1))
  sanity_check_no_markdown_fences "scripts/initbox-status.sh" || failures=$((failures + 1))
  sanity_check_no_markdown_fences "scripts/lib/profile.sh" || failures=$((failures + 1))
  sanity_check_no_markdown_fences "scripts/lib/modules.sh" || failures=$((failures + 1))
  sanity_check_no_markdown_fences "scripts/lib/state.sh" || failures=$((failures + 1))
  sanity_check_no_markdown_fences "scripts/lib/packages.sh" || failures=$((failures + 1))

  sanity_check_package_file || failures=$((failures + 1))
  sanity_check_package_helper || failures=$((failures + 1))

  echo
  echo "Loaded profile checks"
  echo "---------------------"

  sanity_check_profile_value "PROFILE_ID" "${PROFILE_ID:-}" || failures=$((failures + 1))
  sanity_check_profile_value "PROFILE_NAME" "${PROFILE_NAME:-}" || failures=$((failures + 1))
  sanity_check_profile_value "DEFAULT_MODULES" "${DEFAULT_MODULES:-}" || failures=$((failures + 1))
  sanity_check_profile_value "PRIMARY_MANAGEMENT_INTERFACE" "${PRIMARY_MANAGEMENT_INTERFACE:-}" || failures=$((failures + 1))

  if [ "$PROFILE_ID" = "pi-zero2w" ]; then
    if [ "${SUPPORTS_DASHBOARD:-}" = "no" ] && [ "${MODULE_DASHBOARD:-}" = "no" ]; then
      sanity_pass "Pi Zero W / Zero 2W dashboard is blocked"
    else
      sanity_fail "Pi Zero W / Zero 2W dashboard must be blocked"
      failures=$((failures + 1))
    fi

    if initbox_profile_supports_module "dashboard"; then
      sanity_fail "Pi Zero W / Zero 2W profile incorrectly supports dashboard"
      failures=$((failures + 1))
    else
      sanity_pass "Pi Zero W / Zero 2W dashboard does not appear as supported module"
    fi

    if initbox_profile_supports_module "web-terminal"; then
      sanity_pass "Pi Zero W / Zero 2W supports Web Terminal"
    else
      sanity_fail "Pi Zero W / Zero 2W must support Web Terminal"
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
      echo "This may install packages from the local package cache, modify system configuration, enable services, or require reboot."
      echo "Run package preseed first while Internet is available."
      ;;
    uninstall)
      echo "This will remove services and configuration created by this module."
      echo "It will not purge shared packages or the offline package cache."
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

  INITBOX_REPO_ROOT="$REPO_ROOT" \
  INITBOX_PACKAGES_FILE="$PACKAGES_FILE" \
  INITBOX_PACKAGE_CACHE_DIR="$PACKAGE_CACHE_DIR" \
  bash "$module_script"
}

run_module_action() {
  local module_script="$1"
  local module_action="$2"

  case "$module_action" in
    install)
      run_module_install "$module_script"
      ;;
    uninstall|remove)
      INITBOX_REPO_ROOT="$REPO_ROOT" \
      INITBOX_PACKAGES_FILE="$PACKAGES_FILE" \
      INITBOX_PACKAGE_CACHE_DIR="$PACKAGE_CACHE_DIR" \
      bash "$module_script" "$module_action"
      ;;
    *)
      INITBOX_REPO_ROOT="$REPO_ROOT" \
      INITBOX_PACKAGES_FILE="$PACKAGES_FILE" \
      INITBOX_PACKAGE_CACHE_DIR="$PACKAGE_CACHE_DIR" \
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
        uninstall|remove)
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
        uninstall|remove)
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

  if confirm_module_action "uninstall" "$module_name" "$module_script" "REMOVE"; then
    run_module_script "$module_id" "$module_name" "$module_script" "uninstall"
  fi
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

    printf 'Select install module [1-%s], p preseed, v verify, b baseline, u uninstall, c checks, l log, s state, or q: ' "$max_choice"
    read -r choice

    choice="${choice//$'\r'/}"

    case "$choice" in
      q|Q)
        echo "Quit."
        log_line "INSTALLER_CLOSED profile=$PROFILE_ID"
        exit 0
        ;;
      p|P)
        run_package_preseed || true
        pause
        ;;
      v|V)
        run_package_verify || true
        pause
        ;;
      b|B)
        run_baseline_apt_update_upgrade || true
        pause
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
  require_root_for_system_action
  ensure_passwordless_sudo

  build_supported_module_list
  record_profile_state

  log_line "INSTALLER_OPENED profile=$PROFILE_ID action=$ACTION"

  if [ "${#SUPPORTED_MODULES[@]}" -eq 0 ]; then
    echo "ERROR: no supported modules found for profile '$PROFILE_ID'."
    log_line "ERROR no_supported_modules profile=$PROFILE_ID"
    exit 1
  fi

  case "$ACTION" in
    menu|"")
      interactive_menu
      ;;
    p|P|preseed|packages)
      run_package_preseed
      ;;
    v|V|verify|verify-packages)
      run_package_verify
      ;;
    baseline|upgrade)
      run_baseline_apt_update_upgrade
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
      echo "  ./scripts/initbox-installer.sh pi-zero2w p"
      echo "  ./scripts/initbox-installer.sh pi-zero2w v"
      echo "  ./scripts/initbox-installer.sh pi-zero2w uninstall"
      exit 1
      ;;
  esac
}

main "$@"
