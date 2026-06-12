#!/usr/bin/env bash
set -euo pipefail

# InitBox Pi Zero 2W Wireshark/tshark capture module
#
# Actions:
#   install   Install tshark capture on br0 and log-prep helper.
#   uninstall Remove capture service and helper scripts created by this module.
#   purge     Uninstall and also purge dependency packages.
#
# Notes for Pi Zero 2W:
#   - This module does not manage or create br0.
#   - The ISI module owns br0 on Pi Zero 2W.
#   - Capture service waits for br0 and starts when ISI creates it.

ACTION="${1:-install}"

: "${OWNER:=initbox}"
: "${LOGFILE:=/home/${OWNER}/pi_logs/initbox-install.log}"

TRACE_DIR="${TRACE_DIR:-/usr/tracefiles}"
BOXNO_FILE="${BOXNO_FILE:-/etc/pi-boxno}"
IFACE_FILE="${IFACE_FILE:-/etc/pi-capture.iface}"
DEFAULT_IFACE="${DEFAULT_IFACE:-br0}"
ROLE_FILE="${ROLE_FILE:-/etc/pi_roles.conf}"

WIRESHARK_SCRIPT="/usr/local/bin/wireshark.sh"
LOG_PREP_SCRIPT="/usr/local/bin/log-prep.sh"
WIRESHARK_SERVICE="/etc/systemd/system/wireshark-autostart.service"

# Logging

ts() { date +"%Y-%m-%d %H:%M:%S"; }
log()  { echo "[WS-BR0 $(ts)] $*"        | tee -a "$LOGFILE"; }
ok()   { echo "[WS-BR0 $(ts)] [OK] $*"   | tee -a "$LOGFILE"; }
warn() { echo "[WS-BR0 $(ts)] [WARN] $*" | tee -a "$LOGFILE" >&2; }
err()  { echo "[WS-BR0 $(ts)] [ERR] $*"  | tee -a "$LOGFILE" >&2; }

apt_safe() {
  apt-get -o Dpkg::Use-Pty=0 -o Acquire::Retries=5 "$@" 2>&1 | tee -a "$LOGFILE"
}

require_root() {
  if [ "$(id -u)" -ne 0 ]; then
    err "this module must be run as root"
    exit 1
  fi
}

ensure_log_dir() {
  mkdir -p "$(dirname "$LOGFILE")"
  touch "$LOGFILE"
  chown "$OWNER:$OWNER" "$LOGFILE" 2>/dev/null || true
}

is_pi_zero_like() {
  local model=""
  model="$(tr -d '\0' </proc/device-tree/model 2>/dev/null || echo '')"
  case "$model" in
    *"Zero"*) return 0 ;;
    *) return 1 ;;
  esac
}

install_dependencies() {
  log "Installing tshark capture dependencies"
  apt_safe update

  # Avoid the wireshark-common debconf prompt during module install.
  if command -v debconf-set-selections >/dev/null 2>&1; then
    printf 'wireshark-common wireshark-common/install-setuid boolean true\n' \
      | debconf-set-selections 2>/dev/null || true
  fi

  DEBIAN_FRONTEND=noninteractive apt_safe install -y tshark zip libcap2-bin
}

purge_packages() {
  log "Purging tshark capture dependency packages"
  DEBIAN_FRONTEND=noninteractive apt_safe purge -y tshark wireshark-common zip
  DEBIAN_FRONTEND=noninteractive apt_safe autoremove -y
}

configure_permissions() {
  local dumpcap_bin=""

  log "Ensuring wireshark group and capture permissions"

  getent group wireshark >/dev/null 2>&1 || groupadd -r wireshark || true
  usermod -aG wireshark "$OWNER" 2>/dev/null || true

  dumpcap_bin="$(command -v dumpcap || true)"
  if [ -n "$dumpcap_bin" ]; then
    setcap 'CAP_NET_RAW,CAP_NET_ADMIN=+eip' "$dumpcap_bin" 2>/dev/null \
      || warn "setcap on dumpcap failed; capture may require root"
    chgrp wireshark "$dumpcap_bin" 2>/dev/null || true
    chmod 750 "$dumpcap_bin" 2>/dev/null || true
  else
    warn "dumpcap not found; tshark capture permissions may be limited"
  fi

  install -d -m 0770 -o "$OWNER" -g wireshark "$TRACE_DIR"
}

write_capture_script() {
  log "Writing ${WIRESHARK_SCRIPT}"

  cat >"$WIRESHARK_SCRIPT" <<'CAPTURE_EOF'
#!/usr/bin/env bash
set -euo pipefail
umask 077

TRACE_DIR="${TRACE_DIR:-/usr/tracefiles}"
BOXNO_FILE="${BOXNO_FILE:-/etc/pi-boxno}"
IFACE_FILE="${IFACE_FILE:-/etc/pi-capture.iface}"
DEFAULT_IFACE="${DEFAULT_IFACE:-br0}"
TSHARK_BIN="${TSHARK_BIN:-/usr/bin/tshark}"
WAIT_SECONDS="${WAIT_SECONDS:-120}"

log() { echo "[WS $(date +%F_%T)] $*"; }

mkdir -p "$TRACE_DIR"

BOXNO="$(cat "$BOXNO_FILE" 2>/dev/null || echo 1)"
IFACE="$(cat "$IFACE_FILE" 2>/dev/null || echo "$DEFAULT_IFACE")"
OUT="${TRACE_DIR}/initbox_${BOXNO}.pcap"

if [ ! -x "$TSHARK_BIN" ]; then
  log "ERROR: tshark not found at ${TSHARK_BIN}"
  exit 1
fi

log "Capture target interface: ${IFACE}"
log "Capture output base file: ${OUT}"

while true; do
  waited=0

  while ! ip link show "$IFACE" >/dev/null 2>&1; do
    if [ "$waited" -eq 0 ]; then
      log "Waiting for ${IFACE}; on Pi Zero 2W this is normally created by isirunall.service"
    fi

    waited=$((waited + 1))
    if [ "$waited" -ge "$WAIT_SECONDS" ]; then
      log "${IFACE} still not present after ${WAIT_SECONDS}s; retrying"
      waited=0
    fi

    sleep 1
  done

  log "Starting tshark on ${IFACE}"
  "$TSHARK_BIN" -Q -i "$IFACE" -f ip \
    -b files:80 -b filesize:50000 \
    -w "$OUT" || true

  log "tshark exited; restarting after delay"
  sleep 5
done
CAPTURE_EOF

  chmod 755 "$WIRESHARK_SCRIPT"
  chown root:wireshark "$WIRESHARK_SCRIPT" 2>/dev/null || true
}

write_log_prep_script() {
  log "Writing ${LOG_PREP_SCRIPT}"

  cat >"$LOG_PREP_SCRIPT" <<'LOG_PREP_EOF'
#!/usr/bin/env bash
set -euo pipefail

TRACE_DIR="${TRACE_DIR:-/usr/tracefiles}"
BOXNO_FILE="${BOXNO_FILE:-/etc/pi-boxno}"
ROLE_FILE="${ROLE_FILE:-/etc/pi_roles.conf}"
SVC_SNIFF="${SVC_SNIFF:-wireshark-autostart.service}"

BOXNO="$(cat "$BOXNO_FILE" 2>/dev/null || echo 1)"
ARCHIVE="${ARCHIVE:-initbox_${BOXNO}_$(date +%Y%m%d).zip}"
OWNER_USER="${SUDO_USER:-$(logname 2>/dev/null || echo initbox)}"
OWNER_GROUP="$OWNER_USER"

log() { echo "[log-prep] $*"; }

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

roles="$(read_roles)"
want_sniff=0

if [ -n "$roles" ]; then
  for word in $roles; do
    case "$word" in
      sniff|wireshark)
        want_sniff=1
        ;;
    esac
  done
fi

log "roles='${roles}' -> want_sniff=${want_sniff}"
mkdir -p "$TRACE_DIR"

echo "[log-prep] pcap files preparation ..."

if systemctl is-active --quiet "$SVC_SNIFF"; then
  log "$SVC_SNIFF active before prep; stopping it"
else
  log "$SVC_SNIFF inactive before prep"
fi

systemctl stop "$SVC_SNIFF" 2>/dev/null || true

shopt -s nullglob
files=("$TRACE_DIR"/*.pcap "$TRACE_DIR"/*.pcapng "$TRACE_DIR"/*.pcap.gz "$TRACE_DIR"/*.pcapng.gz)

if [ "${#files[@]}" -eq 0 ]; then
  echo "[log-prep] No capture files found in ${TRACE_DIR}."
else
  echo "[log-prep] Compressing ${#files[@]} file(s) into ${TRACE_DIR}/${ARCHIVE} ..."
  zip -j -q "${TRACE_DIR}/${ARCHIVE}" "${files[@]}"
  chown "$OWNER_USER:$OWNER_GROUP" "${TRACE_DIR}/${ARCHIVE}" 2>/dev/null || true
  echo "[log-prep] Deleting original capture files ..."
  rm -f -- "${files[@]}"
fi

chown "$OWNER_USER:$OWNER_GROUP" "$TRACE_DIR" 2>/dev/null || true
echo "[log-prep] Files are stored at: ${TRACE_DIR}"

if [ "$want_sniff" -eq 1 ]; then
  log "Restarting $SVC_SNIFF"
  systemctl start "$SVC_SNIFF" 2>/dev/null || true
else
  log "Not restarting $SVC_SNIFF because sniff role is not enabled"
fi

echo "[log-prep] ... preparation completed."
LOG_PREP_EOF

  chmod 755 "$LOG_PREP_SCRIPT"
  chown root:root "$LOG_PREP_SCRIPT" 2>/dev/null || true
}

write_service() {
  log "Writing ${WIRESHARK_SERVICE}"

  cat >"$WIRESHARK_SERVICE" <<SERVICE_EOF
[Unit]
Description=InitBox tshark capture on br0 for Pi Zero 2W
After=network-online.target isirunall.service
Wants=network-online.target

[Service]
Type=simple
User=${OWNER}
Group=wireshark
ExecStart=${WIRESHARK_SCRIPT}
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
SERVICE_EOF
}

start_service() {
  systemctl daemon-reload
  systemctl enable wireshark-autostart.service 2>/dev/null || true
  systemctl restart wireshark-autostart.service
}

stop_service() {
  systemctl disable --now wireshark-autostart.service 2>/dev/null || true
  systemctl reset-failed wireshark-autostart.service 2>/dev/null || true
}

remove_files() {
  log "Removing tshark capture files"
  rm -f "$WIRESHARK_SCRIPT" "$LOG_PREP_SCRIPT" "$WIRESHARK_SERVICE"
  systemctl daemon-reload
}

print_install_summary() {
  cat <<SUMMARY_EOF

Pi Zero 2W Wireshark/tshark capture installed
---------------------------------------------
Service : wireshark-autostart.service
Capture : ${WIRESHARK_SCRIPT}
Log prep: ${LOG_PREP_SCRIPT}
Output  : ${TRACE_DIR}/initbox_<boxno>.pcap
Default : capture on br0

Important Pi Zero 2W behavior:
  - This module does not create or manage br0.
  - The ISI module creates br0.
  - tshark waits for br0 and starts capturing when br0 exists.
  - Use /etc/pi-capture.iface to override the capture interface.

Check status:
  sudo systemctl status wireshark-autostart.service --no-pager
  sudo journalctl -u wireshark-autostart.service -n 100 --no-pager
  ls -lh ${TRACE_DIR}
SUMMARY_EOF
}

install_main() {
  require_root
  ensure_log_dir

  if ! is_pi_zero_like; then
    warn "This module is intended for Pi Zero/Zero 2W; continuing anyway."
  fi

  install_dependencies
  configure_permissions
  write_capture_script
  write_log_prep_script
  write_service
  start_service
  print_install_summary
  ok "Pi Zero 2W Wireshark/tshark capture module installed."
}

uninstall_main() {
  require_root
  ensure_log_dir
  stop_service
  remove_files
  ok "Pi Zero 2W Wireshark/tshark capture module uninstalled."
}

purge_main() {
  require_root
  ensure_log_dir
  stop_service
  remove_files
  purge_packages
  ok "Pi Zero 2W Wireshark/tshark capture module purged."
}

main() {
  case "$ACTION" in
    install|"") install_main ;;
    uninstall|remove) uninstall_main ;;
    purge) purge_main ;;
    *)
      err "Unknown action '${ACTION}'. Use: install, uninstall, purge."
      exit 1
      ;;
  esac
}

main "$@"
