#!/usr/bin/env bash

# InitBox Raspberry Pi 3 / 4 / 5 sniffer bridge module
#
# Installs:
#   - tshark capture on br0
#   - dynamic br0 bridge manager
#   - log-prep helper for zipping and clearing capture files
#
# Package model:
#   - Uses scripts/lib/packages.sh
#   - With Internet: installs through apt-get and keeps packages cached
#   - Without Internet: installs from local package cache only
#
# Pi 3 / 4 / 5 role model:
#   - The dashboard owns /etc/pi_roles.conf.
#   - Capture starts only when /etc/pi_roles.conf contains a sniffing role.
#   - Accepted sniff roles: sniff, wireshark, sniffer, sniffer-bridge.
#
# Dashboard module availability model:
#   - This module sets WSBR0=1 after install.
#   - This module sets WSBR0=0 after uninstall/purge.
#   - If pi-nodered.service exists, it is restarted after the flag update
#     so the dashboard UI reloads module availability immediately.
#
# Actions:
#   install    Install/update services and helper scripts
#   uninstall  Disable/remove services and helper scripts created by this module
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

TRACE_DIR="${TRACE_DIR:-/usr/tracefiles}"
CAPTURE_IFACE="${CAPTURE_IFACE:-br0}"

WIRESHARK_SCRIPT="/usr/local/bin/wireshark.sh"
LOG_PREP_SCRIPT="/usr/local/bin/log-prep.sh"
BRIDGE_SCRIPT="/usr/local/bin/bridge-check.sh"

WIRESHARK_SERVICE="/etc/systemd/system/wireshark-autostart.service"
BRIDGE_SERVICE="/etc/systemd/system/bridge-check.service"

DASHBOARD_FLAGS_FILE="${DASHBOARD_FLAGS_FILE:-}"
NODERED_SERVICE="${NODERED_SERVICE:-pi-nodered.service}"

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

require_root() {
  if [ "$(id -u)" -ne 0 ]; then
    err "This module must be run as root."
    echo "Run with:"
    echo "  sudo ./scripts/pi-3-4-5/module-ws-br0.sh ${ACTION}"
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
  log "Installing sniffer bridge package requirements through InitBox package cache helper."

  require_package_helper

  log "Preseeding wireshark-common for non-root capture support."
  if command -v debconf-set-selections >/dev/null 2>&1; then
    printf 'wireshark-common wireshark-common/install-setuid boolean true\n' | debconf-set-selections
  else
    warn "debconf-set-selections not found; continuing."
  fi

  if ! bash "$PACKAGES_HELPER" install \
    tshark \
    zip \
    libcap2-bin \
    bridge-utils \
    iproute2 2>&1 | tee -a "$LOGFILE"; then
    err "Sniffer bridge dependency installation failed."
    err "If this Pi is offline, prepare the package cache first with:"
    err "  sudo ./scripts/initbox-installer.sh pi-3-4-5 p"
    exit 1
  fi

  if command -v dpkg-reconfigure >/dev/null 2>&1; then
    log "Reconfiguring wireshark-common non-interactively."
    DEBIAN_FRONTEND=noninteractive dpkg-reconfigure wireshark-common >>"$LOGFILE" 2>&1 || true
  fi
}

dashboard_flags_file_path() {
  local candidate=""

  if [ -n "$DASHBOARD_FLAGS_FILE" ]; then
    printf '%s\n' "$DASHBOARD_FLAGS_FILE"
    return 0
  fi

  for candidate in \
    /etc/initbox/dashboard-modules.env \
    /etc/initbox/dashboard-flags.env \
    /etc/pi-dashboard-modules.env \
    /etc/pi_dashboard_modules.conf; do
    if [ -f "$candidate" ]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done

  printf '%s\n' "/etc/initbox/dashboard-modules.env"
}

ensure_dashboard_flags_file() {
  local flags_file=""
  local flags_dir=""

  flags_file="$(dashboard_flags_file_path)"
  flags_dir="$(dirname "$flags_file")"

  mkdir -p "$flags_dir"

  if [ ! -f "$flags_file" ]; then
    log "Creating dashboard module flags file: ${flags_file}"

    cat >"$flags_file" <<'EOF'
# InitBox dashboard module availability flags
# 1 means the module/control is available in the dashboard.
# 0 means hide or disable the related dashboard control.
FMS=0
WSBR0=0
RTC=0
HOTSPOT=1
DASHBOARD=1
ISI=0
EOF
  fi

  chmod 664 "$flags_file" || true
  chown root:"$OWNER" "$flags_file" 2>/dev/null || true
}

write_dashboard_module_flag() {
  local key="$1"
  local value="$2"
  local flags_file=""
  local tmp_file=""

  ensure_dashboard_flags_file
  flags_file="$(dashboard_flags_file_path)"
  tmp_file="$(mktemp)"

  awk -v key="$key" -v value="$value" '
    BEGIN {
      found = 0
    }

    $0 ~ "^" key "=" {
      print key "=" value
      found = 1
      next
    }

    {
      print
    }

    END {
      if (found == 0) {
        print key "=" value
      }
    }
  ' "$flags_file" >"$tmp_file"

  install -m 0664 "$tmp_file" "$flags_file"
  rm -f "$tmp_file"

  chown root:"$OWNER" "$flags_file" 2>/dev/null || true

  log "Dashboard module flag updated: ${key}=${value} in ${flags_file}"
}

restart_dashboard_if_present() {
  if ! systemctl cat "$NODERED_SERVICE" >/dev/null 2>&1; then
    log "Dashboard Node-RED service not installed; no restart needed."
    return 0
  fi

  if systemctl is-active "$NODERED_SERVICE" >/dev/null 2>&1; then
    log "Restarting ${NODERED_SERVICE} so dashboard UI reloads module flags."
    if systemctl restart "$NODERED_SERVICE"; then
      ok "${NODERED_SERVICE} restarted."
    else
      warn "Failed to restart ${NODERED_SERVICE}."
    fi
    return 0
  fi

  if systemctl is-enabled "$NODERED_SERVICE" >/dev/null 2>&1; then
    log "${NODERED_SERVICE} exists but is not active; starting it so dashboard UI reloads module flags."
    if systemctl restart "$NODERED_SERVICE"; then
      ok "${NODERED_SERVICE} started."
    else
      warn "Failed to start ${NODERED_SERVICE}."
    fi
    return 0
  fi

  log "${NODERED_SERVICE} exists but is disabled/inactive; no dashboard restart needed."
}

ensure_groups_and_permissions() {
  local dumpcap_bin=""

  log "Ensuring wireshark group exists."
  getent group wireshark >/dev/null 2>&1 || groupadd -r wireshark || true

  if id "$OWNER" >/dev/null 2>&1; then
    log "Adding ${OWNER} to wireshark group."
    usermod -aG wireshark "$OWNER" || true
  else
    warn "Owner user does not exist yet: ${OWNER}"
  fi

  dumpcap_bin="$(command -v dumpcap || true)"

  if [ -n "$dumpcap_bin" ]; then
    log "Setting dumpcap capabilities for non-root capture."
    if ! setcap 'cap_net_raw,cap_net_admin=eip' "$dumpcap_bin"; then
      warn "setcap failed on dumpcap; capture may require root."
    fi
  else
    warn "dumpcap not found; tshark capture permissions may be limited."
  fi

  log "Ensuring trace directory exists: ${TRACE_DIR}"

  if id "$OWNER" >/dev/null 2>&1 && getent group wireshark >/dev/null 2>&1; then
    install -d -m 0770 -o "$OWNER" -g wireshark "$TRACE_DIR"
  else
    install -d -m 0770 "$TRACE_DIR"
  fi
}

write_wireshark_script() {
  log "Writing ${WIRESHARK_SCRIPT}."

  cat >"$WIRESHARK_SCRIPT" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

umask 007

TRACE_DIR="${TRACE_DIR:-/usr/tracefiles}"
BOXNO_FILE="${BOXNO_FILE:-/etc/pi-boxno}"
IFACE_FILE="${IFACE_FILE:-/etc/pi-capture.iface}"
ROLE_FILE="${ROLE_FILE:-/etc/pi_roles.conf}"
DEFAULT_IFACE="${DEFAULT_IFACE:-br0}"
TSHARK_BIN="${TSHARK_BIN:-/usr/bin/tshark}"

mkdir -p "$TRACE_DIR"

log() {
  echo "[WS] $*"
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

sniff_role_enabled() {
  local roles=""
  local role_word=""

  roles="$(read_roles)"

  if [ -z "$roles" ]; then
    log "No roles found in ${ROLE_FILE}; sniff capture disabled."
    return 1
  fi

  for role_word in $roles; do
    case "$role_word" in
      sniff|wireshark|sniffer|sniffer-bridge)
        log "Sniff role enabled: ${role_word}"
        return 0
        ;;
    esac
  done

  log "Sniff role not enabled in ${ROLE_FILE}; roles='${roles}'."
  return 1
}

if ! sniff_role_enabled; then
  exit 0
fi

BOXNO="$(cat "$BOXNO_FILE" 2>/dev/null || echo 1)"
IFACE="$(cat "$IFACE_FILE" 2>/dev/null || echo "$DEFAULT_IFACE")"
OUT="${TRACE_DIR}/initbox_${BOXNO}.pcap"

for _ in $(seq 1 60); do
  if ip link show "$IFACE" >/dev/null 2>&1; then
    break
  fi
  log "waiting for ${IFACE}"
  sleep 1
done

if ! ip link show "$IFACE" >/dev/null 2>&1; then
  log "${IFACE} not present; exiting cleanly"
  exit 0
fi

exec "$TSHARK_BIN" -Q -i "$IFACE" -f ip \
  -b files:80 -b filesize:50000 \
  -w "$OUT"
EOF

  chmod 755 "$WIRESHARK_SCRIPT"
  chown "$OWNER:wireshark" "$WIRESHARK_SCRIPT" 2>/dev/null || true
}

write_log_prep_script() {
  log "Writing ${LOG_PREP_SCRIPT}."

  cat >"$LOG_PREP_SCRIPT" <<'EOF'
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

sniff_role_enabled() {
  local roles=""
  local role_word=""

  roles="$(read_roles)"

  if [ -z "$roles" ]; then
    log "roles='' -> want_sniff=0"
    return 1
  fi

  for role_word in $roles; do
    case "$role_word" in
      sniff|wireshark|sniffer|sniffer-bridge)
        log "roles='${roles}' -> want_sniff=1"
        return 0
        ;;
    esac
  done

  log "roles='${roles}' -> want_sniff=0"
  return 1
}

mkdir -p "$TRACE_DIR"

log "pcap files preparation ..."

if systemctl is-active --quiet "$SVC_SNIFF"; then
  log "${SVC_SNIFF} active before prep; stopping it"
else
  log "${SVC_SNIFF} inactive before prep"
fi

systemctl stop "$SVC_SNIFF" 2>/dev/null || true

shopt -s nullglob
files=("$TRACE_DIR"/*.pcap "$TRACE_DIR"/*.pcapng "$TRACE_DIR"/*.pcap.gz "$TRACE_DIR"/*.pcapng.gz)

if [ "${#files[@]}" -eq 0 ]; then
  log "No capture files found in ${TRACE_DIR}."
else
  log "Compressing ${#files[@]} file(s) into ${TRACE_DIR}/${ARCHIVE} ..."
  zip -j -q "${TRACE_DIR}/${ARCHIVE}" "${files[@]}"
  chown "$OWNER_USER:$OWNER_GROUP" "${TRACE_DIR}/${ARCHIVE}" 2>/dev/null || true
  log "Deleting original capture files ..."
  rm -f -- "${files[@]}"
fi

chown "$OWNER_USER:$OWNER_GROUP" "$TRACE_DIR" 2>/dev/null || true
log "Files are stored at: ${TRACE_DIR}"

if sniff_role_enabled; then
  log "Restarting ${SVC_SNIFF} because sniff role is enabled"
  systemctl start "$SVC_SNIFF" 2>/dev/null || true
else
  log "Not restarting ${SVC_SNIFF} because sniff role is not enabled"
fi

log "... preparation completed."
EOF

  chmod 755 "$LOG_PREP_SCRIPT"
  chown "$OWNER:$OWNER" "$LOG_PREP_SCRIPT" 2>/dev/null || true
}

write_bridge_script() {
  log "Writing ${BRIDGE_SCRIPT}."

  cat >"$BRIDGE_SCRIPT" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

BR="${BRIDGE:-br0}"
ROLE_FILE="${ROLE_FILE:-/etc/pi_roles.conf}"
LOOP_SLEEP="${LOOP_SLEEP:-3}"

log() {
  echo "[BRIDGE $(date +%F_%T)] $*"
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

role_enabled() {
  local wanted_role="$1"
  local roles=""
  local role_word=""

  roles="$(read_roles)"

  for role_word in $roles; do
    case "$wanted_role:$role_word" in
      isi:isi)
        return 0
        ;;
      sniff:sniff|sniff:wireshark|sniff:sniffer|sniff:sniffer-bridge)
        return 0
        ;;
    esac
  done

  return 1
}

get_wired_ifs() {
  find /sys/class/net -maxdepth 1 -mindepth 1 -type l -printf '%f\n' \
    | grep -E '^(eth[0-9]+|enx[0-9A-Fa-f]{12}|enp[0-9a-zA-Z]+|end[0-9]+)$' \
    | sort || true
}

carrier_is_up() {
  local iface="$1"

  if [ -r "/sys/class/net/${iface}/carrier" ]; then
    [ "$(cat "/sys/class/net/${iface}/carrier" 2>/dev/null || echo 0)" = "1" ]
    return
  fi

  ip link show "$iface" 2>/dev/null | grep -q "LOWER_UP"
}

list_ports_on_bridge() {
  ip -o link show master "$BR" 2>/dev/null | awk -F': ' '{print $2}' | cut -d'@' -f1
}

detach_existing_ports() {
  local port

  while IFS= read -r port; do
    [ -z "$port" ] && continue
    log "Releasing ${port} from ${BR}."
    ip link set "$port" nomaster 2>/dev/null || true
    ip link set "$port" up 2>/dev/null || true
  done < <(list_ports_on_bridge)
}

ensure_bridge_exists() {
  if ! ip link show "$BR" >/dev/null 2>&1; then
    ip link add name "$BR" type bridge
    log "Created ${BR}."
  fi

  ip addr flush dev "$BR" 2>/dev/null || true
  ip link set "$BR" up 2>/dev/null || true
}

attach_port() {
  local iface="$1"

  ip addr flush dev "$iface" 2>/dev/null || true
  ip link set "$iface" up 2>/dev/null || true
  ip link set "$iface" master "$BR" 2>/dev/null || true
}

teardown_bridge() {
  if ! ip link show "$BR" >/dev/null 2>&1; then
    return 0
  fi

  detach_existing_ports
  ip link set "$BR" down 2>/dev/null || true
  ip link del "$BR" type bridge 2>/dev/null || true
  log "Removed ${BR}."
}

ensure_bridge_for_ports() {
  local ports=("$@")
  local port

  ensure_bridge_exists
  detach_existing_ports

  for port in "${ports[@]}"; do
    attach_port "$port"
  done

  log "${BR} up with ports: ${ports[*]}"
}

while true; do
  mapfile -t all_wired_ifs < <(get_wired_ifs)
  active_wired_ifs=()

  for iface in "${all_wired_ifs[@]}"; do
    if carrier_is_up "$iface"; then
      active_wired_ifs+=("$iface")
    fi
  done

  isi_wanted=0
  sniff_wanted=0

  if role_enabled "isi"; then
    isi_wanted=1
  fi

  if role_enabled "sniff"; then
    sniff_wanted=1
  fi

  if [ "$isi_wanted" -eq 0 ] && [ "$sniff_wanted" -eq 0 ]; then
    teardown_bridge
    log "No ISI/sniff role enabled; bridge not active."
  elif [ "${#active_wired_ifs[@]}" -eq 0 ]; then
    teardown_bridge
    log "No wired interfaces with carrier; bridge not active."
  elif [ "${#active_wired_ifs[@]}" -eq 1 ]; then
    if [ "$isi_wanted" -eq 1 ]; then
      ensure_bridge_for_ports "${active_wired_ifs[0]}"
      log "Single active wired interface bridged for ISI: ${active_wired_ifs[0]}"
    else
      teardown_bridge
      log "Single active wired interface, sniff role only; leaving interface alone."
    fi
  else
    ensure_bridge_for_ports "${active_wired_ifs[@]}"
    log "Multiple active wired interfaces bridged. isi_wanted=${isi_wanted}, sniff_wanted=${sniff_wanted}"
  fi

  sleep "$LOOP_SLEEP"
done
EOF

  chmod 755 "$BRIDGE_SCRIPT"
  chown root:root "$BRIDGE_SCRIPT" 2>/dev/null || true
}

write_services() {
  log "Writing ${WIRESHARK_SERVICE}."

  cat >"$WIRESHARK_SERVICE" <<EOF
[Unit]
Description=InitBox tshark capture on ${CAPTURE_IFACE}
After=network-online.target bridge-check.service
Wants=network-online.target bridge-check.service

[Service]
Type=simple
User=${OWNER}
Group=wireshark
Environment=TRACE_DIR=${TRACE_DIR}
Environment=DEFAULT_IFACE=${CAPTURE_IFACE}
ExecStart=${WIRESHARK_SCRIPT}
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

  log "Writing ${BRIDGE_SERVICE}."

  cat >"$BRIDGE_SERVICE" <<EOF
[Unit]
Description=InitBox dynamic bridge manager for ISI and sniffer capture
After=network-pre.target
Wants=network-pre.target

[Service]
Type=simple
ExecStart=${BRIDGE_SCRIPT}
Restart=on-failure
RestartSec=3
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
}

enable_and_start_services() {
  log "Enabling and starting bridge/capture services."

  systemctl daemon-reload
  systemctl enable bridge-check.service 2>/dev/null || true
  systemctl restart bridge-check.service 2>/dev/null || true
  systemctl enable wireshark-autostart.service 2>/dev/null || true
  systemctl restart wireshark-autostart.service 2>/dev/null || true
}

install_module() {
  require_root
  prepare_log

  log "Starting Pi 3/4/5 sniffer bridge module installation."

  install_packages
  ensure_groups_and_permissions
  write_wireshark_script
  write_log_prep_script
  write_bridge_script
  write_services
  enable_and_start_services

  write_dashboard_module_flag "WSBR0" "1"
  restart_dashboard_if_present

  ok "Sniffer bridge module installed. Captures go to ${TRACE_DIR}."
  ok "Dashboard availability flag set: WSBR0=1"
  ok "Dashboard role file controls capture startup: /etc/pi_roles.conf"
  ok "Use sudo ${LOG_PREP_SCRIPT} to zip and clear capture files."
}

uninstall_module() {
  require_root
  prepare_log

  log "Uninstalling Pi 3/4/5 sniffer bridge module."

  systemctl stop wireshark-autostart.service 2>/dev/null || true
  systemctl disable wireshark-autostart.service 2>/dev/null || true
  systemctl stop bridge-check.service 2>/dev/null || true
  systemctl disable bridge-check.service 2>/dev/null || true

  rm -f "$WIRESHARK_SERVICE"
  rm -f "$BRIDGE_SERVICE"
  rm -f "$WIRESHARK_SCRIPT"
  rm -f "$LOG_PREP_SCRIPT"
  rm -f "$BRIDGE_SCRIPT"

  systemctl daemon-reload

  if ip link show br0 >/dev/null 2>&1; then
    ip link set br0 down 2>/dev/null || true
    ip link del br0 type bridge 2>/dev/null || true
  fi

  write_dashboard_module_flag "WSBR0" "0"
  restart_dashboard_if_present

  ok "Sniffer bridge services and helper scripts removed."
  ok "Dashboard availability flag set: WSBR0=0"
  warn "Installed packages were left in place intentionally."
  warn "Capture files in ${TRACE_DIR} were left in place intentionally."
}

usage() {
  cat <<EOF
Usage:
  sudo ./scripts/pi-3-4-5/module-ws-br0.sh [install|uninstall|purge]

Actions:
  install    Install/update sniffer bridge services
  uninstall  Remove services and helper scripts created by this module
  purge      Compatibility alias for uninstall; packages are not purged

Package cache:
  This module uses:
    scripts/lib/packages.sh

  To prepare package cache in the lab:
    sudo ./scripts/initbox-installer.sh pi-3-4-5 p

Role control:
  The dashboard writes /etc/pi_roles.conf.

  Capture starts only when roles include one of:
    sniff
    wireshark
    sniffer
    sniffer-bridge

  Bridge starts when roles include:
    isi
    or one of the sniff roles above

Dashboard availability:
  This module sets:
    WSBR0=1 on install
    WSBR0=0 on uninstall/purge

  If ${NODERED_SERVICE} exists, it is restarted after the flag update.
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
