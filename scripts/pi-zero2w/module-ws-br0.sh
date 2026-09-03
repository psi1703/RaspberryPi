#!/usr/bin/env bash
# InitBox Pi Zero W / Zero 2W Sniffer / Bridge capture module
#
# Actions:
#   install    Install and enable br0 tshark capture service.
#   uninstall  Remove capture service/scripts created by this module.
#   remove     Alias for uninstall.
#   purge      Compatibility alias for uninstall. It does not purge packages.
#
# Policy:
#   - ISI owns br0 creation.
#   - This module never creates br0.
#   - This module never enslaves Ethernet ports.
#   - This module never writes NetworkManager, dnsmasq, dhcpcd, or bridge config.
#   - This module waits for br0 and captures only when br0 exists.
#   - Capture filenames use initbox_<boxno>_YYYYMMDDHHMMSS.pcap.
#  - Capture uses dumpcap directly to reduce CPU/RAM versus tshark.
#   - /usr/tracefiles is a local field-capture directory, not a mount.

set -euo pipefail

ACTION="${1:-install}"

: "${OWNER:=initbox}"
: "${CAPTURE_INTERFACE:=br0}"
: "${TRACE_DIR:=/usr/tracefiles}"
: "${CAPTURE_PREFIX:=initbox}"
: "${LOGFILE:=/home/${OWNER}/pi_logs/initbox-install.log}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${INITBOX_REPO_ROOT:-$(cd "$SCRIPT_DIR/../.." && pwd)}"

INITBOX_PACKAGES_FILE="${INITBOX_PACKAGES_FILE:-$REPO_ROOT/scripts/packages.txt}"
INITBOX_PACKAGE_CACHE_DIR="${INITBOX_PACKAGE_CACHE_DIR:-/opt/initbox/packages}"
PACKAGES_LIB_FILE="$REPO_ROOT/scripts/lib/packages.sh"

CAPTURE_RUNNER="/usr/local/bin/initbox-ws-br0-capture.sh"
LOG_PREP="/usr/local/bin/log-prep.sh"
CAPTURE_SERVICE_FILE="/etc/systemd/system/wireshark-autostart.service"

OLD_CAPTURE_SERVICE_FILE="/etc/systemd/system/ws-br0.service"
OLD_CAPTURE_RUNNER="/usr/local/bin/ws-br0.sh"

ts() {
  date '+%Y-%m-%d %H:%M:%S'
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

die() {
  err "$*"
  exit 1
}

require_root() {
  if [ "$(id -u)" -ne 0 ]; then
    die "this module must be run as root"
  fi
}

ensure_log_dir() {
  install -d -m 0755 "$(dirname "$LOGFILE")"
  touch "$LOGFILE"
  chown "$OWNER:$OWNER" "$LOGFILE" 2>/dev/null || true
}

load_package_helper() {
  if [ ! -f "$PACKAGES_LIB_FILE" ]; then
    die "package helper missing: $PACKAGES_LIB_FILE"
  fi

  # shellcheck disable=SC1090
  . "$PACKAGES_LIB_FILE"

  if ! declare -F initbox_packages_install >/dev/null 2>&1; then
    die "package helper does not define initbox_packages_install"
  fi
}

install_dependencies() {
  log "Installing sniffer dependencies from InitBox package cache"
  log "packages file: $INITBOX_PACKAGES_FILE"
  log "cache dir:     $INITBOX_PACKAGE_CACHE_DIR"

  load_package_helper

  initbox_packages_install \
    "$INITBOX_PACKAGES_FILE" \
    "$INITBOX_PACKAGE_CACHE_DIR" \
    tshark \
    iproute2 \
    zip \
    libcap2-bin
}

ensure_trace_dir() {
  install -d -m 1777 "$TRACE_DIR"
  chown root:root "$TRACE_DIR" 2>/dev/null || true
  chmod 1777 "$TRACE_DIR"
}

allow_tshark_capture() {
  local dumpcap_path=""

  dumpcap_path="$(command -v dumpcap || true)"

  if [ -n "$dumpcap_path" ]; then
    log "Granting capture capability to ${dumpcap_path}"
    setcap cap_net_raw,cap_net_admin=eip "$dumpcap_path" 2>/dev/null || true
  else
    warn "dumpcap not found; tshark may require root capture"
  fi
}

write_capture_runner() {
  log "Writing ${CAPTURE_RUNNER}"

  cat >"$CAPTURE_RUNNER" <<'RUNNER_EOF'
#!/usr/bin/env bash
set -euo pipefail

: "${CAPTURE_INTERFACE:=br0}"
: "${TRACE_DIR:=/usr/tracefiles}"
: "${CAPTURE_PREFIX:=initbox}"
: "${BOXNO_FILE:=/etc/pi-boxno}"
: "${WAIT_FOR_BRIDGE_SECONDS:=0}"

log() {
  echo "[WS-BR0 $(date '+%F %T')] $*"
}

prepare_trace_dir() {
  install -d -m 1777 "$TRACE_DIR"
  chown root:root "$TRACE_DIR" 2>/dev/null || true
  chmod 1777 "$TRACE_DIR"
}

get_box_number() {
  local boxno="1"

  if [ -r "$BOXNO_FILE" ]; then
    boxno="$(cat "$BOXNO_FILE" 2>/dev/null || printf '1')"
  fi

  if ! printf '%s\n' "$boxno" | grep -Eq '^[0-9]+$'; then
    boxno="1"
  fi

  printf '%s\n' "$boxno"
}

timestamp_now() {
  date '+%Y%m%d%H%M%S'
}

wait_for_capture_interface() {
  local waited=0

  log "Waiting for capture interface ${CAPTURE_INTERFACE}."
  log "This module does not create ${CAPTURE_INTERFACE}; ISI owns bridge creation."

  while true; do
    if ip link show "$CAPTURE_INTERFACE" >/dev/null 2>&1; then
      ip link set "$CAPTURE_INTERFACE" up 2>/dev/null || true
      log "Capture interface ${CAPTURE_INTERFACE} exists."
      return 0
    fi

    if [ "$WAIT_FOR_BRIDGE_SECONDS" -gt 0 ] && [ "$waited" -ge "$WAIT_FOR_BRIDGE_SECONDS" ]; then
      log "ERROR: capture interface ${CAPTURE_INTERFACE} did not appear within ${WAIT_FOR_BRIDGE_SECONDS}s."
      return 1
    fi

    sleep 2
    waited=$((waited + 2))
  done
}

start_capture() {
  local boxno=""
  local stamp=""
  local capture_file=""

  boxno="$(get_box_number)"
  stamp="$(timestamp_now)"
  capture_file="${TRACE_DIR}/${CAPTURE_PREFIX}_${boxno}_${stamp}.pcap"

  prepare_trace_dir

  log "Starting dumpcap capture"
  log "Interface: ${CAPTURE_INTERFACE}"
  log "Output:    ${capture_file}"

  exec dumpcap \
    -i "$CAPTURE_INTERFACE" \
    -q \
    -w "$capture_file"
}

main() {
  if ! command -v ip >/dev/null 2>&1; then
    log "ERROR: ip command missing"
    exit 1
  fi

  if ! command -v dumpcap >/dev/null 2>&1; then
    log "ERROR: dumpcap command missing"
    exit 1
  fi

  prepare_trace_dir
  wait_for_capture_interface
  start_capture
}

main "$@"
RUNNER_EOF

  chmod 0755 "$CAPTURE_RUNNER"
  chown root:root "$CAPTURE_RUNNER" 2>/dev/null || true
}

write_log_prep() {
  log "Writing ${LOG_PREP}"

  cat >"$LOG_PREP" <<'LOGPREP_EOF'
#!/usr/bin/env bash
set -euo pipefail

: "${TRACE_DIR:=/usr/tracefiles}"
: "${CAPTURE_SERVICE:=wireshark-autostart.service}"
: "${BOXNO_FILE:=/etc/pi-boxno}"
: "${CAPTURE_PREFIX:=initbox}"

log() {
  echo "[LOG-PREP $(date '+%F %T')] $*"
}

prepare_trace_dir() {
  install -d -m 1777 "$TRACE_DIR"
  chown root:root "$TRACE_DIR" 2>/dev/null || true
  chmod 1777 "$TRACE_DIR"
}

get_box_number() {
  local boxno="1"

  if [ -r "$BOXNO_FILE" ]; then
    boxno="$(cat "$BOXNO_FILE" 2>/dev/null || printf '1')"
  fi

  if ! printf '%s\n' "$boxno" | grep -Eq '^[0-9]+$'; then
    boxno="1"
  fi

  printf '%s\n' "$boxno"
}

timestamp_now() {
  date '+%Y%m%d%H%M%S'
}

stop_capture_service() {
  systemctl stop "$CAPTURE_SERVICE" 2>/dev/null || true
}

start_capture_service() {
  systemctl start "$CAPTURE_SERVICE" 2>/dev/null || true
}

main() {
  local boxno=""
  local stamp=""
  local zip_file=""
  local pcap_count=0

  prepare_trace_dir

  boxno="$(get_box_number)"
  stamp="$(timestamp_now)"
  zip_file="${TRACE_DIR}/${CAPTURE_PREFIX}_${boxno}_${stamp}.zip"

  log "Preparing capture ZIP."
  log "Trace dir: ${TRACE_DIR}"
  log "ZIP file:  ${zip_file}"

  stop_capture_service
  prepare_trace_dir

  pcap_count="$(
    find "$TRACE_DIR" -maxdepth 1 -type f -name "${CAPTURE_PREFIX}_${boxno}_*.pcap" | wc -l | tr -d '[:space:]'
  )"

  if [ "$pcap_count" -eq 0 ]; then
    log "No capture files found for box ${boxno}; creating empty marker."
    printf 'No capture files were present at %s\n' "$(date -Iseconds)" >"${TRACE_DIR}/NO_CAPTURE_FILES_${stamp}.txt"

    (
      cd "$TRACE_DIR"
      zip -q -9 "$zip_file" "NO_CAPTURE_FILES_${stamp}.txt"
      rm -f "NO_CAPTURE_FILES_${stamp}.txt"
    )
  else
    log "Found ${pcap_count} capture file(s)."

    (
      cd "$TRACE_DIR"
      zip -q -9 "$zip_file" "${CAPTURE_PREFIX}_${boxno}_"*.pcap
      rm -f "${CAPTURE_PREFIX}_${boxno}_"*.pcap
    )
  fi

  chmod 0644 "$zip_file"

  log "Capture ZIP ready: ${zip_file}"

  start_capture_service

  printf '%s\n' "$zip_file"
}

main "$@"
LOGPREP_EOF

  chmod 0755 "$LOG_PREP"
  chown root:root "$LOG_PREP" 2>/dev/null || true
}

write_capture_service() {
  log "Writing ${CAPTURE_SERVICE_FILE}"

  cat >"$CAPTURE_SERVICE_FILE" <<EOF
[Unit]
Description=InitBox br0 packet capture
After=isirunall.service
Wants=isirunall.service

[Service]
Type=simple
User=root
Environment=CAPTURE_INTERFACE=${CAPTURE_INTERFACE}
Environment=TRACE_DIR=${TRACE_DIR}
Environment=CAPTURE_PREFIX=${CAPTURE_PREFIX}
ExecStartPre=/usr/bin/install -d -m 1777 ${TRACE_DIR}
ExecStartPre=/usr/bin/chown root:root ${TRACE_DIR}
ExecStartPre=/usr/bin/chmod 1777 ${TRACE_DIR}
ExecStart=${CAPTURE_RUNNER}
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
}

remove_old_capture_units() {
  log "Removing old capture units/scripts, if present"

  systemctl disable --now ws-br0.service 2>/dev/null || true
  rm -f "$OLD_CAPTURE_SERVICE_FILE"
  rm -f "$OLD_CAPTURE_RUNNER"
}

enable_capture_service() {
  systemctl daemon-reload
  systemctl enable wireshark-autostart.service
  systemctl restart wireshark-autostart.service || true
}

stop_and_disable_unit() {
  local unit_name="$1"

  log "Stopping and disabling ${unit_name}"
  systemctl disable --now "$unit_name" 2>/dev/null || true
  systemctl reset-failed "$unit_name" 2>/dev/null || true
}

remove_capture_files() {
  log "Removing capture service files"

  rm -f "$CAPTURE_SERVICE_FILE"
  rm -f "$CAPTURE_RUNNER"
  rm -f "$LOG_PREP"
  rm -f "$OLD_CAPTURE_SERVICE_FILE"
  rm -f "$OLD_CAPTURE_RUNNER"
}

print_install_summary() {
  cat <<SUMMARY

Sniffer / Bridge capture installed
----------------------------------
Service:      wireshark-autostart.service
Runner:       ${CAPTURE_RUNNER}
Capture tool: dumpcap
Log prep:     ${LOG_PREP}
Interface:    ${CAPTURE_INTERFACE}
Trace dir:    ${TRACE_DIR}
Pattern:      ${CAPTURE_PREFIX}_<box>_YYYYMMDDHHMMSS.pcap

Bridge ownership:
  - ISI owns br0 creation.
  - This module does not create br0.
  - This module waits for br0 and captures when it exists.
  - No NetworkManager, dnsmasq, dhcpcd, or bridge config is written.
  - No drop-ins are used.
  - /usr/tracefiles is treated as a local capture directory, not a mount.

Capture privilege:
  - The service runs as root and executes dumpcap directly.
  - dumpcap is lighter than tshark for continuous field capture.
  - The capture directory is prepared by the module and by ExecStartPre.

ZIP preparation:
  sudo log-prep.sh

Check service:
  sudo systemctl status wireshark-autostart.service --no-pager
  sudo journalctl -u wireshark-autostart.service -n 100 --no-pager

Check captures:
  ls -lh ${TRACE_DIR}
SUMMARY
}

print_uninstall_summary() {
  cat <<SUMMARY

Sniffer / Bridge capture uninstalled
------------------------------------
Removed:
  - wireshark-autostart.service
  - ${CAPTURE_RUNNER}
  - ${LOG_PREP}
  - old ws-br0.service if present
  - old /usr/local/bin/ws-br0.sh if present

Not removed:
  - dependency packages
  - cached .deb files under ${INITBOX_PACKAGE_CACHE_DIR}
  - existing capture files under ${TRACE_DIR}
  - br0
  - ISI simulator service
SUMMARY
}

install_main() {
  require_root
  ensure_log_dir
  install_dependencies
  ensure_trace_dir
  allow_tshark_capture
  remove_old_capture_units
  write_capture_runner
  write_log_prep
  write_capture_service
  enable_capture_service
  print_install_summary
  ok "Sniffer / Bridge capture module installed."
}

uninstall_main() {
  require_root
  ensure_log_dir
  stop_and_disable_unit "wireshark-autostart.service"
  stop_and_disable_unit "ws-br0.service"
  remove_capture_files
  systemctl daemon-reload
  systemctl reset-failed 2>/dev/null || true
  print_uninstall_summary
  ok "Sniffer / Bridge capture module uninstalled."
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
      die "unknown action '${ACTION}'. Use install or uninstall."
      ;;
  esac
}

main "$@"
