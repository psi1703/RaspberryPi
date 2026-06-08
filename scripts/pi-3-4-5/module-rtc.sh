#!/usr/bin/env bash
set -euo pipefail

: "${OWNER:=initbox}"
: "${LOGFILE:=/home/${OWNER}/pi_logs/initbox-install.log}"

ts(){ date +"%Y-%m-%d %H:%M:%S"; }
log(){  echo "[RTC $(ts)] ""$*""" | tee -a """$LOGFILE"""; }
ok(){   echo "[RTC $(ts)] [OK] ""$*""" | tee -a """$LOGFILE"""; }
warn(){ echo "[RTC $(ts)] [WARN] ""$*""" | tee -a """$LOGFILE""" >&2; }
err(){  echo "[RTC $(ts)] [ERR] ""$*""" | tee -a """$LOGFILE""" >&2; }

apt_safe(){
  apt-get -o Dpkg::Use-Pty=0 -o Acquire::Retries=5 "$@" 2>&1 | tee -a "$LOGFILE"
}

log "Installing RTC helpers …"
apt_safe update -y
apt_safe install -y i2c-tools util-linux-extra python3-smbus || true

# ---------- 2) Patch boot config for RTC-DS3231 ----------
patch_rtcds3231_overlay() {
  local cfg

  if [[ -f /boot/firmware/config.txt ]]; then
    cfg=/boot/firmware/config.txt
  elif [[ -f /boot/config.txt ]]; then
    cfg=/boot/config.txt
  else
    warn "No /boot/firmware/config.txt or /boot/config.txt found; cannot configure RTC-DS3231 overlay."
    return 0
  fi

  log "Patching RTC-DS3231 overlay in ${cfg} …"

  local overlay_line='dtoverlay=i2c-rtc,ds3231'

  #
  # CASE 1: Some form of dtparam=i2c_arm=on is already present
  # (commented or not, with or without spaces).
  #
  if grep -q 'dtparam=i2c_arm=on' "$cfg"; then
    # 1a) Normalize the *first* dtparam line: remove leading '#' and spaces.
    sed -i '0,/^[#[:space:]]*dtparam=i2c_arm=on.*$/s//dtparam=i2c_arm=on/' "$cfg"

    # 1b) Ensure the overlay line exists directly below that first dtparam.
    if ! grep -q "^${overlay_line}\$" "$cfg"; then
      sed -i "0,/^dtparam=i2c_arm=on\$/s//dtparam=i2c_arm=on\n${overlay_line}/" "$cfg"
      log "Ensured dtparam=i2c_arm=on and inserted RTC overlay directly below."
    else
      log "dtparam=i2c_arm=on present and RTC overlay already in ${cfg}; nothing more to do."
    fi

    log "NOTE: Changes to ${cfg} require a REBOOT before /dev/rtc0 will appear."
    return 0
  fi

  #
  # CASE 2: No dtparam=i2c_arm=on found at all (unusual or heavily edited config).
  # Try to insert in a sensible place under the 'optional hardware interfaces' header.
  #
  if grep -q 'optional hardware interfaces' "$cfg"; then
    sed -i "0,/optional hardware interfaces/s//optional hardware interfaces\ndtparam=i2c_arm=on\n${overlay_line}/" "$cfg"
    log "Inserted dtparam=i2c_arm=on and RTC overlay below the 'optional hardware interfaces' header in ${cfg}."
  else
    # Last-resort fallback: append at end, but make it explicit in logs.
    echo 'dtparam=i2c_arm=on' >> "$cfg"
    echo "$overlay_line" >> "$cfg"
    log "Appended dtparam=i2c_arm=on and RTC overlay at end of ${cfg} (no suitable anchor found)."
  fi

  log "NOTE: Changes to ${cfg} require a REBOOT before /dev/rtc0 will appear."
}

# Ensure I2C is enabled and the RTC overlay is in place
enable_i2c_for_rtc() {
  # 1) Let raspi-config do the official "Interface Options → I2C" work if available
  if command -v raspi-config >/dev/null 2>&1; then
    log "Enabling I2C interface via raspi-config (non-interactive) …"
    if raspi-config nonint do_i2c 0 >>"$LOGFILE" 2>&1; then
      log "raspi-config reports I2C interface enabled."
    else
      warn "raspi-config nonint do_i2c 0 failed; continuing with manual I2C/RTC configuration."
    fi
  else
    warn "raspi-config not found; skipping raspi-config I2C step."
  fi

  # 2) Make sure boot config has dtparam + RTC overlay
  patch_rtcds3231_overlay

  # 3) Try to expose /dev/i2c-1 immediately in this boot
  if [[ ! -e /dev/i2c-1 ]]; then
    log "Loading i2c-dev kernel module so /dev/i2c-1 is available now …"
    if modprobe i2c-dev 2>>"$LOGFILE"; then
      log "i2c-dev module loaded."
    else
      warn "modprobe i2c-dev failed; /dev/i2c-1 may only appear after a reboot."
    fi
  fi
}

# Run the I2C + overlay setup now
enable_i2c_for_rtc

# Install rtc-sync.sh

cat > /usr/local/bin/rtc-sync.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

# Policy:
# --iso "YYYY-MM-DDTHH:MM:SSZ" or --datetime "DD.MM.YYYY-HH:MM:SS":
#   treat as COPILOT time. If drift > DRIFT_THRESHOLD (default 2s),
#   set system; if RTC present, also write RTC.
#
# No args:
#   If RTC present and system time is bogus -> restore from RTC.
#   If Internet available -> use net time; if drift > DRIFT_THRESHOLD, set system; write RTC if present.
#   Else stay quiet. Also keep RTC aligned to system if RTC drift > 1s.

DRIFT_THRESHOLD="${DRIFT_THRESHOLD:-2}"

now_epoch() {
  date +%s
}

abs() {
  local v="${1:-0}"
  if (( v < 0 )); then
    printf '%d\n' $((-v))
  else
    printf '%d\n' "$v"
  fi
}

to_epoch_iso() {
  # ISO-8601 like: 2025-11-19T14:23:00Z
  local ts="$1"
  date -u -d "$ts" +%s 2>/dev/null || echo 0
}

to_epoch_dt() {
  # DD.MM.YYYY-HH:MM:SS
  local dt="$1" dpart tpart DD MM YYYY
  dpart="${dt%%-*}"
  tpart="${dt#*-}"
  IFS='.' read -r DD MM YYYY <<<"$dpart"
  date -d "${YYYY}-${MM}-${DD} ${tpart}" +%s 2>/dev/null || echo 0
}

apply_epoch_to_system() {
  local ep="$1"
  if command -v timedatectl >/dev/null 2>&1; then
    timedatectl set-time "@${ep}" >/dev/null 2>&1 || date -u -s "@${ep}" >/dev/null 2>&1
  else
    date -u -s "@${ep}" >/dev/null 2>&1 || return 1
  fi
}

have_rtc(){
  # Must have the hwclock binary
  if ! command -v hwclock >/dev/null 2>&1; then
    return 1
  fi

  # Primary: kernel RTC device
  if [[ -e /dev/rtc0 ]]; then
    return 0
  fi

  # Optional: DS3231 probe on I2C (0x68) if i2c-tools are installed
  if command -v i2cdetect >/dev/null 2>&1; then
    for bus in 1 0; do
      if i2cdetect -y "$bus" 2>/dev/null | grep -q '\b68\b'; then
        return 0
      fi
    done
  fi

  # If we reach here, we don't have a usable RTC
  return 1
}

write_rtc_if_present(){
  have_rtc || { echo "[RTC] no RTC present"; return 0; }
  hwclock -w && echo "[RTC] wrote RTC"
}

rtc_to_system_if_bogus(){
  have_rtc || return 0
  local sys_ep rtcline rtcep
  sys_ep="$(now_epoch)"
  # treat anything before 2017 as "bogus"
  if [[ "$sys_ep" -lt 1483228800 ]]; then
    rtcline="$(hwclock -r 2>/dev/null || true)"
    [[ -z "$rtcline" ]] && return 0
    rtcep="$(date -d "$rtcline" +%s 2>/dev/null || echo 0)"
    [[ "$rtcep" -gt 0 ]] && apply_epoch_to_system "$rtcep" && echo "[RTC] restored system time from RTC"
  fi
}

sync_rtc_to_system_if_needed(){
  have_rtc || return 0
  local now_ep rtcline rtcep diff
  now_ep="$(now_epoch)"
  rtcline="$(hwclock -r 2>/dev/null || true)"
  [[ -z "$rtcline" ]] && return 0
  rtcep="$(date -d "$rtcline" +%s 2>/dev/null || echo 0)"
  [[ "$rtcep" -gt 0 ]] || return 0
  diff="$(abs $((now_ep - rtcep)))"
  if [[ "$diff" -gt 1 ]]; then
    hwclock -w && echo "[RTC] wrote RTC (drift=${diff}s)"
  fi
}

net_epoch(){
  # Quietly try to obtain a network time; return 0 if not available.
  local ep=0 hdr now off
  if command -v ntpdate >/dev/null 2>&1; then
    off="$(ntpdate -q time.google.com 2>/dev/null | awk '/offset/ {print $10; exit}')"
    if [[ -n "${off:-}" ]]; then
      now="$(now_epoch)"
      ep="$(awk -v n="$now" -v o="$off" 'BEGIN{printf "%.0f", n+o}')"
      [[ "$ep" -gt 0 ]] && echo "$ep" && return 0
    fi
  fi
  if command -v curl >/dev/null 2>&1; then
    for url in https://www.google.com https://www.cloudflare.com; do
      hdr="$(curl -sI --max-time 4 "$url" | awk -F': ' '/^Date: /{print $2; exit}')"
      if [[ -n "${hdr:-}" ]]; then
        ep="$(date -u -d "$hdr" +%s 2>/dev/null || echo 0)"
        [[ "$ep" -gt 0 ]] && echo "$ep" && return 0
      fi
    done
  fi
  echo 0
}

maybe_apply(){
  local candidate_ep="$1" source="$2" sys_ep diff
  [[ "$candidate_ep" -gt 0 ]] || { echo "[RTC] $source time unavailable"; return 0; }
  sys_ep="$(now_epoch)"
  diff="$(abs $((candidate_ep - sys_ep)))"
  if [[ "$diff" -gt "$DRIFT_THRESHOLD" ]]; then
    apply_epoch_to_system "$candidate_ep" || return 1
    write_rtc_if_present
    echo "[RTC] applied from $source (drift=${diff}s)"
  else
    echo "[RTC] drift ${diff}s (<=${DRIFT_THRESHOLD}s); no update"
  fi
}

case "${1:-}" in
  --iso)
    shift; ts="${1:-}"; [[ -n "$ts" ]] || { echo "[RTC] --iso needs a timestamp"; exit 2; }
    ep="$(to_epoch_iso "$ts")"; [[ "$ep" -gt 0 ]] || { echo "[RTC] bad ISO timestamp"; exit 2; }
    maybe_apply "$ep" "COPILOT/ISO"
    ;;
  --datetime)
    shift; dt="${1:-}"; [[ -n "$dt" ]] || { echo "[RTC] --datetime needs a timestamp"; exit 2; }
    ep="$(to_epoch_dt "$dt")"; [[ "$ep" -gt 0 ]] || { echo "[RTC] bad DateTime"; exit 2; }
    maybe_apply "$ep" "COPILOT/DateTime"
    ;;
  *)
    rtc_to_system_if_bogus
    ep="$(net_epoch)"
    if [[ "$ep" -gt 0 ]]; then
      maybe_apply "$ep" "Internet"
    else
      sync_rtc_to_system_if_needed
    fi
    ;;
esac
EOF

sudo chmod 755 /usr/local/bin/rtc-sync.sh
chown "$OWNER:$OWNER" /usr/local/bin/rtc-sync.sh || true

log "Installing rtc-sync.service and rtc-sync.timer …"

cat > /etc/systemd/system/rtc-sync.service <<EOF
[Unit]
Description=Unified RTC/system clock sync (handles ISI + sniffer mode)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
User=initbox
Group=initbox
ExecStart=/usr/local/bin/rtc-sync.sh
AmbientCapabilities=CAP_SYS_TIME
CapabilityBoundingSet=CAP_SYS_TIME
NoNewPrivileges=false

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/rtc-sync.timer <<EOF
[Unit]
Description=Auto-run rtc-sync

[Timer]
OnBootSec=120
OnUnitActiveSec=3600
Persistent=true

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable rtc-sync.service rtc-sync.timer
systemctl start rtc-sync.timer
systemctl start rtc-sync.service || true

log "RTC module installed. Check 'journalctl -u rtc-sync.service' for logs."

