#!/usr/bin/env bash

# InitBox Raspberry Pi 3 / 4 / 5 installer
#
# Branch scope:
#   - pi-3-4-5 only
#
# Lab model:
#   - Internet is expected during lab preparation.
#   - Debian packages can be downloaded once into a local cache.
#   - Field reruns should be able to install from the local cache once
#     module scripts are wired to scripts/lib/packages.sh.
#
# Menu:
#   - install supported modules
#   - run sanity checks
#   - prepare package cache
#   - show package cache status
#   - show logs/state

set -euo pipefail

EXPECTED_PROFILE_ID="pi-3-4-5"

OWNER="${OWNER:-initbox}"
REQUESTED_PROFILE_ID="${1:-$EXPECTED_PROFILE_ID}"
PROFILE_ID="$REQUESTED_PROFILE_ID"
INITIAL_ACTION="${2:-}"

SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_PATH")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

PROFILE_HELPER="$REPO_ROOT/scripts/lib/profile.sh"
MODULE_HELPER="$REPO_ROOT/scripts/lib/modules.sh"
STATE_HELPER="$REPO_ROOT/scripts/lib/state.sh"
PACKAGES_HELPER="$REPO_ROOT/scripts/lib/packages.sh"

PROFILE_FILE="$REPO_ROOT/profiles/${REQUESTED_PROFILE_ID}.conf"
PACKAGES_FILE="$REPO_ROOT/scripts/packages.txt"

LOG_DIR="/var/log/initbox"
LOGFILE="${LOGFILE:-${LOG_DIR}/install.log}"

LEGACY_LOG_DIR="/home/${OWNER}/pi_logs"
LEGACY_LOGFILE="${LEGACY_LOGFILE:-${LEGACY_LOG_DIR}/initbox-install.log}"

STATE_DIR="/etc/initbox"
STATE_FILE="${STATE_FILE:-${STATE_DIR}/install-state.env}"

OPERATOR_USER="${SUDO_USER:-$OWNER}"

PROFILE_NAME=""
PROFILE_DESCRIPTION=""
REQUIRES_LAB_INTERNET=""
FIELD_INSTALL_ALLOWED=""
SUPPORTS_DASHBOARD=""
SUPPORTS_WEB_TERMINAL=""
DEFAULT_MODULES=""
PRIMARY_MANAGEMENT_INTERFACE=""

ts() {
  date +"%Y-%m-%d %H:%M:%S"
}

log() {
  echo "[INITBOX $(ts)] $*" | tee -a "$LOGFILE"
}

ok() {
  echo "[INITBOX $(ts)] [OK] $*" | tee -a "$LOGFILE"
}

warn() {
  echo "[INITBOX $(ts)] [WARN] $*" | tee -a "$LOGFILE" >&2
}

err() {
  echo "[INITBOX $(ts)] [ERR] $*" | tee -a "$LOGFILE" >&2
}

die() {
  err "$*"
  exit 1
}

repo_relpath() {
  local path="$1"

  printf '%s\n' "${path#"${REPO_ROOT}/"}"
}

require_root() {
  if [ "$(id -u)" -ne 0 ]; then
    die "Run this installer with sudo."
  fi
}

have_internet() {
  ping -c 1 -W 1 8.8.8.8 >/dev/null 2>&1
}

prepare_log_paths() {
  install -d -m 0755 "$LOG_DIR"
  touch "$LOGFILE"

  install -d -m 0755 "$LEGACY_LOG_DIR"
  touch "$LEGACY_LOGFILE"

  if id "$OWNER" >/dev/null 2>&1; then
    chown -R "$OWNER:$OWNER" "$LEGACY_LOG_DIR" || true
  fi
}

prepare_state_path() {
  install -d -m 0755 "$STATE_DIR"

  if [ ! -f "$STATE_FILE" ]; then
    cat >"$STATE_FILE" <<EOF
# InitBox install state
PROFILE_ID=""
PROFILE_NAME=""
LAST_INSTALL_TIME=""
LAST_MODULE=""
LAST_MODULE_STATUS=""
EOF
    chmod 644 "$STATE_FILE"
  fi
}

write_state_value() {
  local key="$1"
  local value="$2"
  local tmp_file=""

  prepare_state_path

  tmp_file="$(mktemp)"

  if grep -q "^${key}=" "$STATE_FILE"; then
    sed "s|^${key}=.*|${key}=\"${value}\"|" "$STATE_FILE" >"$tmp_file"
  else
    cat "$STATE_FILE" >"$tmp_file"
    printf '%s="%s"\n' "$key" "$value" >>"$tmp_file"
  fi

  install -m 0644 "$tmp_file" "$STATE_FILE"
  rm -f "$tmp_file"
}

record_profile_state() {
  write_state_value "PROFILE_ID" "$PROFILE_ID"
  write_state_value "PROFILE_NAME" "$PROFILE_NAME"
  write_state_value "LAST_INSTALL_TIME" "$(date -Iseconds)"

  if declare -F initbox_state_record_profile >/dev/null 2>&1; then
    initbox_state_record_profile "$PROFILE_ID" "$PROFILE_NAME" || true
  fi
}

record_module_state() {
  local module_id="$1"
  local status="$2"

  write_state_value "LAST_MODULE" "$module_id"
  write_state_value "LAST_MODULE_STATUS" "$status"
  write_state_value "LAST_INSTALL_TIME" "$(date -Iseconds)"
}

record_module_success_state() {
  local module_id="$1"
  local module_name="$2"

  record_module_state "$module_id" "success"

  if declare -F initbox_state_record_module_success >/dev/null 2>&1; then
    initbox_state_record_module_success "$module_id" "$module_name" || true
  fi
}

record_module_failure_state() {
  local module_id="$1"
  local module_name="$2"

  record_module_state "$module_id" "failed"

  if declare -F initbox_state_record_module_failure >/dev/null 2>&1; then
    initbox_state_record_module_failure "$module_id" "$module_name" || true
  fi
}

source_helpers() {
  if [ -f "$PROFILE_HELPER" ]; then
    # shellcheck disable=SC1090
    . "$PROFILE_HELPER"
  fi

  if [ -f "$MODULE_HELPER" ]; then
    # shellcheck disable=SC1090
    . "$MODULE_HELPER"
  fi

  if [ -f "$STATE_HELPER" ]; then
    # shellcheck disable=SC1090
    . "$STATE_HELPER"
  fi

  # Do not source scripts/lib/packages.sh here.
  # It also supports direct CLI execution and may inspect "$1".
  # The installer calls it as a command instead.
}

load_profile() {
  PROFILE_ID="$REQUESTED_PROFILE_ID"
  PROFILE_FILE="$REPO_ROOT/profiles/${PROFILE_ID}.conf"

  if [ "$PROFILE_ID" != "$EXPECTED_PROFILE_ID" ]; then
    die "This branch supports only profile '${EXPECTED_PROFILE_ID}'. Requested: '${PROFILE_ID}'"
  fi

  if [ ! -f "$PROFILE_FILE" ]; then
    die "Profile file not found: $PROFILE_FILE"
  fi

  # shellcheck disable=SC1090
  . "$PROFILE_FILE"

  if [ "${PROFILE_ID:-}" != "$EXPECTED_PROFILE_ID" ]; then
    die "Loaded profile does not match expected profile: ${EXPECTED_PROFILE_ID}"
  fi

  if [ -z "${DEFAULT_MODULES:-}" ]; then
    die "DEFAULT_MODULES is not set in $PROFILE_FILE"
  fi

  PROFILE_NAME="${PROFILE_NAME:-Raspberry Pi 3 / 4 / 5}"
  PROFILE_DESCRIPTION="${PROFILE_DESCRIPTION:-Full InitBox Pi 3 / 4 / 5 appliance}"
  REQUIRES_LAB_INTERNET="${REQUIRES_LAB_INTERNET:-yes}"
  FIELD_INSTALL_ALLOWED="${FIELD_INSTALL_ALLOWED:-no}"
  SUPPORTS_DASHBOARD="${SUPPORTS_DASHBOARD:-yes}"
  SUPPORTS_WEB_TERMINAL="${SUPPORTS_WEB_TERMINAL:-yes}"
  PRIMARY_MANAGEMENT_INTERFACE="${PRIMARY_MANAGEMENT_INTERFACE:-dashboard}"
}

ensure_passwordless_sudo_for_operator() {
  local sudoers_file="/etc/sudoers.d/010-initbox-${OPERATOR_USER}"

  if [ "$OPERATOR_USER" = "root" ]; then
    log "Running as root directly; passwordless sudo setup not required."
    return 0
  fi

  if ! id "$OPERATOR_USER" >/dev/null 2>&1; then
    warn "Operator user not found: $OPERATOR_USER"
    return 0
  fi

  log "Ensuring passwordless sudo for operator user: ${OPERATOR_USER}"

  cat >"$sudoers_file" <<EOF
${OPERATOR_USER} ALL=(ALL) NOPASSWD:ALL
EOF

  chmod 440 "$sudoers_file"

  if visudo -cf "$sudoers_file" >/dev/null 2>&1; then
    ok "Passwordless sudo configured for ${OPERATOR_USER}."
  else
    rm -f "$sudoers_file"
    die "Generated sudoers file failed validation."
  fi
}

run_lab_baseline_apt() {
  if ! have_internet; then
    warn "No Internet detected; skipping baseline apt-get update/upgrade."
    warn "Package installs must use the local cache if already prepared."
    return 0
  fi

  log "Running lab baseline apt-get update."

  if ! DEBIAN_FRONTEND=noninteractive apt-get -o Dpkg::Use-Pty=0 -o Acquire::Retries=5 update 2>&1 | tee -a "$LOGFILE"; then
    warn "apt-get update failed; continuing to menu."
    return 0
  fi

  log "Running lab baseline apt-get upgrade."

  if ! DEBIAN_FRONTEND=noninteractive apt-get -o Dpkg::Use-Pty=0 -o Acquire::Retries=5 upgrade -y 2>&1 | tee -a "$LOGFILE"; then
    warn "apt-get upgrade failed; continuing to menu."
    return 0
  fi
}

repair_permissions() {
  local file=""

  log "Repairing script permissions."

  for file in \
    "$REPO_ROOT/scripts/initbox-installer.sh" \
    "$REPO_ROOT/scripts/initbox-status.sh" \
    "$REPO_ROOT/scripts/update-repo.sh" \
    "$REPO_ROOT/scripts/lib/profile.sh" \
    "$REPO_ROOT/scripts/lib/modules.sh" \
    "$REPO_ROOT/scripts/lib/state.sh" \
    "$REPO_ROOT/scripts/lib/packages.sh" \
    "$REPO_ROOT/scripts/pi-3-4-5/module-dashboard.sh" \
    "$REPO_ROOT/scripts/pi-3-4-5/module-fms.sh" \
    "$REPO_ROOT/scripts/pi-3-4-5/module-hotspot.sh" \
    "$REPO_ROOT/scripts/pi-3-4-5/module-isi.sh" \
    "$REPO_ROOT/scripts/pi-3-4-5/module-rtc.sh" \
    "$REPO_ROOT/scripts/pi-3-4-5/module-ws-br0.sh"; do
    if [ -f "$file" ]; then
      chmod 755 "$file"
    fi
  done
}

module_display_name() {
  local module_id="$1"

  if declare -F initbox_module_display_name >/dev/null 2>&1; then
    initbox_module_display_name "$module_id"
    return 0
  fi

  case "$module_id" in
    isi)
      echo "ISI"
      ;;
    fms)
      echo "FMS"
      ;;
    hotspot)
      echo "Hotspot"
      ;;
    dashboard)
      echo "Dashboard"
      ;;
    web-terminal)
      echo "Web Terminal"
      ;;
    rtc)
      echo "RTC"
      ;;
    sniffer-bridge)
      echo "Sniffer / Bridge"
      ;;
    *)
      echo "$module_id"
      ;;
  esac
}

module_script_path() {
  local module_id="$1"

  if declare -F initbox_module_script_path >/dev/null 2>&1; then
    initbox_module_script_path "$PROFILE_ID" "$module_id" "$REPO_ROOT"
    return $?
  fi

  case "$module_id" in
    isi)
      echo "$REPO_ROOT/scripts/pi-3-4-5/module-isi.sh"
      ;;
    fms)
      echo "$REPO_ROOT/scripts/pi-3-4-5/module-fms.sh"
      ;;
    hotspot)
      echo "$REPO_ROOT/scripts/pi-3-4-5/module-hotspot.sh"
      ;;
    dashboard|web-terminal)
      echo "$REPO_ROOT/scripts/pi-3-4-5/module-dashboard.sh"
      ;;
    rtc)
      echo "$REPO_ROOT/scripts/pi-3-4-5/module-rtc.sh"
      ;;
    sniffer-bridge)
      echo "$REPO_ROOT/scripts/pi-3-4-5/module-ws-br0.sh"
      ;;
    *)
      return 1
      ;;
  esac
}

supported_modules() {
  local module_id=""
  local seen=" "

  for module_id in $DEFAULT_MODULES; do
    case "$seen" in
      *" ${module_id} "*)
        continue
        ;;
    esac

    seen="${seen}${module_id} "
    echo "$module_id"
  done
}

show_header() {
  clear || true
  echo "InitBox Raspberry Pi 3 / 4 / 5 Installer"
  echo "========================================="
  echo
  echo "Repository:     $REPO_ROOT"
  echo "Profile:        $PROFILE_ID"
  echo "Profile name:   $PROFILE_NAME"
  echo "Interface:      $PRIMARY_MANAGEMENT_INTERFACE"
  echo "Log:            $LOGFILE"
  echo "Legacy log:     $LEGACY_LOGFILE"
  echo "State:          $STATE_FILE"
  echo
}

show_log_path() {
  echo
  echo "Installer log:"
  echo "  $LOGFILE"
  echo
  echo "Legacy module log:"
  echo "  $LEGACY_LOGFILE"
  echo
  echo "Recent installer log:"
  echo "----------------------------------------"

  if [ -f "$LOGFILE" ]; then
    tail -n 80 "$LOGFILE" || true
  else
    echo "Log file does not exist yet."
  fi
}

show_state() {
  echo
  echo "Install state:"
  echo "  $STATE_FILE"
  echo "----------------------------------------"

  if declare -F initbox_state_print >/dev/null 2>&1; then
    initbox_state_print || true
    return 0
  fi

  if [ -f "$STATE_FILE" ]; then
    cat "$STATE_FILE"
  else
    echo "State file does not exist yet."
  fi
}

show_package_cache_status() {
  echo
  echo "Package cache status"
  echo "----------------------------------------"

  if [ ! -f "$PACKAGES_HELPER" ]; then
    echo "Package helper missing: $PACKAGES_HELPER"
    return 1
  fi

  bash "$PACKAGES_HELPER" status
}

prepare_package_cache() {
  echo
  echo "Prepare package cache"
  echo "----------------------------------------"
  echo "Package list:"
  echo "  $PACKAGES_FILE"
  echo

  if [ ! -f "$PACKAGES_HELPER" ]; then
    die "Package helper missing: $PACKAGES_HELPER"
  fi

  if [ ! -f "$PACKAGES_FILE" ]; then
    die "Package list missing: $PACKAGES_FILE"
  fi

  if ! have_internet; then
    die "Internet is required to prepare the package cache."
  fi

  log "Preparing package cache from ${PACKAGES_FILE}."

  bash "$PACKAGES_HELPER" download "$PACKAGES_FILE"

  ok "Package cache prepared."
  show_package_cache_status
}

run_sanity_checks() {
  local failed=0
  local file=""
  local module_id=""
  local script_path=""

  echo
  echo "InitBox sanity checks"
  echo "====================="
  echo
  echo "Repository root:"
  echo "$REPO_ROOT"
  echo

  echo "Required files"
  echo "--------------"

  for file in \
    "$REPO_ROOT/README.md" \
    "$REPO_ROOT/profiles/README.md" \
    "$REPO_ROOT/profiles/pi-3-4-5.conf" \
    "$REPO_ROOT/scripts/initbox-installer.sh" \
    "$REPO_ROOT/scripts/initbox-status.sh" \
    "$REPO_ROOT/scripts/update-repo.sh" \
    "$REPO_ROOT/scripts/packages.txt" \
    "$REPO_ROOT/scripts/lib/profile.sh" \
    "$REPO_ROOT/scripts/lib/modules.sh" \
    "$REPO_ROOT/scripts/lib/state.sh" \
    "$REPO_ROOT/scripts/lib/packages.sh"; do
    if [ -f "$file" ]; then
      echo "[PASS] file exists: $(repo_relpath "$file")"
    else
      echo "[FAIL] missing file: $(repo_relpath "$file")"
      failed=1
    fi
  done

  echo
  echo "Loaded profile checks"
  echo "---------------------"

  if [ "$PROFILE_ID" = "$EXPECTED_PROFILE_ID" ]; then
    echo "[PASS] PROFILE_ID is ${EXPECTED_PROFILE_ID}"
  else
    echo "[FAIL] PROFILE_ID is not ${EXPECTED_PROFILE_ID}: $PROFILE_ID"
    failed=1
  fi

  if [ -n "$PROFILE_NAME" ]; then
    echo "[PASS] PROFILE_NAME is set"
  else
    echo "[FAIL] PROFILE_NAME is empty"
    failed=1
  fi

  if [ -n "$DEFAULT_MODULES" ]; then
    echo "[PASS] DEFAULT_MODULES is set"
  else
    echo "[FAIL] DEFAULT_MODULES is empty"
    failed=1
  fi

  if [ "$SUPPORTS_DASHBOARD" = "yes" ]; then
    echo "[PASS] Dashboard is supported"
  else
    echo "[FAIL] Dashboard should be supported for pi-3-4-5"
    failed=1
  fi

  if [ "$SUPPORTS_WEB_TERMINAL" = "yes" ]; then
    echo "[PASS] Web Terminal is supported"
  else
    echo "[FAIL] Web Terminal should be supported for pi-3-4-5"
    failed=1
  fi

  echo
  echo "Package cache checks"
  echo "--------------------"

  if [ -x "$PACKAGES_HELPER" ]; then
    echo "[PASS] packages helper is executable"
  elif [ -f "$PACKAGES_HELPER" ]; then
    echo "[WARN] packages helper exists but is not executable"
  else
    echo "[FAIL] packages helper missing"
    failed=1
  fi

  if [ -f "$PACKAGES_FILE" ]; then
    echo "[PASS] packages.txt exists"
    if grep -vE '^[[:space:]]*($|#)' "$PACKAGES_FILE" | grep -q .; then
      echo "[PASS] packages.txt contains package names"
    else
      echo "[FAIL] packages.txt has no package names"
      failed=1
    fi
  else
    echo "[FAIL] packages.txt missing"
    failed=1
  fi

  if [ -f "$PACKAGES_HELPER" ]; then
    echo "[PASS] package helper exists"
  else
    echo "[FAIL] package helper does not exist"
    failed=1
  fi

  echo
  echo "Module mapping checks"
  echo "---------------------"

  while IFS= read -r module_id; do
    [ -z "$module_id" ] && continue

    if script_path="$(module_script_path "$module_id")"; then
      if [ -f "$script_path" ]; then
        echo "[PASS] supported module script exists: $module_id ($(module_display_name "$module_id"))"
      else
        echo "[FAIL] supported module script missing: $module_id -> $script_path"
        failed=1
      fi
    else
      echo "[FAIL] no module mapping for: $module_id"
      failed=1
    fi
  done < <(supported_modules)

  echo
  echo "Syntax checks"
  echo "-------------"

  while IFS= read -r file; do
    [ -z "$file" ] && continue

    if bash -n "$file"; then
      echo "[PASS] bash -n: $(repo_relpath "$file")"
    else
      echo "[FAIL] bash -n: $(repo_relpath "$file")"
      failed=1
    fi
  done < <(
    find "$REPO_ROOT/scripts" -type f -name '*.sh' | sort
  )

  echo
  echo "ShellCheck"
  echo "----------"

  if command -v shellcheck >/dev/null 2>&1; then
    if shellcheck "$REPO_ROOT"/scripts/*.sh "$REPO_ROOT"/scripts/lib/*.sh "$REPO_ROOT"/scripts/pi-3-4-5/*.sh; then
      echo "[PASS] shellcheck"
    else
      echo "[FAIL] shellcheck found issues"
      failed=1
    fi
  else
    echo "[WARN] shellcheck not installed; skipping"
  fi

  echo

  if [ "$failed" -eq 0 ]; then
    ok "All sanity checks passed."
    return 0
  fi

  err "Sanity checks failed."
  return 1
}

print_module_menu() {
  local index=1
  local module_id=""
  local script_path=""
  local module_name=""

  echo "Supported modules"
  echo "-----------------"

  while IFS= read -r module_id; do
    [ -z "$module_id" ] && continue

    module_name="$(module_display_name "$module_id")"

    if script_path="$(module_script_path "$module_id")"; then
      if [ -f "$script_path" ]; then
        printf '%2d) %-16s %s\n' "$index" "$module_id" "$module_name"
      else
        printf '%2d) %-16s %s [missing script]\n' "$index" "$module_id" "$module_name"
      fi
    else
      printf '%2d) %-16s %s [no mapping]\n' "$index" "$module_id" "$module_name"
    fi

    index=$((index + 1))
  done < <(supported_modules)

  echo
  echo "Other options"
  echo "-------------"
  echo " c) Run sanity checks"
  echo " p) Prepare/download package cache"
  echo " k) Show package cache status"
  echo " l) Show install log"
  echo " s) Show install state"
  echo " q) Quit"
  echo
}

module_by_index() {
  local wanted_index="$1"
  local index=1
  local module_id=""

  while IFS= read -r module_id; do
    [ -z "$module_id" ] && continue

    if [ "$index" -eq "$wanted_index" ]; then
      echo "$module_id"
      return 0
    fi

    index=$((index + 1))
  done < <(supported_modules)

  return 1
}

confirm_run() {
  local module_id="$1"
  local module_name="$2"
  local reply=""

  echo
  echo "Selected module:"
  echo "  ${module_id} (${module_name})"
  echo
  echo "Type RUN to execute this module."
  echo "Anything else cancels."
  echo

  if [ -e /dev/tty ]; then
    read -r -p "Confirmation: " reply </dev/tty || reply=""
  else
    read -r -p "Confirmation: " reply || reply=""
  fi

  [ "$reply" = "RUN" ]
}

run_module() {
  local module_id="$1"
  local module_name=""
  local script_path=""

  module_name="$(module_display_name "$module_id")"

  if ! script_path="$(module_script_path "$module_id")"; then
    err "No script mapping for module: $module_id"
    return 1
  fi

  if [ ! -f "$script_path" ]; then
    err "Module script missing: $script_path"
    return 1
  fi

  if ! confirm_run "$module_id" "$module_name"; then
    warn "Cancelled module: $module_id"
    return 0
  fi

  log "Starting module: ${module_id} (${module_name})"
  record_module_state "$module_id" "started"

  if bash "$script_path" install; then
    ok "Module completed: ${module_id}"
    record_module_success_state "$module_id" "$module_name"
    return 0
  fi

  err "Module failed: ${module_id}"
  record_module_failure_state "$module_id" "$module_name"
  return 1
}

pause_for_user() {
  local reply=""

  echo
  if [ -e /dev/tty ]; then
    read -r -p "Press Enter to continue..." reply </dev/tty || true
  else
    read -r -p "Press Enter to continue..." reply || true
  fi
}

handle_choice() {
  local choice="$1"
  local module_id=""

  case "$choice" in
    c|C)
      run_sanity_checks || true
      ;;
    p|P)
      prepare_package_cache || true
      ;;
    k|K)
      show_package_cache_status || true
      ;;
    l|L)
      show_log_path
      ;;
    s|S)
      show_state
      ;;
    q|Q)
      echo "Quit."
      exit 0
      ;;
    ''|*[!0-9]*)
      warn "Unknown menu choice: $choice"
      ;;
    *)
      if module_id="$(module_by_index "$choice")"; then
        run_module "$module_id" || true
      else
        warn "No module at menu index: $choice"
      fi
      ;;
  esac
}

run_menu() {
  local choice=""

  while true; do
    show_header
    print_module_menu

    if [ -e /dev/tty ]; then
      read -r -p "Select option: " choice </dev/tty || choice=""
    else
      read -r -p "Select option: " choice || choice=""
    fi

    handle_choice "$choice"
    pause_for_user
  done
}

run_initial_action_if_requested() {
  case "$INITIAL_ACTION" in
    "")
      return 1
      ;;
    c|check|checks|sanity)
      run_sanity_checks
      return 0
      ;;
    p|packages|cache|download-cache)
      prepare_package_cache
      return 0
      ;;
    k|cache-status|packages-status)
      show_package_cache_status
      return 0
      ;;
    l|log|logs)
      show_log_path
      return 0
      ;;
    s|state)
      show_state
      return 0
      ;;
    *)
      warn "Unknown initial action: $INITIAL_ACTION"
      return 1
      ;;
  esac
}

usage() {
  cat <<EOF
Usage:
  sudo ./scripts/initbox-installer.sh pi-3-4-5
  sudo ./scripts/initbox-installer.sh pi-3-4-5 c
  sudo ./scripts/initbox-installer.sh pi-3-4-5 p
  sudo ./scripts/initbox-installer.sh pi-3-4-5 k
  sudo ./scripts/initbox-installer.sh pi-3-4-5 l
  sudo ./scripts/initbox-installer.sh pi-3-4-5 s

Profile:
  pi-3-4-5 only

Actions:
  c   Run sanity checks
  p   Prepare/download package cache from scripts/packages.txt
  k   Show package cache status
  l   Show install log
  s   Show install state
EOF
}

main() {
  case "${1:-}" in
    -h|--help|help)
      usage
      exit 0
      ;;
  esac

  require_root
  prepare_log_paths
  prepare_state_path
  source_helpers
  load_profile
  repair_permissions
  record_profile_state

  ensure_passwordless_sudo_for_operator
  run_lab_baseline_apt

  if run_initial_action_if_requested; then
    exit 0
  fi

  run_menu
}

main "$@"
