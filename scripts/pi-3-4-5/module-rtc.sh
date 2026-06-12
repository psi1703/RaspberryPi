#!/usr/bin/env bash

# InitBox Raspberry Pi 3 / 4 / 5 RTC module
#
# Installs:
#   - I2C enablement for DS3231 RTC
#   - dtoverlay=i2c-rtc,ds3231 boot config
#   - /usr/local/bin/rtc-sync.sh
#   - rtc-sync.service and rtc-sync.timer
#
# Time sources:
#   - COPILOT DateTime: DD.MM.YYYY-HH:MM:SS
#   - COPILOT Time_ISO8601: YYYY-MM-DDTHH:MM:SSZ or offset form
#   - Internet Date headers when available
#   - Hardware RTC fallback when system time is bogus
#
# Actions:
#   install    Install/update RTC sync helper and timer
#   uninstall  Disable/remove RTC sync service/helper created by this module
#   purge      Compatibility alias for uninstall; packages are not purged

set -euo pipefail

ACTION="${1:-install}"

: "${OWNER:=initbox}"

LOG_DIR="/home/${OWNER}/pi_logs"
LOGFILE="${LOGFILE:-${LOG_DIR}/initbox-install.log}"

RTC_SYNC_SCRIPT="/usr/local/bin/rtc-sync.sh"
RTC_SYNC_SERVICE="/etc/systemd/system/rtc-sync.service"
RTC_SYNC_TIMER="/etc/systemd/system/rtc-sync.timer"

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

apt_safe() {
  DEBIAN_FRONTEND=noninteractive apt-get -o Dpkg::Use-Pty=0 -o Acquire::Retries=5 "$@" 2>&1 | tee -a "$LOGFILE"
}

install_packages() {
  log "Installing RTC helper dependencies."

  if ! apt_safe update; then
    err "apt-get update failed."
    exit 1
  fi

  if ! apt_safe install -y i2c-tools util-linux-extra python3-smbus curl; then
    warn "Some RTC helper packages failed to install; continuing where possible."
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

write_rtc_sync_script() {
  log "Writing ${RTC_SYNC_SCRIPT}."

  cat >"$RTC_SYNC_SCRIPT" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

DRIFT_THRESHOLD="${DRIFT_THRESHOLD:-2}"

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

write_rtc_if_present() {
  if ! have_rtc; then
    echo "[RTC] no RTC present"
    return 0
  fi

  if hwclock -w; then
    echo "[RTC] wrote RTC"
  else
    echo "[RTC] failed to write RTC"
    return 1
  fi
}

rtc_to_system_if_bogus() {
  local system_epoch=""
  local rtc_line=""
  local rtc_epoch=""

  if ! have_rtc; then
    return 0
  fi

  system_epoch="$(now_epoch)"

  if [ "$system_epoch" -ge 1483228800 ]; then
    return 0
  fi

  rtc_line="$(hwclock -r 2>/dev/null || true)"

  if [ -z "$rtc_line" ]; then
    return 0
  fi

  rtc_epoch="$(date -d "$rtc_line" +%s 2>/dev/null || echo 0)"

  if [ "$rtc_epoch" -gt 0 ]; then
    apply_epoch_to_system "$rtc_epoch"
    echo "[RTC] restored system time from RTC"
  fi
}

sync_rtc_to_system_if_needed() {
  local system_epoch=""
  local rtc_line=""
  local rtc_epoch=""
  local diff=""

  if ! have_rtc; then
    return 0
  fi

  system_epoch="$(now_epoch)"
  rtc_line="$(hwclock -r 2>/dev/null || true)"

  if [ -z "$rtc_line" ]; then
    return 0
  fi

  rtc_epoch="$(date -d "$rtc_line" +%s 2>/dev/null || echo 0)"

  if [ "$rtc_epoch" -le 0 ]; then
    return 0
  fi

  diff="$(abs_int "$((system_epoch - rtc_epoch))")"

  if [ "$diff" -gt 1 ]; then
    hwclock -w
    echo "[RTC] wrote RTC from system time; drift=${diff}s"
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

maybe_apply() {
  local candidate_epoch="$1"
  local source="$2"
  local system_epoch=""
  local diff=""

  if [ "$candidate_epoch" -le 0 ]; then
    echo "[RTC] ${source} time unavailable"
    return 0
  fi

  system_epoch="$(now_epoch)"
  diff="$(abs_int "$((candidate_epoch - system_epoch))")"

  if [ "$diff" -gt "$DRIFT_THRESHOLD" ]; then
    apply_epoch_to_system "$candidate_epoch"
    write_rtc_if_present
    echo "[RTC] applied from ${source}; drift=${diff}s"
  else
    echo "[RTC] drift ${diff}s <= ${DRIFT_THRESHOLD}s; no update"
  fi
}

usage() {
  cat <<USAGE
Usage:
  rtc-sync.sh
  rtc-sync.sh --iso8601 TIMESTAMP
  rtc-sync.sh --iso TIMESTAMP
  rtc-sync.sh --datetime DD.MM.YYYY-HH:MM:SS

Examples:
  rtc-sync.sh --iso8601 2026-06-12T14:23:00Z
  rtc-sync.sh --datetime 12.06.2026-14:23:00
USAGE
}

case "${1:-}" in
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

    maybe_apply "$epoch" "COPILOT/ISO8601"
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

    maybe_apply "$epoch" "COPILOT/DateTime"
    ;;
  -h|--help|help)
    usage
    ;;
  *)
    rtc_to_system_if_bogus

    epoch="$(net_epoch)"

    if [ "$epoch" -gt 0 ]; then
      maybe_apply "$epoch" "Internet"
    else
      sync_rtc_to_system_if_needed
    fi
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
ExecStart=${RTC_SYNC_SCRIPT}
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
  write_rtc_sync_script
  write_systemd_units
  enable_units

  ok "RTC module installed."
  ok "Helper: ${RTC_SYNC_SCRIPT}"
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

  systemctl daemon-reload

  ok "RTC sync service, timer, and helper removed."
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

Installed helper:
  ${RTC_SYNC_SCRIPT}

Supported COPILOT time inputs:
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
