#!/usr/bin/env bash
# InitBox unified first-install bootstrapper.
#
# The installer is the master roster/orchestrator for a safe management
# baseline. It installs only management-safe modules by default, records the
# requested Dashboard state before module installation begins, and leaves all
# field/runtime roles OFF until an operator explicitly enables them.
#
# Runtime layout:
#   executables: /usr/local/bin
#   shared files: /usr/local/share/initbox
#   logs: /var/log/initbox

set -euo pipefail

ACTION="menu"
ASSUME_YES="0"
SYSTEM_UPGRADE_POLICY="prompt"
DASHBOARD_POLICY="prompt"
REFRESH_CACHE_POLICY="prompt"
SKIP_MODULES="0"

OWNER="${OWNER:-initbox}"
RUNTIME_ROOT="${INITBOX_RUNTIME_ROOT:-/usr/local/share/initbox}"
BIN_DIR="${INITBOX_BIN_DIR:-/usr/local/bin}"
STATE_DIR="${INITBOX_STATE_DIR:-/etc/initbox}"
LOG_DIR="${INITBOX_LOG_DIR:-/var/log/initbox}"
PACKAGE_CACHE_ROOT="${INITBOX_PACKAGE_CACHE_ROOT:-/opt/initbox/packages}"
APT_CACHE_DIR="${INITBOX_APT_CACHE_DIR:-${PACKAGE_CACHE_ROOT}/apt}"
INSTALL_LOG="${INITBOX_INSTALL_LOG:-${LOG_DIR}/install.log}"
DASHBOARD_REQUEST_FILE="${DASHBOARD_REQUEST_FILE:-/etc/initbox/dashboard-requested.env}"
REPO_ROOT=""
PROFILE_ID=""
DEFAULT_MODULES_LIST=""
OPERATIONAL_MODULES_LIST=""
DASHBOARD_SELECTED="no"

usage() {
  cat <<'EOF_USAGE'
Usage:
  sudo scripts/install-initbox.sh
  sudo scripts/install-initbox.sh menu
  sudo scripts/install-initbox.sh plan
  sudo scripts/install-initbox.sh status
  sudo scripts/install-initbox.sh install [advanced options]

Normal use:
  Run without arguments and use the menu.

Actions:
  menu                  Guided installer menu. Default when no action is given.
  install               Advanced non-menu install.
  plan                  Show detected hardware/profile and planned modules only.
  status                Show installed InitBox state if present.

Advanced options for install:
  --yes, -y             Accept prompts using safe defaults.
  --system-upgrade yes|no|prompt
                         First-install apt-get update + apt-get upgrade.
                         Default: prompt.
  --dashboard yes|no|prompt
                         Pi-full only. Dashboard is never installed on Zero.
                         Default: prompt.
  --refresh-cache yes|no|prompt
                         Refresh offline package cache after module install.
                         Default: prompt.
  --skip-modules        Install runtime files only; do not install modules.
  --runtime-root PATH   Runtime root. Default: /usr/local/share/initbox.
  --repo-root PATH      Source repository root. Auto-detected by default.
  --help, -h            Show this help.

Design rules:
  - apt-get only.
  - never runs apt-get dist-upgrade or full-upgrade.
  - no git checkout and no GitHub Actions runner.
  - Dashboard selection is recorded before module installation begins.
  - Pi-full baseline installs only management-safe modules.
  - ISI, sniffer-bridge, and FMS roles remain OFF until explicitly enabled.
  - all InitBox logs go under /var/log/initbox.
EOF_USAGE
}

log() {
  printf '[installer] %s\n' "$*"
  if [ -n "${INSTALL_LOG:-}" ]; then
    printf '[installer] %s\n' "$*" >>"$INSTALL_LOG" 2>/dev/null || true
  fi
}

warn() {
  printf '[installer] [WARN] %s\n' "$*" >&2
  if [ -n "${INSTALL_LOG:-}" ]; then
    printf '[installer] [WARN] %s\n' "$*" >>"$INSTALL_LOG" 2>/dev/null || true
  fi
}

fail() {
  printf '[installer] [ERR] %s\n' "$*" >&2
  if [ -n "${INSTALL_LOG:-}" ]; then
    printf '[installer] [ERR] %s\n' "$*" >>"$INSTALL_LOG" 2>/dev/null || true
  fi
  exit 1
}

require_root() {
  if [ "$(id -u)" -ne 0 ]; then
    fail "this installer must be run as root"
  fi
}

validate_yes_no_prompt() {
  case "$1" in
    yes|no|prompt) ;;
    *) fail "expected yes, no, or prompt; got: $1" ;;
  esac
}

parse_args() {
  if [ "$#" -gt 0 ]; then
    case "$1" in
      menu|install|plan|status)
        ACTION="$1"
        shift
        ;;
    esac
  fi

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --yes|-y)
        ASSUME_YES="1"
        shift
        ;;
      --system-upgrade)
        [ "$#" -ge 2 ] || fail "--system-upgrade requires yes, no, or prompt"
        SYSTEM_UPGRADE_POLICY="$2"
        validate_yes_no_prompt "$SYSTEM_UPGRADE_POLICY"
        shift 2
        ;;
      --dashboard)
        [ "$#" -ge 2 ] || fail "--dashboard requires yes, no, or prompt"
        DASHBOARD_POLICY="$2"
        validate_yes_no_prompt "$DASHBOARD_POLICY"
        shift 2
        ;;
      --refresh-cache)
        [ "$#" -ge 2 ] || fail "--refresh-cache requires yes, no, or prompt"
        REFRESH_CACHE_POLICY="$2"
        validate_yes_no_prompt "$REFRESH_CACHE_POLICY"
        shift 2
        ;;
      --skip-modules)
        SKIP_MODULES="1"
        shift
        ;;
      --runtime-root)
        [ "$#" -ge 2 ] || fail "--runtime-root requires a path"
        RUNTIME_ROOT="$2"
        shift 2
        ;;
      --repo-root)
        [ "$#" -ge 2 ] || fail "--repo-root requires a path"
        REPO_ROOT="$2"
        shift 2
        ;;
      --help|-h|help)
        usage
        exit 0
        ;;
      *)
        usage >&2
        fail "unknown argument: $1"
        ;;
    esac
  done

  case "$ACTION" in
    menu|install|plan|status) ;;
    *) fail "unknown action: $ACTION" ;;
  esac

  if [ "$ASSUME_YES" = "1" ]; then
    [ "$SYSTEM_UPGRADE_POLICY" = "prompt" ] && SYSTEM_UPGRADE_POLICY="no"
    [ "$DASHBOARD_POLICY" = "prompt" ] && DASHBOARD_POLICY="no"
    [ "$REFRESH_CACHE_POLICY" = "prompt" ] && REFRESH_CACHE_POLICY="no"
  fi
}

ask_yes_no() {
  local prompt="$1"
  local default_answer="$2"
  local reply=""
  local suffix=""

  case "$default_answer" in
    yes) suffix="Y/n" ;;
    no) suffix="y/N" ;;
    *) fail "invalid default answer: $default_answer" ;;
  esac

  if [ "$ASSUME_YES" = "1" ]; then
    printf '%s\n' "$default_answer"
    return 0
  fi

  if [ -e /dev/tty ]; then
    read -r -p "${prompt} [${suffix}]: " reply </dev/tty || reply=""
  elif [ -t 0 ]; then
    read -r -p "${prompt} [${suffix}]: " reply || reply=""
  else
    reply=""
  fi

  case "${reply:-$default_answer}" in
    y|Y|yes|YES|Yes) printf 'yes\n' ;;
    n|N|no|NO|No) printf 'no\n' ;;
    *) printf '%s\n' "$default_answer" ;;
  esac
}

read_menu_choice() {
  local choice=""
  if [ -e /dev/tty ]; then
    read -r -p "Select option: " choice </dev/tty || choice="q"
  elif [ -t 0 ]; then
    read -r -p "Select option: " choice || choice="q"
  else
    choice="q"
  fi
  printf '%s\n' "$choice"
}

prepare_base_dirs() {
  install -d -m 0755 "$RUNTIME_ROOT" "$BIN_DIR" "$STATE_DIR" "$LOG_DIR" "$PACKAGE_CACHE_ROOT" "$APT_CACHE_DIR"
  touch "$INSTALL_LOG"
  chmod 0644 "$INSTALL_LOG" 2>/dev/null || true
}

ensure_owner_user() {
  if id "$OWNER" >/dev/null 2>&1; then
    return 0
  fi

  log "Creating system user: $OWNER"
  if command -v useradd >/dev/null 2>&1; then
    useradd --system --create-home --home-dir "/home/${OWNER}" --shell /bin/bash "$OWNER"
  else
    fail "useradd is required to create $OWNER"
  fi
}

find_repo_root() {
  local script_path=""
  local script_dir=""
  local candidate=""

  if [ -n "$REPO_ROOT" ]; then
    [ -f "$REPO_ROOT/scripts/lib/hardware.sh" ] || fail "--repo-root does not look like InitBox repo root: $REPO_ROOT"
    return 0
  fi

  if [ -n "${INITBOX_REPO_ROOT:-}" ] && [ -f "${INITBOX_REPO_ROOT}/scripts/lib/hardware.sh" ]; then
    REPO_ROOT="$INITBOX_REPO_ROOT"
    return 0
  fi

  script_path="$(readlink -f "${BASH_SOURCE[0]}")"
  script_dir="$(cd "$(dirname "$script_path")" && pwd)"

  candidate="$(cd "$script_dir/.." 2>/dev/null && pwd || true)"
  if [ -n "$candidate" ] && [ -f "$candidate/scripts/lib/hardware.sh" ]; then
    REPO_ROOT="$candidate"
    return 0
  fi

  if [ -f "$RUNTIME_ROOT/scripts/lib/hardware.sh" ]; then
    REPO_ROOT="$RUNTIME_ROOT"
    return 0
  fi

  fail "could not locate InitBox repository/runtime root"
}

require_file() {
  [ -f "$1" ] || fail "required file is missing: $1"
}

source_helpers() {
  require_file "$REPO_ROOT/scripts/lib/hardware.sh"
  require_file "$REPO_ROOT/scripts/lib/profile.sh"
  require_file "$REPO_ROOT/scripts/lib/state.sh"

  # shellcheck source=/dev/null
  . "$REPO_ROOT/scripts/lib/hardware.sh"
  # shellcheck source=/dev/null
  . "$REPO_ROOT/scripts/lib/profile.sh"
  # shellcheck source=/dev/null
  . "$REPO_ROOT/scripts/lib/state.sh"
}

detect_and_load_profile() {
  initbox_detect_hardware
  PROFILE_ID="$INITBOX_PROFILE_ID"
  initbox_load_profile "$PROFILE_ID"
  initbox_validate_profile_for_hardware "$PROFILE_ID"
  DEFAULT_MODULES_LIST="$DEFAULT_MODULES"
  OPERATIONAL_MODULES_LIST="${OPERATIONAL_MODULES:-}"
}

print_plan() {
  echo "InitBox unified installer"
  echo "========================"
  echo "Source root:         $REPO_ROOT"
  echo "Runtime root:        $RUNTIME_ROOT"
  echo "Executable dir:      $BIN_DIR"
  echo "Log root:            $LOG_DIR"
  echo "Hardware:            $INITBOX_HARDWARE_NAME"
  echo "Model:               $INITBOX_MODEL_RAW"
  echo "Profile:             $PROFILE_ID"
  echo "Hotspot gateway:     $INITBOX_HOTSPOT_GATEWAY/24"
  echo "Baseline roster:     $DEFAULT_MODULES_LIST"
  echo "Operational roster:  ${OPERATIONAL_MODULES_LIST:-none}"
  if [ "$PROFILE_ID" = "pi-full" ]; then
    echo "Dashboard policy:    optional prompt / explicit menu choice"
  else
    echo "Dashboard policy:    disabled"
  fi
  echo
  echo "Installer rule: operational roles are OFF after install. Operator must enable required roles explicitly."
}

install_file_atomic() {
  local source_path="$1"
  local target_path="$2"
  local mode="$3"
  local target_dir=""
  local temp_path=""
  local source_real=""
  local target_real=""

  require_file "$source_path"
  target_dir="$(dirname "$target_path")"
  install -d -m 0755 "$target_dir"

  source_real="$(readlink -f "$source_path")"
  target_real="$(readlink -m "$target_path")"
  if [ "$source_real" = "$target_real" ]; then
    chmod "$mode" "$target_path"
    chown root:root "$target_path" 2>/dev/null || true
    return 0
  fi

  temp_path="$(mktemp "${target_dir}/.install.XXXXXX")"
  install -m "$mode" -o root -g root "$source_path" "$temp_path"
  mv -f "$temp_path" "$target_path"
}

copy_directory_contents() {
  local source_dir="$1"
  local target_dir="$2"

  [ -d "$source_dir" ] || return 1
  install -d -m 0755 "$target_dir"
  rm -rf "${target_dir:?}/"*
  cp -a "$source_dir/." "$target_dir/"
  chown -R root:root "$target_dir" 2>/dev/null || true
  find "$target_dir" -type d -exec chmod 0755 {} +
  find "$target_dir" -type f -exec chmod 0644 {} +
}

resolve_installer_source() {
  if [ -f "$REPO_ROOT/scripts/install-initbox.sh" ]; then
    printf '%s\n' "$REPO_ROOT/scripts/install-initbox.sh"
    return 0
  fi

  if [ -f "${BASH_SOURCE[0]}" ]; then
    readlink -f "${BASH_SOURCE[0]}"
    return 0
  fi

  return 1
}

install_runtime_tree() {
  local item=""
  local module_source=""
  local module_target_dir=""
  local installer_source=""

  log "Installing InitBox runtime tree"
  installer_source="$(resolve_installer_source)" || fail "could not resolve installer source"

  install_file_atomic "$installer_source" "$BIN_DIR/initbox-installer.sh" 0755
  install_file_atomic "$installer_source" "$RUNTIME_ROOT/scripts/install-initbox.sh" 0644

  if [ -f "$REPO_ROOT/scripts/bootstrap-initbox.sh" ]; then
    install_file_atomic "$REPO_ROOT/scripts/bootstrap-initbox.sh" "$BIN_DIR/initbox-bootstrap.sh" 0755
    install_file_atomic "$REPO_ROOT/scripts/bootstrap-initbox.sh" "$RUNTIME_ROOT/scripts/bootstrap-initbox.sh" 0644
  fi

  install_file_atomic "$REPO_ROOT/scripts/initbox-sync.sh" "$BIN_DIR/initbox-sync.sh" 0755
  install_file_atomic "$REPO_ROOT/scripts/bin/initbox-module-runner.sh" "$BIN_DIR/initbox-module-runner.sh" 0755
  install_file_atomic "$REPO_ROOT/scripts/bin/initbox-package-cache.sh" "$BIN_DIR/initbox-package-cache.sh" 0755

  if [ -f "$REPO_ROOT/scripts/validate-initbox.sh" ]; then
    install_file_atomic "$REPO_ROOT/scripts/validate-initbox.sh" "$BIN_DIR/initbox-validate.sh" 0755
    install_file_atomic "$REPO_ROOT/scripts/validate-initbox.sh" "$RUNTIME_ROOT/scripts/validate-initbox.sh" 0644
  fi

  if [ -f "$REPO_ROOT/scripts/apply-initbox-config.sh" ]; then
    install_file_atomic "$REPO_ROOT/scripts/apply-initbox-config.sh" "$BIN_DIR/initbox-apply-config.sh" 0755
    install_file_atomic "$REPO_ROOT/scripts/apply-initbox-config.sh" "$RUNTIME_ROOT/scripts/apply-initbox-config.sh" 0644
  fi

  install_file_atomic "$REPO_ROOT/scripts/manifest.json" "$RUNTIME_ROOT/manifest.json" 0644

  install -d -m 0755 "$RUNTIME_ROOT/profiles"
  install_file_atomic "$REPO_ROOT/profiles/pi-zero2w.conf" "$RUNTIME_ROOT/profiles/pi-zero2w.conf" 0644
  install_file_atomic "$REPO_ROOT/profiles/pi-full.conf" "$RUNTIME_ROOT/profiles/pi-full.conf" 0644

  install -d -m 0755 "$RUNTIME_ROOT/scripts/lib"
  for item in hardware.sh profile.sh modules.sh state.sh packages.sh module-runner.sh; do
    install_file_atomic "$REPO_ROOT/scripts/lib/$item" "$RUNTIME_ROOT/scripts/lib/$item" 0644
  done

  install -d -m 0755 "$RUNTIME_ROOT/scripts/packages"
  install_file_atomic "$REPO_ROOT/scripts/packages/pi-zero2w.txt" "$RUNTIME_ROOT/scripts/packages/pi-zero2w.txt" 0644
  install_file_atomic "$REPO_ROOT/scripts/packages/pi-full.txt" "$RUNTIME_ROOT/scripts/packages/pi-full.txt" 0644

  module_target_dir="$RUNTIME_ROOT/scripts/$PROFILE_ID"
  install -d -m 0755 "$module_target_dir"
  for module_source in "$REPO_ROOT/scripts/$PROFILE_ID"/module-*.sh; do
    [ -f "$module_source" ] || continue
    install_file_atomic "$module_source" "$module_target_dir/$(basename "$module_source")" 0644
  done

  if [ "$PROFILE_ID" = "pi-full" ]; then
    if [ -f "$REPO_ROOT/backend/initbox_dashboard_api.py" ]; then
      install_file_atomic "$REPO_ROOT/backend/initbox_dashboard_api.py" "$BIN_DIR/initbox-dashboard-api.py" 0755
    fi

    if [ -d "$REPO_ROOT/frontend/dist" ]; then
      copy_directory_contents "$REPO_ROOT/frontend/dist" "$RUNTIME_ROOT/dashboard/ui" || true
    fi
  fi
}

record_base_state() {
  initbox_state_record_hardware \
    "$INITBOX_HARDWARE_ID" \
    "$INITBOX_HARDWARE_NAME" \
    "$INITBOX_MODEL_RAW" \
    "$INITBOX_HOTSPOT_GATEWAY" \
    "$INITBOX_DASHBOARD_CAPABLE"
  initbox_state_record_profile "$PROFILE_ID" "$PROFILE_NAME"
}

record_dashboard_request_file() {
  local requested="$1"
  local source="${2:-installer}"

  install -d -m 0755 "$(dirname "$DASHBOARD_REQUEST_FILE")"
  cat >"$DASHBOARD_REQUEST_FILE" <<EOF_REQUEST
# InitBox dashboard request. Managed by install-initbox.sh / initbox-apply-config.sh.
DASHBOARD_REQUESTED="${requested}"
DASHBOARD_REQUEST_SOURCE="${source}"
DASHBOARD_REQUEST_RECORDED_AT="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
EOF_REQUEST
  chmod 0644 "$DASHBOARD_REQUEST_FILE"
  chown root:root "$DASHBOARD_REQUEST_FILE" 2>/dev/null || true
}

select_and_record_dashboard_request() {
  local decision="no"
  local source="operator"

  if [ "$PROFILE_ID" != "pi-full" ]; then
    DASHBOARD_SELECTED="no"
    initbox_state_record_dashboard_selection "no" "policy"
    record_dashboard_request_file "no" "policy"
    return 0
  fi

  case "$DASHBOARD_POLICY" in
    yes|no)
      decision="$DASHBOARD_POLICY"
      source="operator"
      ;;
    prompt)
      decision="$(ask_yes_no "Install React Dashboard on this Pi-full device" no)"
      source="operator"
      ;;
  esac

  DASHBOARD_SELECTED="$decision"
  initbox_state_record_dashboard_selection "$decision" "$source"
  record_dashboard_request_file "$decision" "$source"
  log "Dashboard request recorded before module installation: $decision"
}

enforce_management_safe_state() {
  if [ "$PROFILE_ID" != "pi-full" ]; then
    return 0
  fi

  log "Enforcing management-safe runtime state: field roles OFF"
  install -d -m 0755 /etc
  printf 'ROLES=""\n' >/etc/pi_roles.conf
  chmod 0664 /etc/pi_roles.conf 2>/dev/null || true
  chown root:"$OWNER" /etc/pi_roles.conf 2>/dev/null || chown root:root /etc/pi_roles.conf 2>/dev/null || true

  systemctl stop isirunall.service wireshark-autostart.service fms.service >/dev/null 2>&1 || true
  systemctl disable isirunall.service wireshark-autostart.service fms.service >/dev/null 2>&1 || true

  if [ -x /usr/local/bin/bridge-check.sh ]; then
    /usr/local/bin/bridge-check.sh cleanup >/dev/null 2>&1 || true
  fi

  ip link set eth0 nomaster >/dev/null 2>&1 || true
  ip link set eth1 nomaster >/dev/null 2>&1 || true
  if ip link show br0 >/dev/null 2>&1; then
    ip link set br0 down >/dev/null 2>&1 || true
    ip link delete br0 type bridge >/dev/null 2>&1 || true
  fi

  rm -f /etc/NetworkManager/conf.d/99-initbox-bridge-unmanaged.conf
  if command -v nmcli >/dev/null 2>&1; then
    nmcli general reload >/dev/null 2>&1 || true
    nmcli device set eth0 managed yes >/dev/null 2>&1 || true
    if ! ip route show default 2>/dev/null | grep -q '^default '; then
      nmcli device connect eth0 >/dev/null 2>&1 || true
    fi
  fi
}

run_first_install_system_upgrade() {
  local decision="no"

  case "$SYSTEM_UPGRADE_POLICY" in
    yes|no) decision="$SYSTEM_UPGRADE_POLICY" ;;
    prompt) decision="$(ask_yes_no "Run first-install apt-get update and apt-get upgrade in the lab" no)" ;;
  esac

  if [ "$decision" != "yes" ]; then
    log "Skipping first-install system upgrade"
    return 0
  fi

  log "Running apt-get update"
  apt-get update

  log "Running apt-get upgrade with existing conffiles preserved"
  DEBIAN_FRONTEND=noninteractive apt-get -y \
    -o Dpkg::Options::=--force-confold \
    upgrade
}

install_default_modules() {
  local module_id=""
  local module_log=""

  if [ "$SKIP_MODULES" = "1" ]; then
    log "Skipping module installation because --skip-modules was requested"
    return 0
  fi

  log "Installing management-safe baseline modules for profile: $PROFILE_ID"
  for module_id in $DEFAULT_MODULES_LIST; do
    case "$PROFILE_ID:$module_id" in
      pi-full:isi|pi-full:fms|pi-full:sniffer-bridge)
        fail "unsafe operational module '$module_id' is present in DEFAULT_MODULES; fix profile roster"
        ;;
    esac

    module_log="$LOG_DIR/module-${module_id}.log"
    log "Installing module: $module_id (log: $module_log)"
    INITBOX_LOG_DIR="$LOG_DIR" LOGFILE="$module_log" "$BIN_DIR/initbox-module-runner.sh" install "$module_id"
  done
}

install_dashboard_if_selected() {
  local module_log=""

  if [ "$SKIP_MODULES" = "1" ]; then
    return 0
  fi

  if [ "$DASHBOARD_SELECTED" = "yes" ]; then
    module_log="$LOG_DIR/module-dashboard.log"
    log "Installing selected Dashboard module (log: $module_log)"
    INITBOX_LOG_DIR="$LOG_DIR" LOGFILE="$module_log" "$BIN_DIR/initbox-module-runner.sh" install dashboard
  else
    log "Dashboard not selected"
  fi
}

refresh_package_cache_if_selected() {
  local decision="no"

  case "$REFRESH_CACHE_POLICY" in
    yes|no) decision="$REFRESH_CACHE_POLICY" ;;
    prompt) decision="$(ask_yes_no "Refresh offline package cache for field use" no)" ;;
  esac

  if [ "$decision" != "yes" ]; then
    log "Skipping package cache refresh"
    return 0
  fi

  log "Refreshing offline package cache for profile: $PROFILE_ID"
  INITBOX_LOG_DIR="$LOG_DIR" "$BIN_DIR/initbox-package-cache.sh" preseed "$PROFILE_ID"
}

run_apply_config() {
  if [ ! -x "$BIN_DIR/initbox-apply-config.sh" ]; then
    warn "Apply-config helper is not installed yet: $BIN_DIR/initbox-apply-config.sh"
    return 0
  fi

  echo
  echo "Applying InitBox convergence"
  echo "----------------------------"
  if [ "$DASHBOARD_SELECTED" = "yes" ]; then
    INITBOX_APPLY_DASHBOARD="yes" "$BIN_DIR/initbox-apply-config.sh" apply || warn "apply-config reported warnings/failures"
  else
    "$BIN_DIR/initbox-apply-config.sh" apply || warn "apply-config reported warnings/failures"
  fi
}

show_status() {
  if [ -f "$STATE_DIR/install-state.env" ]; then
    cat "$STATE_DIR/install-state.env"
  else
    echo "No InitBox install state found at $STATE_DIR/install-state.env"
  fi
}

show_service_summary() {
  echo
  echo "systemctl --failed"
  echo "------------------"
  systemctl --failed --no-pager || true
}

show_log_summary() {
  echo
  echo "Logs"
  echo "----"
  echo "Installer:     $INSTALL_LOG"
  echo "Modules:       $LOG_DIR/module-<module>.log"
  echo "Sync:          $LOG_DIR/sync.log"
  echo "Apply-config:  $LOG_DIR/apply-config.log"
  echo "Validator:     $LOG_DIR/validate-latest.log"
}

run_validation_summary() {
  if [ ! -x "$BIN_DIR/initbox-validate.sh" ]; then
    warn "Validator is not installed yet: $BIN_DIR/initbox-validate.sh"
    return 0
  fi

  echo
  echo "Running InitBox validation"
  echo "--------------------------"
  if "$BIN_DIR/initbox-validate.sh"; then
    log "InitBox validation completed without failures"
  else
    warn "InitBox validation reported failures. See $LOG_DIR/validate-latest.log"
  fi
}

run_install_flow() {
  print_plan
  ensure_owner_user
  run_first_install_system_upgrade
  install_runtime_tree
  record_base_state
  select_and_record_dashboard_request
  enforce_management_safe_state
  install_default_modules
  install_dashboard_if_selected
  enforce_management_safe_state
  run_apply_config
  refresh_package_cache_if_selected
  show_service_summary
  show_log_summary
  run_validation_summary

  log "InitBox installation complete"
  echo
  echo "Installed commands:"
  echo "  $BIN_DIR/initbox-installer.sh"
  echo "  $BIN_DIR/initbox-sync.sh"
  echo "  $BIN_DIR/initbox-module-runner.sh"
  echo "  $BIN_DIR/initbox-package-cache.sh"
  echo "  $BIN_DIR/initbox-apply-config.sh"
  echo "  $BIN_DIR/initbox-validate.sh"
  echo "  $BIN_DIR/initbox-bootstrap.sh"
}

refresh_cache_only() {
  ensure_owner_user
  install_runtime_tree
  record_base_state
  REFRESH_CACHE_POLICY="yes"
  refresh_package_cache_if_selected
  show_log_summary
}

print_menu() {
  echo
  echo "InitBox installer menu"
  echo "======================"
  echo "Hardware: $INITBOX_HARDWARE_NAME"
  echo "Profile:  $PROFILE_ID"
  echo "Gateway:  $INITBOX_HOTSPOT_GATEWAY/24"
  echo "Logs:     $LOG_DIR"
  echo
  echo "1) Show install plan"
  echo "2) Install management baseline without Dashboard"
  if [ "$PROFILE_ID" = "pi-full" ]; then
    echo "3) Install management baseline with Dashboard"
    echo "4) Full lab management install: prompt OS upgrade, prompt Dashboard, refresh cache"
    echo "5) Refresh offline package cache only"
    echo "6) Run validation only"
    echo "7) Show installed state"
  else
    echo "3) Full Zero install: prompt OS upgrade, no Dashboard, refresh cache"
    echo "4) Refresh offline package cache only"
    echo "5) Run validation only"
    echo "6) Show installed state"
  fi
  echo "q) Quit"
  echo
}

run_menu() {
  local choice=""

  while true; do
    print_menu
    choice="$(read_menu_choice)"

    case "$PROFILE_ID:$choice" in
      *:1)
        print_plan
        ;;
      *:2)
        SYSTEM_UPGRADE_POLICY="prompt"
        DASHBOARD_POLICY="no"
        REFRESH_CACHE_POLICY="prompt"
        run_install_flow
        return 0
        ;;
      pi-full:3)
        SYSTEM_UPGRADE_POLICY="prompt"
        DASHBOARD_POLICY="yes"
        REFRESH_CACHE_POLICY="prompt"
        run_install_flow
        return 0
        ;;
      pi-full:4)
        SYSTEM_UPGRADE_POLICY="prompt"
        DASHBOARD_POLICY="prompt"
        REFRESH_CACHE_POLICY="yes"
        run_install_flow
        return 0
        ;;
      pi-full:5)
        refresh_cache_only
        ;;
      pi-full:6)
        install_runtime_tree
        run_apply_config
        ;;
      pi-full:7)
        show_status
        ;;
      pi-zero2w:3)
        SYSTEM_UPGRADE_POLICY="prompt"
        DASHBOARD_POLICY="no"
        REFRESH_CACHE_POLICY="yes"
        run_install_flow
        return 0
        ;;
      pi-zero2w:4)
        refresh_cache_only
        ;;
      pi-zero2w:5)
        install_runtime_tree
        run_apply_config
        ;;
      pi-zero2w:6)
        show_status
        ;;
      *:q|*:Q|*:quit|*:exit)
        log "Installer menu exited without changes"
        return 0
        ;;
      *)
        warn "Unknown menu option: $choice"
        ;;
    esac
  done
}

main() {
  parse_args "$@"

  if [ "$ACTION" = "status" ]; then
    show_status
    return 0
  fi

  require_root
  prepare_base_dirs
  find_repo_root
  source_helpers
  detect_and_load_profile

  case "$ACTION" in
    plan) print_plan ;;
    menu) run_menu ;;
    install) run_install_flow ;;
    *) fail "unsupported action: $ACTION" ;;
  esac
}

main "$@"
