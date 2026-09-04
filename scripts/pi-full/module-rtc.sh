#!/usr/bin/env bash

# InitBox Raspberry Pi 3 / 4 / 5 RTC module
#
# Installs:
#   - I2C enablement for DS3231 RTC
#   - dtoverlay=i2c-rtc,ds3231 boot config
#   - /usr/local/bin/rtc-sync.sh
#   - rtc-sync.service and rtc-sync.timer
#   - /etc/initbox/rtc-sync.env policy file
#
# Package model:
#   - Uses scripts/lib/packages.sh
#   - With Internet: installs through apt-get and keeps packages cached
#   - Without Internet: installs from local package cache only
#
# Time policy:
#   - RTC is the normal InitBox field baseline.
#   - COPILOT/ZEITNEHMER time may correct the Pi on the test bench.
#   - COPILOT correction default threshold is 5 seconds.
#   - Large COPILOT jumps are rejected by default to protect capture timestamps.
#   - Internet time is disabled by default in rtc-sync.sh and must be enabled explicitly.
#
# Actions:
#   install    Install/update RTC sync helper and timer
#   uninstall  Disable/remove RTC sync service/helper created by this module
#   purge      Compatibility alias for uninstall; packages are not purged

set -euo pipefail

ACTION="${1:-install}"

: "${OWNER:=initbox}"

SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_PATH")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PACKAGES_HELPER="$REPO_ROOT/scripts/lib/packages.sh"

LOG_DIR="/home/${OWNER}/pi_logs"
LOGFILE="${LOGFILE:-${LOG_DIR}/initbox-install.log}"

RTC_SYNC_SCRIPT="/usr/local/bin/rtc-sync.sh"
RTC_SYNC_SERVICE="/etc/systemd/system/rtc-sync.service"
RTC_SYNC_TIMER="/etc/systemd/system/rtc-sync.timer"
RTC_SYNC_ENV="/etc/initbox/rtc-sync.env"

ts() {
  date +"%Y-%m-%d %H:%M:%S"
}

log() {
  echo "[RTC $(ts)] $*" | tee -a "$LOGFILE"
}

ok() {
  echo "[RTC $(ts)] [OK] $*" | tee -a "$LOGFILE"
}

warn() {
  echo "[RTC $(ts)] [WARN] $*" | tee -a "$LOGFILE" >&2
}

err() {
  echo "[RTC $(ts)] [ERR] $*" | tee -a "$LOGFILE" >&2
}

require_root() {
  if [ "$(id -u)" -ne 0 ]; then
    err "This module must be run as root."
    echo "Run with:"
    echo "  sudo ./scripts/pi-3-4-5/module-rtc.sh ${ACTION}"
    exit 1
  fi
}

prepare_log() {
  mkdir -p "$LOG_DIR"
  touch "$LOGFILE"

  if id "$OWNER" >/dev/null 2>&1; then
    chown -R "$OWNER:$OWNER" "$LOG_DIR" || true
  fi
}

require_package_helper() {
  if [ ! -f "$PACKAGES_HELPER" ]; then
    err "Package helper not found: $PACKAGES_HELPER"
    err "Expected file: scripts/lib/packages.sh"
    exit 1
  fi

  chmod 755 "$PACKAGES_HELPER" 2>/dev/null || true
}

install_packages() {
  log "Installing RTC helper dependencies through InitBox package cache helper."

  require_package_helper

  if ! bash "$PACKAGES_HELPER" install \
    i2c-tools \
    util-linux-extra \
    python3-smbus \
    curl 2>&1 | tee -a "$LOGFILE"; then
    warn "Some RTC helper packages failed to install."
    warn "If this Pi is offline, prepare the package cache first with:"
    warn "  sudo ./scripts/initbox-installer.sh pi-3-4-5 p"
  fi
}

find_boot_config() {
  if [ -f /boot/firmware/config.txt ]; then
    printf '%s\n' "/boot/firmware/config.txt"
  elif [ -f /boot/config.txt ]; then
    printf '%s\n' "/boot/config.txt"
  else
    return 1
  fi
}

patch_rtcds3231_overlay() {
  local cfg=""
  local overlay_line="dtoverlay=i2c-rtc,ds3231"

  if ! cfg="$(find_boot_config)"; then
    warn "No /boot/firmware/config.txt or /boot/config.txt found; cannot configure RTC overlay."
    return 0
  fi

  log "Patching RTC DS3231 overlay in ${cfg}."

  if grep -q 'dtparam=i2c_arm=on' "$cfg"; then
    sed -i '0,/^[#[:space:]]*dtparam=i2c_arm=on.*$/s//dtparam=i2c_arm=on/' "$cfg"

    if ! grep -q "^${overlay_line}\$" "$cfg"; then
      sed -i "0,/^dtparam=i2c_arm=on\$/s//dtparam=i2c_arm=on\n${overlay_line}/" "$cfg"
      log "Ensured dtparam=i2c_arm=on and inserted RTC overlay below it."
    else
      log "RTC overlay already present."
    fi

    log "NOTE: changes to ${cfg} require a reboot before /dev/rtc0 appears."
    return 0
  fi

  if grep -qi 'optional hardware interfaces' "$cfg"; then
    sed -i "0,/optional hardware interfaces/Is//optional hardware interfaces\ndtparam=i2c_arm=on\n${overlay_line}/" "$cfg"
    log "Inserted I2C and RTC overlay below optional hardware interfaces header."
  else
    {
      echo
      echo "# InitBox RTC"
      echo "dtparam=i2c_arm=on"
      echo "$overlay_line"
    } >>"$cfg"
    log "Appended I2C and RTC overlay at end of ${cfg}."
  fi

  log "NOTE: changes to ${cfg} require a reboot before /dev/rtc0 appears."
}

enable_i2c_for_rtc() {
  if command -v raspi-config >/dev/null 2>&1; then
    log "Enabling I2C via raspi-config."

    if raspi-config nonint do_i2c 0 >>"$LOGFILE" 2>&1; then
      log "raspi-config reports I2C enabled."
    else
      warn "raspi-config I2C enable failed; continuing with manual boot config."
    fi
  else
    warn "raspi-config not found; continuing with manual boot config."
  fi

  patch_rtcds3231_overlay

  if [ ! -e /dev/i2c-1 ]; then
    log "Loading i2c-dev module for current boot."

    if modprobe i2c-dev 2>>"$LOGFILE"; then
      log "i2c-dev module loaded."
    else
      warn "modprobe i2c-dev failed; /dev/i2c-1 may only appear after reboot."
    fi
  fi
}

write_rtc_sync_env() {
  log "Writing ${RTC_SYNC_ENV}."

  install -d -m 0755 /etc/initbox

  if [ -f "$RTC_SYNC_ENV" ]; then
    log "Existing ${RTC_SYNC_ENV} found; preserving operator-tuned values."
    return 0
  fi

  cat >"$RTC_SYNC_ENV" <<'EOF'
# InitBox RTC/time-sync policy.
#
# Field rule:
#   RTC is the normal baseline for capture timestamps.
#
# Test-bench rule:
#   When ISI ZEITNEHMER receives COPILOT time, rtc-sync.sh may correct
#   the Pi clock only when drift is greater than COPILOT_DRIFT_THRESHOLD
#   and not greater than MAX_COPILOT_TIME_JUMP.

INITBOX_TIME_AUTHORITY=rtc
ALLOW_COPILOT_TIME_SYNC=1
COPILOT_DRIFT_THRESHOLD=5
MAX_COPILOT_TIME_JUMP=300
INTERNET_TIME_SYNC=0
RTC_CORRECT_SYSTEM=0
EOF

  chmod 644 "$RTC_SYNC_ENV"
  chown root:root "$RTC_SYNC_ENV" || true
}

write_rtc_sync_script() {
  log "Writing ${RTC_SYNC_SCRIPT}."

  cat >"$RTC_SYNC_SCRIPT" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

CONFIG_FILE="${CONFIG_FILE:-/etc/initbox/rtc-sync.env}"

if [ -r "$CONFIG_FILE" ]; then
  # shellcheck disable=SC1090
  . "$CONFIG_FILE" || true
fi

INITBOX_TIME_AUTHORITY="${INITBOX_TIME_AUTHORITY:-rtc}"
ALLOW_COPILOT_TIME_SYNC="${ALLOW_COPILOT_TIME_SYNC:-1}"
COPILOT_DRIFT_THRESHOLD="${COPILOT_DRIFT_THRESHOLD:-5}"
MAX_COPILOT_TIME_JUMP="${MAX_COPILOT_TIME_JUMP:-300}"
INTERNET_TIME_SYNC="${INTERNET_TIME_SYNC:-0}"
RTC_CORRECT_SYSTEM="${RTC_CORRECT_SYSTEM:-0}"
DRIFT_THRESHOLD="${DRIFT_THRESHOLD:-$COPILOT_DRIFT_THRESHOLD}"

now_epoch() {
  date +%s
}

abs_int() {
  local value="${1:-0}"

  if [ "$value" -lt 0 ]; then
    printf '%d\n' "$((-value))"
  else
    printf '%d\n' "$value"
  fi
}

fmt_epoch() {
  local epoch="${1:-0}"

  if [ "$epoch" -gt 0 ]; then
    date -d "@$epoch" '+%Y-%m-%d %H:%M:%S %z' 2>/dev/null || printf 'epoch:%s\n' "$epoch"
  else
    printf 'unavailable\n'
  fi
}

is_positive_int() {
  case "${1:-}" in
    ''|*[!0-9]*) return 1 ;;
    *) [ "$1" -gt 0 ] ;;
  esac
}

to_epoch_iso() {
  local timestamp="$1"

  date -u -d "$timestamp" +%s 2>/dev/null || echo 0
}

to_epoch_datetime() {
  local datetime="$1"
  local date_part=""
  local time_part=""
  local day=""
  local month=""
  local year=""

  date_part="${datetime%%-*}"
  time_part="${datetime#*-}"

  IFS='.' read -r day month year <<EOF_DT
$date_part
EOF_DT

  date -d "${year}-${month}-${day} ${time_part}" +%s 2>/dev/null || echo 0
}

apply_epoch_to_system() {
  local epoch="$1"

  if command -v timedatectl >/dev/null 2>&1; then
    timedatectl set-time "@${epoch}" >/dev/null 2>&1 || date -u -s "@${epoch}" >/dev/null 2>&1
  else
    date -u -s "@${epoch}" >/dev/null 2>&1
  fi
}

have_rtc() {
  if ! command -v hwclock >/dev/null 2>&1; then
    return 1
  fi

  if [ -e /dev/rtc0 ]; then
    return 0
  fi

  if command -v i2cdetect >/dev/null 2>&1; then
    for bus in 1 0; do
      if i2cdetect -y "$bus" 2>/dev/null | grep -q '\b68\b'; then
        return 0
      fi
    done
  fi

  return 1
}

rtc_epoch() {
  local rtc_line=""
  local epoch="0"

  if ! have_rtc; then
    echo 0
    return 0
  fi

  rtc_line="$(hwclock -r 2>/dev/null || true)"

  if [ -n "$rtc_line" ]; then
    epoch="$(date -d "$rtc_line" +%s 2>/dev/null || echo 0)"
  fi

  echo "$epoch"
}

write_rtc_if_present() {
  if ! have_rtc; then
    echo "[RTC] no RTC present"
    return 0
  fi

  if hwclock -w; then
    echo "[RTC] wrote system time to RTC"
  else
    echo "[RTC] failed to write RTC"
    return 1
  fi
}

rtc_to_system_if_bogus() {
  local system_epoch=""
  local rtc_epoch_val=""

  if ! have_rtc; then
    echo "[RTC] no RTC present; cannot restore system time"
    return 0
  fi

  system_epoch="$(now_epoch)"

  if [ "$system_epoch" -ge 1483228800 ]; then
    echo "[RTC] system time is not bogus; no RTC restore needed"
    return 0
  fi

  rtc_epoch_val="$(rtc_epoch)"

  if [ "$rtc_epoch_val" -gt 0 ]; then
    apply_epoch_to_system "$rtc_epoch_val"
    echo "[RTC] restored system time from RTC: $(fmt_epoch "$rtc_epoch_val")"
  else
    echo "[RTC] RTC time unavailable; system time not changed"
  fi
}

check_rtc_drift() {
  local system_epoch=""
  local rtc_epoch_val=""
  local diff=""

  if ! have_rtc; then
    echo "[RTC] no RTC present; drift check skipped"
    return 0
  fi

  system_epoch="$(now_epoch)"
  rtc_epoch_val="$(rtc_epoch)"

  if [ "$rtc_epoch_val" -le 0 ]; then
    echo "[RTC] RTC time unavailable; drift check skipped"
    return 0
  fi

  diff="$(abs_int "$((system_epoch - rtc_epoch_val))")"

  echo "[RTC] authority=${INITBOX_TIME_AUTHORITY} system='$(fmt_epoch "$system_epoch")' rtc='$(fmt_epoch "$rtc_epoch_val")' drift=${diff}s"

  if [ "$RTC_CORRECT_SYSTEM" = "1" ] && [ "$diff" -gt "$DRIFT_THRESHOLD" ]; then
    apply_epoch_to_system "$rtc_epoch_val"
    echo "[RTC] corrected system time from RTC; drift=${diff}s"
  fi
}

net_epoch() {
  local epoch=0
  local header=""
  local current_epoch=""
  local offset=""

  if command -v ntpdate >/dev/null 2>&1; then
    offset="$(ntpdate -q time.google.com 2>/dev/null | awk '/offset/ {print $10; exit}')"

    if [ -n "${offset:-}" ]; then
      current_epoch="$(now_epoch)"
      epoch="$(awk -v now="$current_epoch" -v off="$offset" 'BEGIN{printf "%.0f", now+off}')"

      if [ "$epoch" -gt 0 ]; then
        echo "$epoch"
        return 0
      fi
    fi
  fi

  if command -v curl >/dev/null 2>&1; then
    for url in https://www.google.com https://www.cloudflare.com; do
      header="$(curl -sI --max-time 4 "$url" | awk -F': ' '/^Date: /{print $2; exit}')"

      if [ -n "${header:-}" ]; then
        epoch="$(date -u -d "$header" +%s 2>/dev/null || echo 0)"

        if [ "$epoch" -gt 0 ]; then
          echo "$epoch"
          return 0
        fi
      fi
    done
  fi

  echo 0
}

maybe_apply_epoch() {
  local candidate_epoch="$1"
  local source="$2"
  local threshold="$3"
  local max_jump="$4"
  local system_epoch=""
  local diff=""

  if [ "$candidate_epoch" -le 0 ]; then
    echo "[RTC] ${source} time unavailable"
    return 0
  fi

  system_epoch="$(now_epoch)"
  diff="$(abs_int "$((candidate_epoch - system_epoch))")"

  echo "[RTC] source=${source} candidate='$(fmt_epoch "$candidate_epoch")' system='$(fmt_epoch "$system_epoch")' drift=${diff}s threshold=${threshold}s max_jump=${max_jump}s"

  if [ "$diff" -le "$threshold" ]; then
    echo "[RTC] drift ${diff}s <= ${threshold}s; no update"
    return 0
  fi

  if is_positive_int "$max_jump" && [ "$diff" -gt "$max_jump" ]; then
    echo "[RTC] rejected ${source}; drift=${diff}s exceeds max_jump=${max_jump}s"
    return 0
  fi

  apply_epoch_to_system "$candidate_epoch"
  write_rtc_if_present
  echo "[RTC] applied from ${source}; drift=${diff}s"
}

maybe_apply_copilot() {
  local candidate_epoch="$1"
  local source="$2"

  if [ "$ALLOW_COPILOT_TIME_SYNC" != "1" ]; then
    echo "[RTC] COPILOT sync disabled; compare only"
    maybe_apply_epoch "$candidate_epoch" "$source" 999999999 0
    return 0
  fi

  maybe_apply_epoch "$candidate_epoch" "$source" "$COPILOT_DRIFT_THRESHOLD" "$MAX_COPILOT_TIME_JUMP"
}

maybe_apply_internet() {
  local candidate_epoch="$1"

  if [ "$INTERNET_TIME_SYNC" != "1" ]; then
    echo "[RTC] Internet time sync disabled by policy; no Internet correction attempted"
    return 0
  fi

  maybe_apply_epoch "$candidate_epoch" "Internet" "$DRIFT_THRESHOLD" 0
}

usage() {
  cat <<USAGE
Usage:
  rtc-sync.sh
  rtc-sync.sh --check
  rtc-sync.sh --from-rtc
  rtc-sync.sh --to-rtc
  rtc-sync.sh --internet
  rtc-sync.sh --iso8601 TIMESTAMP
  rtc-sync.sh --iso TIMESTAMP
  rtc-sync.sh --datetime DD.MM.YYYY-HH:MM:SS

Policy defaults:
  RTC is the normal field baseline.
  COPILOT correction is allowed by default only when drift > 5s and <= 300s.
  Internet correction is disabled unless INTERNET_TIME_SYNC=1 or --internet is used.

Examples:
  rtc-sync.sh --iso8601 2026-06-12T14:23:00Z
  rtc-sync.sh --datetime 12.06.2026-14:23:00
  INTERNET_TIME_SYNC=1 rtc-sync.sh --internet
USAGE
}

case "${1:---check}" in
  --iso8601|--iso)
    shift
    timestamp="${1:-}"

    if [ -z "$timestamp" ]; then
      echo "[RTC] ISO timestamp is required"
      exit 2
    fi

    epoch="$(to_epoch_iso "$timestamp")"

    if [ "$epoch" -le 0 ]; then
      echo "[RTC] bad ISO timestamp"
      exit 2
    fi

    maybe_apply_copilot "$epoch" "COPILOT/ISO8601"
    ;;
  --datetime)
    shift
    datetime="${1:-}"

    if [ -z "$datetime" ]; then
      echo "[RTC] DateTime timestamp is required"
      exit 2
    fi

    epoch="$(to_epoch_datetime "$datetime")"

    if [ "$epoch" -le 0 ]; then
      echo "[RTC] bad DateTime timestamp"
      exit 2
    fi

    maybe_apply_copilot "$epoch" "COPILOT/DateTime"
    ;;
  --from-rtc)
    if have_rtc; then
      epoch="$(rtc_epoch)"
      if [ "$epoch" -gt 0 ]; then
        apply_epoch_to_system "$epoch"
        echo "[RTC] set system time from RTC: $(fmt_epoch "$epoch")"
      else
        echo "[RTC] RTC time unavailable"
        exit 1
      fi
    else
      echo "[RTC] no RTC present"
      exit 1
    fi
    ;;
  --to-rtc)
    write_rtc_if_present
    ;;
  --internet)
    epoch="$(net_epoch)"
    if [ "$epoch" -gt 0 ]; then
      maybe_apply_epoch "$epoch" "Internet" "$DRIFT_THRESHOLD" 0
    else
      echo "[RTC] Internet time unavailable"
    fi
    ;;
  --check|"")
    rtc_to_system_if_bogus
    check_rtc_drift
    if [ "$INTERNET_TIME_SYNC" = "1" ]; then
      epoch="$(net_epoch)"
      maybe_apply_internet "$epoch"
    fi
    ;;
  -h|--help|help)
    usage
    ;;
  *)
    echo "[RTC] unknown argument: ${1:-}"
    usage
    exit 2
    ;;
esac
EOF

  chmod 755 "$RTC_SYNC_SCRIPT"
  chown root:root "$RTC_SYNC_SCRIPT" || true
}

write_systemd_units() {
  log "Installing rtc-sync.service and rtc-sync.timer."

  cat >"$RTC_SYNC_SERVICE" <<EOF
[Unit]
Description=InitBox RTC/system clock sync
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
EnvironmentFile=-${RTC_SYNC_ENV}
ExecStart=${RTC_SYNC_SCRIPT} --check
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

  cat >"$RTC_SYNC_TIMER" <<'EOF'
[Unit]
Description=Auto-run InitBox RTC sync

[Timer]
OnBootSec=120
OnUnitActiveSec=3600
Persistent=true

[Install]
WantedBy=timers.target
EOF
}

enable_units() {
  log "Enabling rtc-sync service and timer."

  systemctl daemon-reload
  systemctl enable rtc-sync.service rtc-sync.timer 2>/dev/null || true
  systemctl start rtc-sync.timer 2>/dev/null || true
  systemctl start rtc-sync.service 2>/dev/null || true
}

install_module() {
  require_root
  prepare_log

  log "Starting RTC module installation."

  install_packages
  enable_i2c_for_rtc
  write_rtc_sync_env
  write_rtc_sync_script
  write_systemd_units
  enable_units

  ok "RTC module installed."
  ok "Helper: ${RTC_SYNC_SCRIPT}"
  ok "Policy: ${RTC_SYNC_ENV}"
  warn "If RTC overlay was just added, reboot once so /dev/rtc0 appears."
}

uninstall_module() {
  require_root
  prepare_log

  log "Uninstalling RTC module."

  systemctl stop rtc-sync.timer 2>/dev/null || true
  systemctl disable rtc-sync.timer 2>/dev/null || true

  systemctl stop rtc-sync.service 2>/dev/null || true
  systemctl disable rtc-sync.service 2>/dev/null || true

  rm -f "$RTC_SYNC_TIMER"
  rm -f "$RTC_SYNC_SERVICE"
  rm -f "$RTC_SYNC_SCRIPT"
  rm -f "$RTC_SYNC_ENV"

  systemctl daemon-reload

  ok "RTC sync service, timer, helper, and policy file removed."
  warn "Installed packages were left in place intentionally."
  warn "Boot overlay configuration was left in place intentionally."
}

usage() {
  cat <<EOF
Usage:
  sudo ./scripts/pi-3-4-5/module-rtc.sh [install|uninstall|purge]

Actions:
  install    Install/update RTC sync helper and timer
  uninstall  Remove RTC sync service/helper created by this module
  purge      Compatibility alias for uninstall; packages are not purged

Package cache:
  This module uses:
    scripts/lib/packages.sh

  To prepare package cache in the lab:
    sudo ./scripts/initbox-installer.sh pi-3-4-5 p

Installed helper:
  ${RTC_SYNC_SCRIPT}

Policy file:
  ${RTC_SYNC_ENV}

Supported operations:
  ${RTC_SYNC_SCRIPT} --check
  ${RTC_SYNC_SCRIPT} --from-rtc
  ${RTC_SYNC_SCRIPT} --to-rtc
  ${RTC_SYNC_SCRIPT} --internet
  ${RTC_SYNC_SCRIPT} --iso8601 YYYY-MM-DDTHH:MM:SSZ
  ${RTC_SYNC_SCRIPT} --iso YYYY-MM-DDTHH:MM:SSZ
  ${RTC_SYNC_SCRIPT} --datetime DD.MM.YYYY-HH:MM:SS
EOF
}

case "$ACTION" in
  install)
    install_module
    ;;
  uninstall|remove)
    uninstall_module
    ;;
  purge)
    warn "purge is treated as uninstall; packages are not removed."
    uninstall_module
    ;;
  -h|--help|help)
    usage
    ;;
  *)
    err "Unknown action: ${ACTION}"
    usage
    exit 1
    ;;
esac
