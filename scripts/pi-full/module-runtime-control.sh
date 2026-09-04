#!/usr/bin/env bash
# InitBox Raspberry Pi 3 / 4 / 5 / CM4 / CM5 shared runtime-control module.
#
# This functionality was historically embedded in module-dashboard.sh. It is
# now independent so Pi-full systems remain fully controllable when the React
# Dashboard is not installed.
#
# Installs:
#   - /etc/pi_roles.conf
#   - /etc/initbox/dashboard-modules.env (legacy-compatible availability file)
#   - /usr/local/bin/pi-servsync.sh
#   - /usr/local/bin/pi-rolectl.sh
#   - pi-servsync.service
#
# pi-rolectl examples:
#   sudo pi-rolectl.sh show
#   sudo pi-rolectl.sh set isi fms sniff
#   sudo pi-rolectl.sh add fms
#   sudo pi-rolectl.sh remove sniff
#   sudo pi-rolectl.sh clear
#   sudo pi-rolectl.sh apply
set -euo pipefail

ACTION="${1:-install}"
: "${OWNER:=initbox}"
: "${LOGFILE:=/home/${OWNER}/pi_logs/initbox-install.log}"
: "${ROLE_FILE:=/etc/pi_roles.conf}"
: "${MODS_FILE:=/etc/initbox/dashboard-modules.env}"

SERVSYNC_SCRIPT="/usr/local/bin/pi-servsync.sh"
ROLECTL_SCRIPT="/usr/local/bin/pi-rolectl.sh"
SERVSYNC_SERVICE="/etc/systemd/system/pi-servsync.service"

ts() {
  date '+%Y-%m-%d %H:%M:%S'
}

log() {
  echo "[RUNTIME $(ts)] $*" | tee -a "$LOGFILE"
}

ok() {
  echo "[RUNTIME $(ts)] [OK] $*" | tee -a "$LOGFILE"
}

warn() {
  echo "[RUNTIME $(ts)] [WARN] $*" | tee -a "$LOGFILE" >&2
}

fail() {
  echo "[RUNTIME $(ts)] [ERR] $*" | tee -a "$LOGFILE" >&2
  exit 1
}

require_root() {
  if [ "$(id -u)" -ne 0 ]; then
    fail "this module must be run as root"
  fi
}

ensure_log_dir() {
  install -d -m 0755 "$(dirname "$LOGFILE")"
  touch "$LOGFILE"
  if id "$OWNER" >/dev/null 2>&1; then
    chown "$OWNER:$OWNER" "$LOGFILE" 2>/dev/null || true
  fi
}

ensure_role_file() {
  if [ ! -f "$ROLE_FILE" ]; then
    log "Creating $ROLE_FILE with no active roles"
    cat >"$ROLE_FILE" <<'EOF_ROLES'
# InitBox active runtime roles.
# Supported canonical roles: isi fms sniff
ROLES=""
EOF_ROLES
  fi

  chmod 0664 "$ROLE_FILE" || true
  chown root:"$OWNER" "$ROLE_FILE" 2>/dev/null || chown root:root "$ROLE_FILE" 2>/dev/null || true
}

ensure_module_flags_file() {
  install -d -m 0755 "$(dirname "$MODS_FILE")"

  if [ ! -f "$MODS_FILE" ]; then
    cat >"$MODS_FILE" <<'EOF_FLAGS'
ISI=0
FMS=0
WSBR0=0
HOTSPOT=0
DASHBOARD=0
RTC=0
EOF_FLAGS
  else
    local key=""
    for key in ISI FMS WSBR0 HOTSPOT DASHBOARD RTC; do
      if ! grep -q "^${key}=" "$MODS_FILE"; then
        printf '%s=0\n' "$key" >>"$MODS_FILE"
      fi
    done
  fi

  chmod 0644 "$MODS_FILE"
  chown root:root "$MODS_FILE" 2>/dev/null || true
}

write_servsync_script() {
  log "Writing $SERVSYNC_SCRIPT"

  cat >"$SERVSYNC_SCRIPT" <<'EOF_SERVSYNC'
#!/usr/bin/env bash
set -euo pipefail

ROLE_FILE="${ROLE_FILE:-/etc/pi_roles.conf}"
MODS_FILE="${MODS_FILE:-/etc/initbox/dashboard-modules.env}"
BRIDGE_RUNTIME_CTL="${BRIDGE_RUNTIME_CTL:-/usr/local/bin/initbox-bridge-runtime.sh}"
BRIDGE_ACTIVE_FLAG="${BRIDGE_ACTIVE_FLAG:-/run/initbox/bridge-active}"

SVC_ISI="isirunall.service"
SVC_FMS="fms.service"
SVC_SNIFF="wireshark-autostart.service"
SVC_BRIDGE="bridge-check.service"

log() {
  echo "[servsync] $*"
  logger -t pi-servsync -- "$*" 2>/dev/null || true
}

read_roles() {
  local role_text=""

  if [ -r "$ROLE_FILE" ]; then
    # shellcheck disable=SC1090
    . "$ROLE_FILE" || true
    role_text="${ROLES:-${roles:-}}"
    role_text="${role_text,,}"
    role_text="${role_text//$'\r'/}"
  fi

  printf '%s' "$role_text"
}

load_module_flags() {
  ISI="${ISI:-0}"
  FMS="${FMS:-0}"
  WSBR0="${WSBR0:-0}"
  RTC="${RTC:-0}"
  HOTSPOT="${HOTSPOT:-0}"
  DASHBOARD="${DASHBOARD:-0}"

  if [ -r "$MODS_FILE" ]; then
    # shellcheck disable=SC1090
    . "$MODS_FILE" || true
  fi

  ISI="${ISI:-0}"
  FMS="${FMS:-0}"
  WSBR0="${WSBR0:-0}"
  RTC="${RTC:-0}"
  HOTSPOT="${HOTSPOT:-0}"
  DASHBOARD="${DASHBOARD:-0}"
}

sanitize_roles() {
  local requested_roles="$1"
  local clean_roles=""
  local role_word=""

  load_module_flags

  for role_word in $requested_roles; do
    case "$role_word" in
      isi)
        [ "$ISI" = "1" ] && clean_roles="${clean_roles} isi"
        ;;
      fms)
        [ "$FMS" = "1" ] && clean_roles="${clean_roles} fms"
        ;;
      sniff|wireshark|sniffer|sniffer-bridge|ethsniffer)
        [ "$WSBR0" = "1" ] && clean_roles="${clean_roles} sniff"
        ;;
      *)
        log "ignoring unsupported or unavailable role: $role_word"
        ;;
    esac
  done

  printf '%s\n' "$clean_roles" | xargs
}

write_roles_if_changed() {
  local clean_roles="$1"
  local current_roles=""

  current_roles="$(read_roles)"
  [ "$current_roles" = "$clean_roles" ] && return 0

  install -d -m 0755 "$(dirname "$ROLE_FILE")"
  printf 'ROLES="%s"\n' "$clean_roles" >"$ROLE_FILE"
  chmod 0664 "$ROLE_FILE" || true
  chown root:initbox "$ROLE_FILE" 2>/dev/null || chown root:root "$ROLE_FILE" 2>/dev/null || true
  log "sanitized $ROLE_FILE: '$current_roles' -> '$clean_roles'"
}

start_enable() {
  local unit="$1"

  if ! systemctl cat "$unit" >/dev/null 2>&1; then
    log "unit not installed: $unit"
    return 0
  fi

  systemctl enable --now "$unit" >/dev/null 2>&1 || true
  sleep 0.2

  if systemctl is-active --quiet "$unit"; then
    log "started $unit"
  else
    log "failed to start $unit"
  fi
}

stop_disable() {
  local unit="$1"
  systemctl stop "$unit" >/dev/null 2>&1 || true
  systemctl disable "$unit" >/dev/null 2>&1 || true
  log "stopped+disabled $unit"
}

bridge_runtime_start() {
  if [ -x "$BRIDGE_RUNTIME_CTL" ]; then
    "$BRIDGE_RUNTIME_CTL" start >/dev/null 2>&1 || true
  else
    mkdir -p "$(dirname "$BRIDGE_ACTIVE_FLAG")"
    : >"$BRIDGE_ACTIVE_FLAG"
  fi
  log "bridge runtime armed"
}

bridge_runtime_stop() {
  if [ -x "$BRIDGE_RUNTIME_CTL" ]; then
    "$BRIDGE_RUNTIME_CTL" stop >/dev/null 2>&1 || true
  else
    rm -f "$BRIDGE_ACTIVE_FLAG" 2>/dev/null || true
  fi
  log "bridge runtime disarmed"
}

bridge_runtime_is_armed() {
  [ -f "$BRIDGE_ACTIVE_FLAG" ]
}

mode="${1:-apply}"
force_stop=0
arm_from_roles=1

case "$mode" in
  stop|stopall|--force-stop)
    force_stop=1
    arm_from_roles=0
    ;;
  boot|boot-safe|--boot-safe|apply|start|sync|"")
    arm_from_roles=1
    ;;
  *)
    log "unknown mode '$mode', using apply"
    arm_from_roles=1
    ;;
esac

roles="$(sanitize_roles "$(read_roles)")"
write_roles_if_changed "$roles"

want_isi=0
want_sniff=0
want_fms=0

if [ "$force_stop" -eq 0 ]; then
  for role_word in $roles; do
    case "$role_word" in
      isi)
        want_isi=1
        ;;
      fms)
        want_fms=1
        ;;
      sniff|wireshark|sniffer|sniffer-bridge|ethsniffer)
        want_sniff=1
        ;;
    esac
  done
fi

log "parsed roles='$roles' mode='$mode' flags=ISI:${ISI:-0} WSBR0:${WSBR0:-0} FMS:${FMS:-0} -> isi:$want_isi sniff:$want_sniff fms:$want_fms"

if [ "$force_stop" -eq 1 ]; then
  bridge_runtime_stop
  stop_disable "$SVC_SNIFF"
  stop_disable "$SVC_ISI"
  stop_disable "$SVC_FMS"
  start_enable "$SVC_BRIDGE"
  sleep 1
  stop_disable "$SVC_BRIDGE"
  exit 0
fi

if [ "$want_isi" -eq 1 ] || [ "$want_sniff" -eq 1 ]; then
  [ "$arm_from_roles" -eq 1 ] && bridge_runtime_start
  start_enable "$SVC_BRIDGE"
  sleep 1
else
  bridge_runtime_stop
  stop_disable "$SVC_BRIDGE"
fi

if bridge_runtime_is_armed && [ "$want_sniff" -eq 1 ]; then
  start_enable "$SVC_SNIFF"
else
  stop_disable "$SVC_SNIFF"
fi

if bridge_runtime_is_armed && [ "$want_isi" -eq 1 ]; then
  start_enable "$SVC_ISI"
else
  stop_disable "$SVC_ISI"
fi

if [ "$want_fms" -eq 1 ]; then
  start_enable "$SVC_FMS"
else
  stop_disable "$SVC_FMS"
fi
EOF_SERVSYNC

  chmod 0755 "$SERVSYNC_SCRIPT"
  chown root:root "$SERVSYNC_SCRIPT" 2>/dev/null || true
}

write_rolectl_script() {
  log "Writing $ROLECTL_SCRIPT"

  cat >"$ROLECTL_SCRIPT" <<'EOF_ROLECTL'
#!/usr/bin/env bash
set -euo pipefail

ROLE_FILE="${ROLE_FILE:-/etc/pi_roles.conf}"
SERVSYNC="${SERVSYNC:-/usr/local/bin/pi-servsync.sh}"

usage() {
  cat <<'EOF_USAGE'
Usage:
  sudo pi-rolectl.sh show
  sudo pi-rolectl.sh set [isi] [fms] [sniff]
  sudo pi-rolectl.sh add ROLE...
  sudo pi-rolectl.sh remove ROLE...
  sudo pi-rolectl.sh clear
  sudo pi-rolectl.sh apply
  sudo pi-rolectl.sh stop

Role aliases accepted for sniff:
  sniff wireshark sniffer sniffer-bridge ethsniffer
EOF_USAGE
}

require_root() {
  if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: this action must run as root" >&2
    exit 1
  fi
}

read_roles() {
  local role_text=""

  if [ -r "$ROLE_FILE" ]; then
    # shellcheck disable=SC1090
    . "$ROLE_FILE" || true
    role_text="${ROLES:-${roles:-}}"
  fi

  printf '%s\n' "$role_text" | xargs
}

normalize_role() {
  case "${1,,}" in
    isi)
      printf 'isi\n'
      ;;
    fms)
      printf 'fms\n'
      ;;
    sniff|wireshark|sniffer|sniffer-bridge|ethsniffer)
      printf 'sniff\n'
      ;;
    *)
      return 1
      ;;
  esac
}

normalize_roles() {
  local arg=""
  local normalized=""
  local result=""

  for arg in "$@"; do
    if ! normalized="$(normalize_role "$arg")"; then
      echo "ERROR: unsupported role: $arg" >&2
      exit 2
    fi

    case " $result " in
      *" $normalized "*)
        ;;
      *)
        result="${result:+$result }$normalized"
        ;;
    esac
  done

  printf '%s\n' "$result"
}

write_roles() {
  local role_text="$1"
  local tmp=""

  require_root
  install -d -m 0755 "$(dirname "$ROLE_FILE")"
  tmp="$(mktemp "$(dirname "$ROLE_FILE")/.pi_roles.XXXXXX")"
  printf 'ROLES="%s"\n' "$role_text" >"$tmp"
  install -m 0664 -o root -g initbox "$tmp" "$ROLE_FILE" 2>/dev/null \
    || install -m 0664 -o root -g root "$tmp" "$ROLE_FILE"
  rm -f "$tmp"
}

apply_roles() {
  require_root
  if [ ! -x "$SERVSYNC" ]; then
    echo "ERROR: runtime service controller is missing: $SERVSYNC" >&2
    exit 1
  fi
  "$SERVSYNC" apply
}

cmd="${1:-show}"
shift || true

case "$cmd" in
  show)
    echo "Active InitBox roles: $(read_roles)"
    ;;
  set)
    roles="$(normalize_roles "$@")"
    write_roles "$roles"
    apply_roles
    ;;
  add)
    current="$(read_roles)"
    requested="$(normalize_roles "$@")"
    # shellcheck disable=SC2086
    roles="$(normalize_roles $current $requested)"
    write_roles "$roles"
    apply_roles
    ;;
  remove)
    current="$(read_roles)"
    remove="$(normalize_roles "$@")"
    kept=""
    for role in $current; do
      case " $remove " in
        *" $role "*)
          ;;
        *)
          kept="${kept:+$kept }$role"
          ;;
      esac
    done
    write_roles "$kept"
    apply_roles
    ;;
  clear)
    write_roles ""
    apply_roles
    ;;
  apply)
    apply_roles
    ;;
  stop)
    require_root
    "$SERVSYNC" stopall
    ;;
  -h|--help|help)
    usage
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac
EOF_ROLECTL

  chmod 0755 "$ROLECTL_SCRIPT"
  chown root:root "$ROLECTL_SCRIPT" 2>/dev/null || true
}

write_service() {
  cat >"$SERVSYNC_SERVICE" <<EOF_SERVICE
[Unit]
Description=Apply InitBox runtime roles to field services
After=multi-user.target
Wants=multi-user.target

[Service]
Type=oneshot
ExecStart=$SERVSYNC_SCRIPT boot-safe
RemainAfterExit=yes
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF_SERVICE
}

install_main() {
  require_root
  ensure_log_dir
  ensure_role_file
  ensure_module_flags_file
  write_servsync_script
  write_rolectl_script
  write_service

  systemctl daemon-reload
  systemctl enable pi-servsync.service
  systemctl restart pi-servsync.service || true

  echo
  echo "InitBox runtime control installed"
  echo "---------------------------------"
  echo "Role file:        $ROLE_FILE"
  echo "Module flags:     $MODS_FILE"
  echo "Role CLI:         $ROLECTL_SCRIPT"
  echo "Service sync:     $SERVSYNC_SCRIPT"
  echo
  echo "Examples:"
  echo "  sudo pi-rolectl.sh show"
  echo "  sudo pi-rolectl.sh set isi fms sniff"
  echo "  sudo pi-rolectl.sh clear"

  ok "Runtime Control module installed"
}

uninstall_main() {
  require_root
  ensure_log_dir

  if [ -x "$SERVSYNC_SCRIPT" ]; then
    "$SERVSYNC_SCRIPT" stopall || true
  fi

  systemctl disable --now pi-servsync.service 2>/dev/null || true
  rm -f "$SERVSYNC_SERVICE" "$SERVSYNC_SCRIPT" "$ROLECTL_SCRIPT"
  systemctl daemon-reload
  systemctl reset-failed pi-servsync.service 2>/dev/null || true

  # Keep the role and availability files. They are harmless state and allow a
  # later reinstall to restore the operator's last selection.
  warn "Role/config state was retained under /etc for safe reinstall"
  ok "Runtime Control module uninstalled"
}

main() {
  case "$ACTION" in
    install|"")
      install_main
      ;;
    uninstall|remove)
      uninstall_main
      ;;
    purge)
      warn "purge keeps shared state; running uninstall"
      uninstall_main
      ;;
    *)
      fail "unknown action '$ACTION'; use install or uninstall"
      ;;
  esac
}

main "$@"
