#!/usr/bin/env bash
set -euo pipefail

# InitBox Pi Zero W / Zero 2W tshark capture module
#
# Actions:
#   install   Install tshark capture on br0 and log-prep helper.
#   uninstall Remove capture service and helper scripts created by this module.
#   remove    Alias for uninstall.
#   purge     Compatibility alias for uninstall. It does not purge packages.
#
# Notes for Pi Zero W / Zero 2W:
#   - This module does not manage or create br0.
#   - The ISI module owns br0.
#   - The capture service waits for br0 and starts when ISI creates it.
#
# Offline field-mode policy:
#   - Debian packages are installed from the InitBox local package cache.
#   - Uninstall removes services/config/runtime files only.
#   - Purge is disabled and behaves like uninstall.
#   - Installed packages and cached .deb files are kept.

ACTION="${1:-install}"

: "${OWNER:=initbox}"
: "${LOGFILE:=/home/${OWNER}/pi_logs/initbox-install.log}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${INITBOX_REPO_ROOT:-$(cd "$SCRIPT_DIR/../.." && pwd)}"

INITBOX_PACKAGES_FILE="${INITBOX_PACKAGES_FILE:-$REPO_ROOT/scripts/packages.txt}"
INITBOX_PACKAGE_CACHE_DIR="${INITBOX_PACKAGE_CACHE_DIR:-/opt/initbox/packages}"
PACKAGES_LIB_FILE="$REPO_ROOT/scripts/lib/packages.sh"

TRACE_DIR="${TRACE_DIR:-/usr/tracefiles}"
BOXNO_FILE="${BOXNO_FILE:-/etc/pi-boxno}"
IFACE_FILE="${IFACE_FILE:-/etc/pi-capture.iface}"
DEFAULT_IFACE="${DEFAULT_IFACE:-br0}"
ROLE_FILE="${ROLE_FILE:-/etc/pi_roles.conf}"

WIRESHARK_SCRIPT="/usr/local/bin/wireshark.sh"
LOG_PREP_SCRIPT="/usr/local/bin/log-prep.sh"
WIRESHARK_SERVICE="/etc/systemd/system/wireshark-autostart.service"

# ----------------------------------------------------------------------------
# Logging
# ----------------------------------------------------------------------------

ts() {
  date +"%Y-%m-%d %H:%M:%S"
}

log() {
  echo "[WS-BR0 $(ts)] $*" | tee -a "$LOGFILE"
}

ok() {
  echo "[WS-BR0 $(ts)] [OK] $*" | tee -a "$LOGFILE"
}

warn() {
  echo "[WS-BR0 $(ts)] [WARN] $*" | tee -a "$LOGFILE" >&2
}

err() {
  echo "[WS-BR0 $(ts)] [ERR] $*" | tee -a "$LOGFILE" >&2
}

# ----------------------------------------------------------------------------
# Shared helpers
# ----------------------------------------------------------------------------

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

  model="$(tr -d '\0' </proc/device-tree/model 2>/dev/null || echo "")"

  case "$model" in
    *"Zero"*)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

load_package_helper() {
  if [ ! -f "$PACKAGES_LIB_FILE" ]; then
    err "package helper missing: $PACKAGES_LIB_FILE"
    exit 1
  fi

  # shellcheck disable=SC1090
  . "$PACKAGES_LIB_FILE"

  if ! declare -F initbox_packages_install >/dev/null 2>&1; then
    err "package helper does not define initbox_packages_install"
    exit 1
  fi
}

# ----------------------------------------------------------------------------
# Dependency management
# ----------------------------------------------------------------------------

preseed_wireshark_debconf() {
  if command -v debconf-set-selections >/dev/null 2>&1; then
    printf 'wireshark-common wireshark-common/install-setuid boolean true\n' \
      | debconf-set-selections 2>/dev/null || true
  fi
}

install_dependencies() {
  log "Installing tshark capture dependencies from InitBox package cache"
  log "packages file: $INITBOX_PACKAGES_FILE"
  log "cache dir:     $INITBOX_PACKAGE_CACHE_DIR"

  preseed_wireshark_debconf
  load_package_helper

  initbox_packages_install \
    "$INITBOX_PACKAGES_FILE" \
    "$INITBOX_PACKAGE_CACHE_DIR" \
    tshark \
    zip \
    libcap2-bin

  preseed_wireshark_debconf

  if command -v dpkg-reconfigure >/dev/null 2>&1 && dpkg -s wireshark-common >/dev/null 2>&1; then
    DEBIAN_FRONTEND=noninteractive dpkg-reconfigure -f noninteractive wireshark-common 2>/dev/null || true
  fi
}

# ----------------------------------------------------------------------------
# Capture permissions
# ----------------------------------------------------------------------------

configure_permissions() {
  local dumpcap_bin=""

  log "Ensuring wireshark group and capture permissions"

  getent group wireshark >/dev/null 2>&1 || groupadd -r wireshark || true

  if id "$OWNER" >/dev/null 2>&1; then
    usermod -aG wireshark "$OWNER" 2>/dev/null || true
  else
    warn "owner user does not exist: $OWNER"
  fi

  dumpcap_bin="$(command -v dumpcap || true)"

  if [ -n "$dumpcap_bin" ]; then
    chgrp wireshark "$dumpcap_bin" 2>/dev/null || true
    chmod 750 "$dumpcap_bin" 2>/dev/null || true

    if command -v setcap >/dev/null 2>&1; then
      setcap cap_net_raw,cap_net_admin=eip "$dumpcap_bin" 2>/dev/null \
        || warn "setcap on dumpcap failed; capture may require root"
    else
      warn "setcap command is missing; capture may require root"
    fi

    if command -v getcap >/dev/null 2>&1; then
      log "dumpcap capabilities: $(getcap "$dumpcap_bin" 2>/dev/null || true)"
    fi
  else
    warn "dumpcap not found; tshark capture permissions may be limited"
  fi

  install -d -m 0770 -o "$OWNER" -g wireshark "$TRACE_DIR"
}

# ----------------------------------------------------------------------------
# Capture runner
# ----------------------------------------------------------------------------

write_capture_script() {
  log "Writing ${WIRESHARK_SCRIPT}"

  cat >"$WIRESHARK_SCRIPT" <<'CAPTURE_EOF'
#!/usr/bin/env bash
set -euo pipefail
umask 007

TRACE_DIR="${TRACE_DIR:-/usr/tracefiles}"
BOXNO_FILE="${BOXNO_FILE:-/etc/pi-boxno}"
IFACE_FILE="${IFACE_FILE:-/etc/pi-capture.iface}"
DEFAULT_IFACE="${DEFAULT_IFACE:-br0}"
TSHARK_BIN="${TSHARK_BIN:-/usr/bin/tshark}"
WAIT_LOG_INTERVAL="${WAIT_LOG_INTERVAL:-30}"
RESTART_DELAY="${RESTART_DELAY:-5}"

log() {
  echo "[WS $(date +%F_%T)] $*"
}

read_capture_interface() {
  local iface=""

  iface="$(cat "$IFACE_FILE" 2>/dev/null || true)"
  iface="${iface//$'\r'/}"

  if [ -z "$iface" ]; then
    iface="$DEFAULT_IFACE"
  fi

  printf '%s\n' "$iface"
}

read_box_number() {
  local boxno=""

  boxno="$(cat "$BOXNO_FILE" 2>/dev/null || true)"
  boxno="${boxno//$'\r'/}"

  if [ -z "$boxno" ]; then
    boxno="1"
  fi

  printf '%s\n' "$boxno"
}

wait_for_interface() {
  local iface="$1"
  local waited=0

  while ! ip link show "$iface" >/dev/null 2>&1; do
    if [ "$waited" -eq 0 ]; then
      log "Waiting for ${iface}; on Pi Zero W / Zero 2W this is normally created by isirunall.service"
    fi

    sleep 1
    waited=$((waited + 1))

    if [ "$waited" -ge "$WAIT_LOG_INTERVAL" ]; then
      log "${iface} still not present after ${WAIT_LOG_INTERVAL}s; continuing to wait"
      waited=0
    fi
  done
}

mkdir -p "$TRACE_DIR"

if [ ! -x "$TSHARK_BIN" ]; then
  log "ERROR: tshark not found or not executable at ${TSHARK_BIN}"
  exit 1
fi

while true; do
  BOXNO="$(read_box_number)"
  IFACE="$(read_capture_interface)"
  OUT="${TRACE_DIR}/initbox_${BOXNO}.pcap"

  log "Capture target interface: ${IFACE}"
  log "Capture output base file: ${OUT}"

  wait_for_interface "$IFACE"

  log "Interface ${IFACE} is present"
  ip -br link show "$IFACE" 2>/dev/null || true

  log "Starting tshark on ${IFACE}"

  set +e
  "$TSHARK_BIN" \
    -n \
    -i "$IFACE" \
    -f ip \
    -b files:80 \
    -b filesize:50000 \
    -w "$OUT"
  status="$?"
  set -e

  log "tshark exited with status ${status}; restarting after ${RESTART_DELAY}s"

  if [ "$status" -ne 0 ]; then
    log "If this repeats, check dumpcap permissions:"
    log "  getcap /usr/bin/dumpcap"
    log "  id"
    log "  ip link show ${IFACE}"
  fi

  sleep "$RESTART_DELAY"
done
CAPTURE_EOF

  chmod 755 "$WIRESHARK_SCRIPT"
  chown root:wireshark "$WIRESHARK_SCRIPT" 2>/dev/null || true
}

# ----------------------------------------------------------------------------
# Log preparation helper
# ----------------------------------------------------------------------------

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
BOXNO="${BOXNO//$'\r'/}"
ARCHIVE="${ARCHIVE:-initbox_${BOXNO}_$(date +%Y%m%d).zip}"
OWNER_USER="${SUDO_USER:-$(logname 2>/dev/null || echo initbox)}"
OWNER_GROUP="$OWNER_USER"

log() {
  echo "[log-prep] $*"
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

roles="$(read_roles)"
want_sniff=0

if [ -n "$roles" ]; then
  for word in $roles; do
    case "$word" in
      sniff|wireshark|tshark|capture|sniffer)
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

# ----------------------------------------------------------------------------
# systemd service
# ----------------------------------------------------------------------------

write_service() {
  log "Writing ${WIRESHARK_SERVICE}"

  cat >"$WIRESHARK_SERVICE" <<SERVICE_EOF
[Unit]
Description=InitBox tshark capture on br0 for Pi Zero W / Zero 2W
After=network-online.target isirunall.service
Wants=network-online.target

[Service]
Type=simple
User=${OWNER}
Group=wireshark
SupplementaryGroups=wireshark
Environment=TRACE_DIR=${TRACE_DIR}
Environment=BOXNO_FILE=${BOXNO_FILE}
Environment=IFACE_FILE=${IFACE_FILE}
Environment=DEFAULT_IFACE=${DEFAULT_IFACE}
ExecStart=${WIRESHARK_SCRIPT}
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal
NoNewPrivileges=no
CapabilityBoundingSet=CAP_NET_RAW CAP_NET_ADMIN
AmbientCapabilities=CAP_NET_RAW CAP_NET_ADMIN

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

# ----------------------------------------------------------------------------
# Summaries
# ----------------------------------------------------------------------------

print_install_summary() {
  cat <<SUMMARY_EOF

Pi Zero W / Zero 2W tshark capture installed
--------------------------------------------
Service : wireshark-autostart.service
Capture : ${WIRESHARK_SCRIPT}
Log prep: ${LOG_PREP_SCRIPT}
Output  : ${TRACE_DIR}/initbox_<boxno>.pcap
Default : capture on br0

Important Pi Zero W / Zero 2W behavior:
  - This module does not create or manage br0.
  - The ISI module creates br0 after the COPILOT 10.x.x.x gate passes.
  - tshark waits for br0 and starts capturing when br0 exists.
  - Use ${IFACE_FILE} to override the capture interface.
  - wireshark-common may be installed automatically as a tshark dependency.
  - uninstall does not remove packages or the offline package cache.
  - purge is disabled and behaves like uninstall.

Check status:
  sudo systemctl status wireshark-autostart.service --no-pager
  sudo journalctl -u wireshark-autostart.service -n 100 --no-pager
  getcap /usr/bin/dumpcap
  id ${OWNER}
  ls -lh ${TRACE_DIR}
SUMMARY_EOF
}

print_uninstall_summary() {
  cat <<SUMMARY_EOF

Pi Zero W / Zero 2W tshark capture uninstalled
----------------------------------------------
Removed:
  - wireshark-autostart.service
  - ${WIRESHARK_SCRIPT}
  - ${LOG_PREP_SCRIPT}

Not removed:
  - tshark / wireshark-common packages
  - dependency packages
  - cached .deb files under ${INITBOX_PACKAGE_CACHE_DIR}
  - capture files under ${TRACE_DIR}
SUMMARY_EOF
}

# ----------------------------------------------------------------------------
# Actions
# ----------------------------------------------------------------------------

install_main() {
  require_root
  ensure_log_dir

  if ! is_pi_zero_like; then
    warn "This module is intended for Pi Zero W / Zero 2W; continuing anyway."
  fi

  install_dependencies
  configure_permissions
  write_capture_script
  write_log_prep_script
  write_service
  start_service
  print_install_summary
  ok "Pi Zero W / Zero 2W tshark capture module installed."
}

uninstall_main() {
  require_root
  ensure_log_dir
  stop_service
  remove_files
  print_uninstall_summary
  ok "Pi Zero W / Zero 2W tshark capture module uninstalled."
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
      warn "purge is disabled by offline field-mode policy; running uninstall only"
      uninstall_main
      ;;
    *)
      err "Unknown action '${ACTION}'. Use: install or uninstall."
      exit 1
      ;;
  esac
}

main "$@"
