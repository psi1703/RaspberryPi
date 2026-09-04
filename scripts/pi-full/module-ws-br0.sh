#!/usr/bin/env bash

# InitBox Raspberry Pi 3 / 4 / 5 sniffer bridge module
#
# Installs:
#   - tshark capture on br0
#   - dynamic br0 bridge manager
#   - IP-free bridge mode for eth0/eth1/br0 while active
#   - NetworkManager unmanaged policy for bridge ports while active
#   - wired bridge cleanup when ISI/sniffer roles are disabled
#   - lab-safe bridge gating so stale sniffer roles do not steal eth0 DHCP
#   - ISI startup bridge creation before namespace DHCP/10.x.x.x validation
#   - single-owner lab DHCP restore: NetworkManager or dhcpcd, never both
#   - log-prep helper for zipping and clearing capture files
#
# Ownership model:
#   - This module owns wired bridge state only:
#       eth0, eth1, enx*, enp*, end*, br0, veth*_host
#   - This module must not configure, repair, flush, or assign wlan0.
#   - wlan0 hotspot IP, hostapd, and dnsmasq are owned by module-hotspot.sh.
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
#   - If initbox-dashboard.service exists, it is restarted after the flag update
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

DHCPCD_CONF="${DHCPCD_CONF:-/etc/dhcpcd.conf}"
UPSTREAM_IFACE="${UPSTREAM_IFACE:-eth0}"

DASHBOARD_FLAGS_FILE="${DASHBOARD_FLAGS_FILE:-}"
DASHBOARD_SERVICE="${DASHBOARD_SERVICE:-initbox-dashboard.service}"

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
  if ! systemctl cat "$DASHBOARD_SERVICE" >/dev/null 2>&1; then
    log "React dashboard service not installed; no restart needed."
    return 0
  fi

  if systemctl is-active "$DASHBOARD_SERVICE" >/dev/null 2>&1; then
    log "Restarting ${DASHBOARD_SERVICE} so dashboard UI reloads module flags."
    if systemctl restart "$DASHBOARD_SERVICE"; then
      ok "${DASHBOARD_SERVICE} restarted."
    else
      warn "Failed to restart ${DASHBOARD_SERVICE}."
    fi
    return 0
  fi

  if systemctl is-enabled "$DASHBOARD_SERVICE" >/dev/null 2>&1; then
    log "${DASHBOARD_SERVICE} exists but is not active; starting it so dashboard UI reloads module flags."
    if systemctl restart "$DASHBOARD_SERVICE"; then
      ok "${DASHBOARD_SERVICE} started."
    else
      warn "Failed to start ${DASHBOARD_SERVICE}."
    fi
    return 0
  fi

  log "${DASHBOARD_SERVICE} exists but is disabled/inactive; no dashboard restart needed."
}

remove_managed_dhcpcd_bridge_block() {
  local tmp_file=""

  if [ ! -f "$DHCPCD_CONF" ]; then
    return 0
  fi

  tmp_file="$(mktemp)"

  awk '
    BEGIN { skip = 0 }

    /^# START INITBOX-BRIDGE-SAFETY$/ {
      skip = 1
      next
    }

    /^# END INITBOX-BRIDGE-SAFETY$/ {
      skip = 0
      next
    }

    skip == 1 {
      next
    }

    /^[[:space:]]*denyinterfaces[[:space:]]+veth\*[[:space:]]*$/ {
      next
    }

    /^[[:space:]]*denyinterfaces[[:space:]]+br0[[:space:]]*$/ {
      next
    }

    {
      print
    }
  ' "$DHCPCD_CONF" >"$tmp_file"

  install -m 0644 "$tmp_file" "$DHCPCD_CONF"
  rm -f "$tmp_file"
}

write_dhcpcd_bridge_safety() {
  local stale_port=""
  local stale_ns=""

  log "Updating ${DHCPCD_CONF} with bridge safety block."

  touch "$DHCPCD_CONF"
  for stale_port in veth1_host veth2_host veth3_host; do
    ip route flush dev "$stale_port" 2>/dev/null || true
    ip addr flush dev "$stale_port" 2>/dev/null || true
    ip link delete "$stale_port" 2>/dev/null || true
  done

  for stale_ns in ns1 ns2 ns3; do
    ip netns delete "$stale_ns" 2>/dev/null || true
  done

  remove_managed_dhcpcd_bridge_block

  cat >>"$DHCPCD_CONF" <<EOF

# START INITBOX-BRIDGE-SAFETY
# br0/veth* are InitBox internal bridge ports.
# dhcpcd must not assign link-local/default routes to them.
denyinterfaces veth*
denyinterfaces br0
# END INITBOX-BRIDGE-SAFETY
EOF
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

safe_boxno() {
  local raw_boxno="$1"

  raw_boxno="${raw_boxno//$'\r'/}"
  raw_boxno="${raw_boxno//$'\n'/}"

  if printf '%s' "$raw_boxno" | grep -Eq '^[0-9A-Za-z_-]+$'; then
    printf '%s' "$raw_boxno"
  else
    printf '1'
  fi
}

if ! sniff_role_enabled; then
  exit 0
fi

BOXNO="$(safe_boxno "$(cat "$BOXNO_FILE" 2>/dev/null || echo 1)")"
IFACE="$(cat "$IFACE_FILE" 2>/dev/null || echo "$DEFAULT_IFACE")"
# Use tshark ring-buffer naming. With base file initbox_<boxno>.pcap and
# -b filesize/-b files, tshark creates files like:
#   initbox_<boxno>_00001_<YYYYMMDDHHMMSS>.pcap
#   initbox_<boxno>_00002_<YYYYMMDDHHMMSS>.pcap
# This preserves the required timestamped filename format and prevents one
# capture file from growing forever.
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

log "Starting rotating capture on ${IFACE}: base=${OUT}, limit=50000KB, files=80"

exec "$TSHARK_BIN" -Q -i "$IFACE" -f ip \
  -F pcap \
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
STAMP="$(date +%Y%m%d%H%M%S)"
ARCHIVE="${ARCHIVE:-initbox_${BOXNO}_${STAMP}.zip}"

OWNER_USER="${SUDO_USER:-$(logname 2>/dev/null || echo initbox)}"
OWNER_GROUP="$OWNER_USER"

log() {
  echo "[log-prep] $*"
}

safe_boxno() {
  local raw_boxno="$1"

  raw_boxno="${raw_boxno//$'\r'/}"
  raw_boxno="${raw_boxno//$'\n'/}"

  if printf '%s' "$raw_boxno" | grep -Eq '^[0-9A-Za-z_-]+$'; then
    printf '%s' "$raw_boxno"
  else
    printf '1'
  fi
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

wait_for_sniff_service_to_stop() {
  local wait_count=0

  while systemctl is-active --quiet "$SVC_SNIFF"; do
    wait_count=$((wait_count + 1))

    if [ "$wait_count" -ge 20 ]; then
      log "${SVC_SNIFF} still active after stop request; continuing cleanup carefully."
      return 0
    fi

    sleep 1
  done
}

kill_leftover_tshark_for_trace_dir() {
  local pid=""

  while IFS= read -r pid; do
    [ -z "$pid" ] && continue
    log "Stopping leftover tshark process writing under ${TRACE_DIR}: pid=${pid}"
    kill "$pid" 2>/dev/null || true
  done < <(pgrep -f "tshark.*${TRACE_DIR}" || true)

  sleep 1

  while IFS= read -r pid; do
    [ -z "$pid" ] && continue
    log "Force-stopping leftover tshark process writing under ${TRACE_DIR}: pid=${pid}"
    kill -9 "$pid" 2>/dev/null || true
  done < <(pgrep -f "tshark.*${TRACE_DIR}" || true)
}

delete_old_archives_before_new_zip() {
  find "$TRACE_DIR" -maxdepth 1 -type f -name 'initbox_*.zip' -print -delete
}

delete_all_capture_files_after_zip() {
  find "$TRACE_DIR" -maxdepth 1 -type f \
    \( \
      -name 'initbox_*.pcap' -o \
      -name 'initbox_*.pcapng' -o \
      -name 'initbox_*.pcap.gz' -o \
      -name 'initbox_*.pcapng.gz' \
    \) \
    -print -delete
}

list_trace_dir() {
  find "$TRACE_DIR" -maxdepth 1 -type f -printf '%f\n' | sort || true
}

BOXNO="$(safe_boxno "$BOXNO")"
ARCHIVE="${ARCHIVE:-initbox_${BOXNO}_${STAMP}.zip}"

mkdir -p "$TRACE_DIR"

log "pcap files preparation ..."

if systemctl is-active --quiet "$SVC_SNIFF"; then
  log "${SVC_SNIFF} active before prep; stopping it"
else
  log "${SVC_SNIFF} inactive before prep"
fi

systemctl stop "$SVC_SNIFF" 2>/dev/null || true
wait_for_sniff_service_to_stop
kill_leftover_tshark_for_trace_dir
sleep 1

log "Trace directory before cleanup:"
list_trace_dir | sed 's/^/[log-prep]   /'

log "Deleting old ZIP files from ${TRACE_DIR} before creating the new archive."
delete_old_archives_before_new_zip | sed 's/^/[log-prep] deleted old zip: /' || true

shopt -s nullglob
files=("$TRACE_DIR"/*.pcap "$TRACE_DIR"/*.pcapng "$TRACE_DIR"/*.pcap.gz "$TRACE_DIR"/*.pcapng.gz)

if [ "${#files[@]}" -eq 0 ]; then
  log "No capture files found in ${TRACE_DIR}."
else
  log "Compressing ${#files[@]} file(s) into ${TRACE_DIR}/${ARCHIVE} ..."
  zip -j -q "${TRACE_DIR}/${ARCHIVE}" "${files[@]}"
  chown "$OWNER_USER:$OWNER_GROUP" "${TRACE_DIR}/${ARCHIVE}" 2>/dev/null || true
  chmod 0664 "${TRACE_DIR}/${ARCHIVE}" 2>/dev/null || true
fi

log "Hard-deleting all old capture files from ${TRACE_DIR} after ZIP creation."
delete_all_capture_files_after_zip | sed 's/^/[log-prep] deleted old capture: /' || true

chown "$OWNER_USER:$OWNER_GROUP" "$TRACE_DIR" 2>/dev/null || true

if sniff_role_enabled; then
  log "Restarting ${SVC_SNIFF} because sniff role is enabled"
  log "New live pcap will be created as: initbox_${BOXNO}_00001_$(date +%Y%m%d%H%M%S).pcap"
  systemctl start "$SVC_SNIFF" 2>/dev/null || true
else
  log "Not restarting ${SVC_SNIFF} because sniff role is not enabled"
fi

sleep 2

log "Trace directory after restart:"
list_trace_dir | sed 's/^/[log-prep]   /'

log "Files are stored at: ${TRACE_DIR}"
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
LOOP_SLEEP_ACTIVE="${LOOP_SLEEP_ACTIVE:-$LOOP_SLEEP}"
LOOP_SLEEP_STEADY="${LOOP_SLEEP_STEADY:-15}"
RESTORE_IFACE="${RESTORE_IFACE:-eth0}"
DHCPCD_CONF="${DHCPCD_CONF:-/etc/dhcpcd.conf}"
NM_UNMANAGED_FILE="${NM_UNMANAGED_FILE:-/etc/NetworkManager/conf.d/99-initbox-bridge-unmanaged.conf}"
RESTORE_DHCP_STATE_DIR="${RESTORE_DHCP_STATE_DIR:-/run/initbox-bridge-restore}"
RESTORE_DHCP_MIN_INTERVAL="${RESTORE_DHCP_MIN_INTERVAL:-60}"
DHCPCD_RELEASE_DIR="${DHCPCD_RELEASE_DIR:-/run/initbox-bridge-dhcpcd-release}"
AUTO_DISABLE_INVALID_ROLES="${AUTO_DISABLE_INVALID_ROLES:-1}"
INVALID_ROLE_GRACE_SECONDS="${INVALID_ROLE_GRACE_SECONDS:-6}"
ISI_STARTUP_GRACE_SECONDS="${ISI_STARTUP_GRACE_SECONDS:-90}"
ISI_STARTUP_STATE_DIR="${ISI_STARTUP_STATE_DIR:-/run/initbox-bridge-isi-startup}"
ROLE_INVALID_STATE_DIR="${ROLE_INVALID_STATE_DIR:-/run/initbox-bridge-invalid-roles}"
BRIDGE_LAST_STATE_FILE="${BRIDGE_LAST_STATE_FILE:-/run/initbox-bridge-last-state}"
VETH_CLEANUP_LOG_FILE="${VETH_CLEANUP_LOG_FILE:-/run/initbox-bridge-veth-cleaned}"

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

write_roles_text() {
  local new_roles="$1"
  local tmp_file=""

  tmp_file="$(mktemp)"

  if [ -f "$ROLE_FILE" ]; then
    awk -v new_roles="$new_roles" '
      BEGIN { found = 0 }

      /^[[:space:]]*ROLES=/ {
        print "ROLES=\"" new_roles "\""
        found = 1
        next
      }

      {
        print
      }

      END {
        if (found == 0) {
          print "ROLES=\"" new_roles "\""
        }
      }
    ' "$ROLE_FILE" >"$tmp_file"
  else
    printf 'ROLES="%s"\n' "$new_roles" >"$tmp_file"
  fi

  install -m 0644 "$tmp_file" "$ROLE_FILE"
  rm -f "$tmp_file"
}

stop_service_if_present() {
  local service_name="$1"

  if command -v systemctl >/dev/null 2>&1 && systemctl cat "$service_name" >/dev/null 2>&1; then
    systemctl stop "$service_name" >/dev/null 2>&1 || true
  fi
}

remove_role_group_from_role_file() {
  local group="$1"
  local reason="$2"
  local roles=""
  local role_word=""
  local new_roles=""
  local removed=0

  roles="$(read_roles)"

  for role_word in $roles; do
    case "$group:$role_word" in
      isi:isi)
        removed=1
        continue
        ;;
      sniff:sniff|sniff:wireshark|sniff:sniffer|sniff:sniffer-bridge)
        removed=1
        continue
        ;;
    esac

    if [ -z "$new_roles" ]; then
      new_roles="$role_word"
    else
      new_roles="${new_roles} ${role_word}"
    fi
  done

  if [ "$removed" -eq 1 ]; then
    write_roles_text "$new_roles"
    log "Auto-disabled ${group} role after invalid topology: ${reason}. New roles='${new_roles}'."

    case "$group" in
      isi)
        stop_service_if_present isirunall.service
        cleanup_isi_runtime_leftovers
        ;;
      sniff)
        stop_service_if_present wireshark-autostart.service
        ;;
    esac

    return 0
  fi

  return 1
}

clear_invalid_role_timer() {
  local group="$1"

  rm -f "${ROLE_INVALID_STATE_DIR}/${group}.first" 2>/dev/null || true
}

invalid_role_grace_elapsed() {
  local group="$1"
  local reason="$2"
  local marker=""
  local now=""
  local first=""

  if [ "$AUTO_DISABLE_INVALID_ROLES" != "1" ]; then
    return 1
  fi

  mkdir -p "$ROLE_INVALID_STATE_DIR"
  marker="${ROLE_INVALID_STATE_DIR}/${group}.first"
  now="$(date +%s)"

  if [ ! -f "$marker" ]; then
    printf '%s\n' "$now" >"$marker"
    log "${group} role invalid; starting ${INVALID_ROLE_GRACE_SECONDS}s auto-disable timer: ${reason}."
    return 1
  fi

  first="$(cat "$marker" 2>/dev/null || echo "$now")"

  if [ $((now - first)) -ge "$INVALID_ROLE_GRACE_SECONDS" ]; then
    return 0
  fi

  log "${group} role invalid but still inside ${INVALID_ROLE_GRACE_SECONDS}s grace: ${reason}."
  return 1
}

maybe_auto_disable_role_group() {
  local group="$1"
  local reason="$2"

  if invalid_role_grace_elapsed "$group" "$reason"; then
    remove_role_group_from_role_file "$group" "$reason"
    clear_invalid_role_timer "$group"
    return 0
  fi

  return 1
}

clear_isi_startup_timer() {
  rm -f "${ISI_STARTUP_STATE_DIR}/isi.first" 2>/dev/null || true
}

isi_startup_grace_elapsed() {
  local reason="$1"
  local marker=""
  local now=""
  local first=""

  if [ "$AUTO_DISABLE_INVALID_ROLES" != "1" ]; then
    return 1
  fi

  mkdir -p "$ISI_STARTUP_STATE_DIR"
  marker="${ISI_STARTUP_STATE_DIR}/isi.first"
  now="$(date +%s)"

  if [ ! -f "$marker" ]; then
    printf '%s
' "$now" >"$marker"
    log "ISI bridge active; waiting up to ${ISI_STARTUP_GRACE_SECONDS}s for namespace DHCP/10.x.x.x validation: ${reason}."
    return 1
  fi

  first="$(cat "$marker" 2>/dev/null || echo "$now")"

  if [ $((now - first)) -ge "$ISI_STARTUP_GRACE_SECONDS" ]; then
    return 0
  fi

  return 1
}

maybe_auto_disable_isi_after_startup() {
  local reason="$1"

  if isi_startup_grace_elapsed "$reason"; then
    remove_role_group_from_role_file "isi" "$reason after startup grace"
    clear_isi_startup_timer
    clear_invalid_role_timer "isi"
    return 0
  fi

  return 1
}

dhcpcd_service_exists() {
  command -v systemctl >/dev/null 2>&1 && systemctl cat dhcpcd.service >/dev/null 2>&1
}

networkmanager_is_active() {
  command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet NetworkManager.service
}

networkmanager_can_manage_iface() {
  local iface="$1"

  command -v nmcli >/dev/null 2>&1 || return 1
  networkmanager_is_active || return 1
  ip link show "$iface" >/dev/null 2>&1 || return 1

  nmcli -t -f DEVICE,STATE device status 2>/dev/null \
    | awk -F: -v iface="$iface" '
      $1 == iface && $2 != "unmanaged" { found = 1 }
      END { exit found == 1 ? 0 : 1 }
    '
}

remove_lab_nm_dhcpcd_block() {
  local tmp_file=""

  if [ ! -f "$DHCPCD_CONF" ]; then
    return 0
  fi

  tmp_file="$(mktemp)"

  awk '
    BEGIN { skip = 0 }

    /^# START INITBOX-LAB-NM-OWNER$/ {
      skip = 1
      next
    }

    /^# END INITBOX-LAB-NM-OWNER$/ {
      skip = 0
      next
    }

    skip == 0 {
      print
    }
  ' "$DHCPCD_CONF" >"$tmp_file"

  install -m 0644 "$tmp_file" "$DHCPCD_CONF"
  rm -f "$tmp_file"
}

ensure_lab_nm_dhcpcd_block() {
  local iface="$1"
  local tmp_file=""

  touch "$DHCPCD_CONF"
  tmp_file="$(mktemp)"

  awk '
    BEGIN { skip = 0 }

    /^# START INITBOX-LAB-NM-OWNER$/ {
      skip = 1
      next
    }

    /^# END INITBOX-LAB-NM-OWNER$/ {
      skip = 0
      next
    }

    skip == 0 {
      print
    }
  ' "$DHCPCD_CONF" >"$tmp_file"

  {
    echo ""
    echo "# START INITBOX-LAB-NM-OWNER"
    echo "# NetworkManager owns the lab uplink. dhcpcd must not also lease it."
    echo "denyinterfaces ${iface}"
    echo "# END INITBOX-LAB-NM-OWNER"
  } >>"$tmp_file"

  if ! cmp -s "$tmp_file" "$DHCPCD_CONF"; then
    install -m 0644 "$tmp_file" "$DHCPCD_CONF"
    log "Updated lab DHCP owner policy: NetworkManager owns ${iface}."
  fi

  rm -f "$tmp_file"
}

release_dhcpcd_for_iface() {
  local iface="$1"

  if command -v dhcpcd >/dev/null 2>&1; then
    dhcpcd -k "$iface" >/dev/null 2>&1 || true
  fi
}

ensure_dhcpcd_running() {
  if networkmanager_can_manage_iface "$RESTORE_IFACE"; then
    ensure_lab_nm_dhcpcd_block "$RESTORE_IFACE"
    release_dhcpcd_for_iface "$RESTORE_IFACE"
    log "NetworkManager owns ${RESTORE_IFACE}; dhcpcd restore skipped for lab uplink."
    return 0
  fi

  remove_lab_nm_dhcpcd_block

  if dhcpcd_service_exists; then
    systemctl start dhcpcd.service >/dev/null 2>&1 || true
  fi
}

remove_active_dhcpcd_block() {
  local tmp_file=""

  if [ ! -f "$DHCPCD_CONF" ]; then
    return 0
  fi

  tmp_file="$(mktemp)"

  awk '
    BEGIN { skip = 0 }

    /^# START INITBOX-BRIDGE-ACTIVE$/ {
      skip = 1
      next
    }

    /^# END INITBOX-BRIDGE-ACTIVE$/ {
      skip = 0
      next
    }

    skip == 0 {
      print
    }
  ' "$DHCPCD_CONF" >"$tmp_file"

  install -m 0644 "$tmp_file" "$DHCPCD_CONF"
  rm -f "$tmp_file"
}

ensure_active_dhcpcd_block() {
  local base_file=""
  local desired_file=""
  local port=""

  base_file="$(mktemp)"
  desired_file="$(mktemp)"

  touch "$DHCPCD_CONF"

  awk '
    BEGIN { skip = 0 }

    /^# START INITBOX-BRIDGE-ACTIVE$/ {
      skip = 1
      next
    }

    /^# END INITBOX-BRIDGE-ACTIVE$/ {
      skip = 0
      next
    }

    skip == 0 {
      print
    }
  ' "$DHCPCD_CONF" >"$base_file"

  cp "$base_file" "$desired_file"

  {
    echo ""
    echo "# START INITBOX-BRIDGE-ACTIVE"
    echo "# Runtime bridge mode guard."
    echo "# While br0 is active, dhcpcd must not manage bridge ports."
    echo "# wlan0 is owned by module-hotspot.sh and is intentionally not managed here."
    echo "denyinterfaces br0"
    echo "denyinterfaces veth*"

    for port in "$@"; do
      [ -z "$port" ] && continue
      echo "denyinterfaces ${port}"
    done

    echo "# END INITBOX-BRIDGE-ACTIVE"
  } >>"$desired_file"

  if ! cmp -s "$desired_file" "$DHCPCD_CONF"; then
    install -m 0644 "$desired_file" "$DHCPCD_CONF"
    log "Updated active bridge dhcpcd policy."
  fi

  rm -f "$base_file" "$desired_file"
}

networkmanager_service_exists() {
  command -v systemctl >/dev/null 2>&1 && systemctl cat NetworkManager.service >/dev/null 2>&1
}

write_networkmanager_unmanaged_policy() {
  local desired_file=""

  if ! command -v nmcli >/dev/null 2>&1 && ! networkmanager_service_exists; then
    return 0
  fi

  mkdir -p "$(dirname "$NM_UNMANAGED_FILE")"
  desired_file="$(mktemp)"

  cat >"$desired_file" <<'EONM'
[keyfile]
unmanaged-devices=interface-name:br0;interface-name:veth*;interface-name:veth*_host;interface-name:eth0;interface-name:eth1;interface-name:enx*;interface-name:enp*;interface-name:end*
EONM

  if ! cmp -s "$desired_file" "$NM_UNMANAGED_FILE" 2>/dev/null; then
    install -m 0644 "$desired_file" "$NM_UNMANAGED_FILE"
    log "Updated NetworkManager unmanaged bridge-port policy."

    if command -v nmcli >/dev/null 2>&1; then
      nmcli general reload >/dev/null 2>&1 || true
    fi
  fi

  rm -f "$desired_file"
}

set_networkmanager_managed_state() {
  local state="$1"
  shift
  local iface=""

  if ! command -v nmcli >/dev/null 2>&1; then
    return 0
  fi

  for iface in "$@"; do
    [ -z "$iface" ] && continue
    ip link show "$iface" >/dev/null 2>&1 || continue
    nmcli device set "$iface" managed "$state" >/dev/null 2>&1 || true
  done
}

get_wired_ifs() {
  local path=""
  local iface=""

  for path in /sys/class/net/eth[0-9]* /sys/class/net/enx* /sys/class/net/enp* /sys/class/net/end[0-9]*; do
    [ -e "$path" ] || continue
    iface="${path##*/}"
    if is_wired_iface "$iface"; then
      printf '%s\n' "$iface"
    fi
  done | sort
}

networkmanager_bridge_ports_unmanaged() {
  local ports=("$@")
  local veth_ports=()
  local port=""

  write_networkmanager_unmanaged_policy

  while IFS= read -r port; do
    [ -z "$port" ] && continue
    veth_ports+=("$port")
  done < <(get_veth_host_ports)

  set_networkmanager_managed_state no "$BR" "${ports[@]}" "${veth_ports[@]}"
}

write_networkmanager_veth_unmanaged_policy() {
  local desired_file=""

  if ! command -v nmcli >/dev/null 2>&1 && ! networkmanager_service_exists; then
    return 0
  fi

  mkdir -p "$(dirname "$NM_UNMANAGED_FILE")"
  desired_file="$(mktemp)"

  cat >"$desired_file" <<'EONM'
[keyfile]
unmanaged-devices=interface-name:br0;interface-name:veth*;interface-name:veth*_host
EONM

  if ! cmp -s "$desired_file" "$NM_UNMANAGED_FILE" 2>/dev/null; then
    install -m 0644 "$desired_file" "$NM_UNMANAGED_FILE"
    log "Updated NetworkManager lab policy: br0/veth stay unmanaged; wired Ethernet may be restored."

    if command -v nmcli >/dev/null 2>&1; then
      nmcli general reload >/dev/null 2>&1 || true
    fi
  fi

  rm -f "$desired_file"
}

networkmanager_restore_lab_mode() {
  local restore_ports=()
  local iface=""
  local port=""

  write_networkmanager_veth_unmanaged_policy

  if ! command -v nmcli >/dev/null 2>&1; then
    return 0
  fi

  while IFS= read -r iface; do
    [ -z "$iface" ] && continue
    restore_ports+=("$iface")
  done < <(get_wired_ifs)

  for port in "${restore_ports[@]}"; do
    nmcli device set "$port" managed yes >/dev/null 2>&1 || true
  done

  while IFS= read -r port; do
    [ -z "$port" ] && continue
    nmcli device set "$port" managed no >/dev/null 2>&1 || true
  done < <(get_veth_host_ports)

  if ip link show "$BR" >/dev/null 2>&1; then
    nmcli device set "$BR" managed no >/dev/null 2>&1 || true
  fi
}
carrier_is_up() {
  local iface="$1"
  local carrier="0"

  if [ -r "/sys/class/net/${iface}/carrier" ]; then
    IFS= read -r carrier <"/sys/class/net/${iface}/carrier" || carrier="0"
    [ "$carrier" = "1" ]
    return
  fi

  ip link show "$iface" 2>/dev/null | grep -q "LOWER_UP"
}

is_wired_iface() {
  local iface="$1"

  printf '%s\n' "$iface" | grep -Eq '^(eth[0-9]+|enx[0-9A-Fa-f]{12}|enp[0-9a-zA-Z]+|end[0-9]+)$'
}

list_ports_on_bridge() {
  ip -o link show master "$BR" 2>/dev/null | awk -F': ' '{print $2}' | cut -d'@' -f1
}

detach_port() {
  local port="$1"

  log "Releasing ${port} from ${BR}."
  ip addr flush dev "$port" 2>/dev/null || true
  ip link set "$port" nomaster 2>/dev/null || true
  ip link set "$port" up 2>/dev/null || true
}

detach_all_ports() {
  local port=""

  while IFS= read -r port; do
    [ -z "$port" ] && continue
    detach_port "$port"
  done < <(list_ports_on_bridge)
}

desired_contains() {
  local needle="$1"
  shift
  local item=""

  for item in "$@"; do
    [ "$item" = "$needle" ] && return 0
  done

  return 1
}

detach_wired_ports_not_desired() {
  local desired=("$@")
  local port=""

  while IFS= read -r port; do
    [ -z "$port" ] && continue

    if ! is_wired_iface "$port"; then
      continue
    fi

    if ! desired_contains "$port" "${desired[@]}"; then
      detach_port "$port"
    fi
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

current_master() {
  local iface="$1"

  if [ -e "/sys/class/net/${iface}/master" ]; then
    basename "$(readlink -f "/sys/class/net/${iface}/master")" 2>/dev/null || true
  fi
}

iface_has_ipv4() {
  local iface="$1"

  ip -4 addr show dev "$iface" 2>/dev/null | grep -q 'inet '
}

iface_has_isi_ipv4() {
  local iface="$1"

  ip -4 addr show dev "$iface" 2>/dev/null | awk '$1 == "inet" {print $2}' | grep -Eq '^10\.'
}

namespace_has_isi_ipv4() {
  local ns="$1"

  ip netns exec "$ns" ip -4 addr show 2>/dev/null | awk '$1 == "inet" {print $2}' | grep -Eq '^10\.'
}

isi_network_present() {
  local iface=""
  local ns_line=""
  local ns=""

  while IFS= read -r iface; do
    [ -z "$iface" ] && continue

    if iface_has_isi_ipv4 "$iface"; then
      return 0
    fi
  done < <(find /sys/class/net -maxdepth 1 -mindepth 1 -type l -printf '%f\n' 2>/dev/null | sort || true)

  if command -v ip >/dev/null 2>&1; then
    while IFS= read -r ns_line; do
      [ -z "$ns_line" ] && continue
      ns="${ns_line%% *}"
      [ -z "$ns" ] && continue

      if namespace_has_isi_ipv4 "$ns"; then
        return 0
      fi
    done < <(ip netns list 2>/dev/null || true)
  fi

  return 1
}

sniffer_topology_present() {
  carrier_is_up eth0 && carrier_is_up eth1
}

dhcpcd_is_tracking_iface() {
  local iface="$1"

  pgrep -af "dhcpcd: .* ${iface}( |$)" >/dev/null 2>&1
}

release_dhcpcd_once() {
  local iface="$1"
  local master_now=""
  local marker=""

  mkdir -p "$DHCPCD_RELEASE_DIR"

  master_now="$(current_master "$iface")"
  marker="${DHCPCD_RELEASE_DIR}/${iface}"

  if [ -f "$marker" ] && [ "$master_now" = "$BR" ] && ! iface_has_ipv4 "$iface" && ! dhcpcd_is_tracking_iface "$iface"; then
    return 0
  fi

  release_dhcpcd_for_iface "$iface"

  : >"$marker"
}

clear_dhcpcd_release_marks() {
  rm -rf "$DHCPCD_RELEASE_DIR" 2>/dev/null || true
}

route_exists_for_dev() {
  local iface="$1"

  ip route show dev "$iface" 2>/dev/null | grep -q .
}

clean_veth_host_network_state() {
  local port=""
  local cleaned=0

  while IFS= read -r port; do
    [ -z "$port" ] && continue

    if command -v nmcli >/dev/null 2>&1; then
      nmcli device set "$port" managed no >/dev/null 2>&1 || true
    fi

    release_dhcpcd_for_iface "$port"

    if iface_has_ipv4 "$port" || route_exists_for_dev "$port"; then
      cleaned=1
      ip route flush dev "$port" 2>/dev/null || true
      ip addr flush dev "$port" 2>/dev/null || true
    fi
  done < <(get_veth_host_ports)

  if [ "$cleaned" -eq 1 ]; then
    if [ ! -f "$VETH_CLEANUP_LOG_FILE" ]; then
      log "Cleaned IP addresses/routes from veth*_host bridge ports."
      : >"$VETH_CLEANUP_LOG_FILE"
    fi
  else
    rm -f "$VETH_CLEANUP_LOG_FILE" 2>/dev/null || true
  fi
}

cleanup_isi_runtime_leftovers() {
  local ns=""
  local port=""

  clean_veth_host_network_state

  while IFS= read -r port; do
    [ -z "$port" ] && continue
    ip link delete "$port" 2>/dev/null || true
  done < <(get_veth_host_ports)

  for ns in ns1 ns2 ns3; do
    ip netns delete "$ns" 2>/dev/null || true
  done

  rm -f "$VETH_CLEANUP_LOG_FILE" 2>/dev/null || true
}

attach_port() {
  local iface="$1"

  release_dhcpcd_once "$iface"

  ip addr flush dev "$iface" 2>/dev/null || true
  ip link set "$iface" up 2>/dev/null || true
  ip link set "$iface" master "$BR" 2>/dev/null || true
  ip addr flush dev "$iface" 2>/dev/null || true
}

force_bridge_ports_ip_free() {
  local port=""

  ip addr flush dev "$BR" 2>/dev/null || true

  while IFS= read -r port; do
    [ -z "$port" ] && continue
    ip route flush dev "$port" 2>/dev/null || true
    ip addr flush dev "$port" 2>/dev/null || true
  done < <(list_ports_on_bridge)

  clean_veth_host_network_state
}
get_veth_host_ports() {
  local path=""

  for path in /sys/class/net/veth*_host; do
    [ -e "$path" ] || continue
    printf '%s\n' "${path##*/}"
  done
}

bridge_exists_fast() {
  [ -d "/sys/class/net/${BR}" ]
}

bridge_member_fast() {
  local port="$1"

  [ -e "/sys/class/net/${BR}/brif/${port}" ]
}

bridge_member_wired_ports_fast() {
  local path=""
  local port=""

  for path in "/sys/class/net/${BR}/brif"/*; do
    [ -e "$path" ] || continue
    port="${path##*/}"
    if is_wired_iface "$port"; then
      printf '%s\n' "$port"
    fi
  done
}

bridge_already_configured_for_ports_fast() {
  local desired_ports=("$@")
  local port=""
  local state_key=""

  bridge_exists_fast || return 1

  for port in "${desired_ports[@]}"; do
    [ -z "$port" ] && continue
    [ -d "/sys/class/net/${port}" ] || return 1
    bridge_member_fast "$port" || return 1
  done

  while IFS= read -r port; do
    [ -z "$port" ] && continue
    if ! desired_contains "$port" "${desired_ports[@]}"; then
      return 1
    fi
  done < <(bridge_member_wired_ports_fast)

  while IFS= read -r port; do
    [ -z "$port" ] && continue
    bridge_member_fast "$port" || return 1
  done < <(get_veth_host_ports)

  state_key="$(printf '%s\n' "${desired_ports[@]}" | sort | paste -sd ' ' -)"
  log_bridge_state_once "active:${state_key}" "${BR} steady with wired ports: ${state_key}"

  return 0
}

log_bridge_state_once() {
  local state="$1"
  local message="$2"
  local last_state=""
  local state_dir=""

  state_dir="$(dirname "$BRIDGE_LAST_STATE_FILE")"
  mkdir -p "$state_dir"

  last_state="$(cat "$BRIDGE_LAST_STATE_FILE" 2>/dev/null || true)"

  if [ "$last_state" != "$state" ]; then
    log "$message"
    printf '%s\n' "$state" >"$BRIDGE_LAST_STATE_FILE"
  fi
}

clear_bridge_state_once() {
  rm -f "$BRIDGE_LAST_STATE_FILE" 2>/dev/null || true
}

bridge_already_configured_for_ports() {
  bridge_already_configured_for_ports_fast "$@"
}

restore_default_interface() {
  local iface="$RESTORE_IFACE"
  local marker=""
  local now=""
  local last="0"

  if ! ip link show "$iface" >/dev/null 2>&1; then
    return 0
  fi

  ip link set "$iface" nomaster 2>/dev/null || true
  ip link set "$iface" up 2>/dev/null || true

  if networkmanager_can_manage_iface "$iface"; then
    ensure_lab_nm_dhcpcd_block "$iface"
    release_dhcpcd_for_iface "$iface"
    nmcli device set "$iface" managed yes >/dev/null 2>&1 || true

    if iface_has_ipv4 "$iface"; then
      rm -f "${RESTORE_DHCP_STATE_DIR}/${iface}.last" 2>/dev/null || true
      log "${iface} has IPv4 under NetworkManager; dhcpcd kept off this interface."
      return 0
    fi

    mkdir -p "$RESTORE_DHCP_STATE_DIR"
    marker="${RESTORE_DHCP_STATE_DIR}/${iface}.last"
    now="$(date +%s)"
    last="$(cat "$marker" 2>/dev/null || echo 0)"

    if [ $((now - last)) -lt "$RESTORE_DHCP_MIN_INTERVAL" ]; then
      log "${iface} has no IPv4; NetworkManager DHCP restore request throttled."
      return 0
    fi

    printf '%s\n' "$now" >"$marker"

    log "${iface} has no IPv4; requesting NetworkManager DHCP restore."
    nmcli device reapply "$iface" >/dev/null 2>&1 \
      || nmcli device connect "$iface" >/dev/null 2>&1 \
      || true

    return 0
  fi

  remove_lab_nm_dhcpcd_block

  if iface_has_ipv4 "$iface"; then
    rm -f "${RESTORE_DHCP_STATE_DIR}/${iface}.last" 2>/dev/null || true
    log "${iface} already has IPv4; no DHCP action needed."
    return 0
  fi

  mkdir -p "$RESTORE_DHCP_STATE_DIR"
  marker="${RESTORE_DHCP_STATE_DIR}/${iface}.last"
  now="$(date +%s)"
  last="$(cat "$marker" 2>/dev/null || echo 0)"

  if [ $((now - last)) -lt "$RESTORE_DHCP_MIN_INTERVAL" ]; then
    log "${iface} has no IPv4; dhcpcd DHCP restore request throttled."
    return 0
  fi

  printf '%s\n' "$now" >"$marker"

  log "${iface} has no IPv4; requesting dhcpcd lab DHCP renewal."
  if command -v dhcpcd >/dev/null 2>&1; then
    dhcpcd -n "$iface" >/dev/null 2>&1 || dhcpcd "$iface" >/dev/null 2>&1 || true
  fi
}

teardown_bridge() {
  clean_veth_host_network_state

  if ! ip link show "$BR" >/dev/null 2>&1; then
    remove_active_dhcpcd_block
    networkmanager_restore_lab_mode
    ensure_dhcpcd_running
    clear_dhcpcd_release_marks
    clear_bridge_state_once
    restore_default_interface
    clean_veth_host_network_state
    return 0
  fi

  detach_all_ports
  ip addr flush dev "$BR" 2>/dev/null || true
  ip link set "$BR" down 2>/dev/null || true
  ip link del "$BR" type bridge 2>/dev/null || true
  remove_active_dhcpcd_block
  networkmanager_restore_lab_mode
  ensure_dhcpcd_running
  clear_dhcpcd_release_marks
  clear_bridge_state_once
  clean_veth_host_network_state
  log "Removed ${BR}."

  restore_default_interface
}
ensure_bridge_for_ports() {
  local ports=("$@")
  local port=""

  clean_veth_host_network_state

  if bridge_already_configured_for_ports "${ports[@]}"; then
    return 0
  fi

  ensure_active_dhcpcd_block "${ports[@]}"
  networkmanager_bridge_ports_unmanaged "${ports[@]}"
  ensure_bridge_exists
  detach_wired_ports_not_desired "${ports[@]}"

  for port in "${ports[@]}"; do
    attach_port "$port"
  done

  while IFS= read -r port; do
    [ -z "$port" ] && continue
    release_dhcpcd_once "$port"
    ip addr flush dev "$port" 2>/dev/null || true
    ip link set "$port" master "$BR" 2>/dev/null || true
    ip link set "$port" up 2>/dev/null || true
    ip addr flush dev "$port" 2>/dev/null || true
  done < <(get_veth_host_ports)

  force_bridge_ports_ip_free

  log "${BR} up with wired ports: ${ports[*]}"
}

if [ "${1:-run}" = "cleanup" ]; then
  teardown_bridge
  log "cleanup action completed"
  exit 0
fi

trap 'teardown_bridge; exit 0' TERM INT HUP

# Expensive ISI validation is latched deliberately.
# Once a 10.x.x.x ISI network has been detected and br0 is steady, do not keep
# running ip-netns probes every loop. In steady state, use only cheap sysfs
# checks for carrier and bridge membership. Revalidate ISI only after the
# bridge/topology stops being steady, the role is turned off/on again, or the
# service restarts.
isi_valid_latched=0
no_carrier_cleanup_done=0
no_role_cleanup_done=0

while true; do
  next_sleep="$LOOP_SLEEP_ACTIVE"

  clean_veth_host_network_state

  mapfile -t all_wired_ifs < <(get_wired_ifs)
  active_wired_ifs=()

  for iface in "${all_wired_ifs[@]}"; do
    if carrier_is_up "$iface"; then
      active_wired_ifs+=("$iface")
    fi
  done

  if [ "${#active_wired_ifs[@]}" -gt 0 ]; then
    no_carrier_cleanup_done=0
  fi

  isi_wanted=0
  sniff_wanted=0

  if role_enabled "isi"; then
    isi_wanted=1
  fi

  if role_enabled "sniff"; then
    sniff_wanted=1
  fi

  if [ "$isi_wanted" -eq 1 ] || [ "$sniff_wanted" -eq 1 ]; then
    no_role_cleanup_done=0
  fi

  isi_network_ok=0
  sniff_topology_ok=0
  bridge_steady=0

  if [ "${#active_wired_ifs[@]}" -gt 0 ] && bridge_already_configured_for_ports "${active_wired_ifs[@]}"; then
    bridge_steady=1
  fi

  if [ "$sniff_wanted" -eq 1 ] && sniffer_topology_present; then
    sniff_topology_ok=1
    clear_invalid_role_timer "sniff"
  fi

  if [ "$isi_wanted" -eq 0 ]; then
    isi_valid_latched=0
    clear_invalid_role_timer "isi"
    clear_isi_startup_timer
  elif [ "$isi_valid_latched" -eq 1 ] && [ "$bridge_steady" -eq 1 ]; then
    isi_network_ok=1
    clear_invalid_role_timer "isi"
    clear_isi_startup_timer
  elif isi_network_present; then
    isi_network_ok=1
    isi_valid_latched=1
    clear_invalid_role_timer "isi"
    clear_isi_startup_timer
  else
    isi_valid_latched=0
  fi

  if [ "$sniff_wanted" -eq 1 ] && [ "$sniff_topology_ok" -eq 0 ]; then
    if maybe_auto_disable_role_group "sniff" "eth0 and eth1 carrier not both present"; then
      sniff_wanted=0
    fi
  fi

  if [ "$isi_wanted" -eq 0 ] && [ "$sniff_wanted" -eq 0 ]; then
    if [ "$no_role_cleanup_done" -eq 0 ]; then
      teardown_bridge
      isi_valid_latched=0
      log "No valid ISI/sniff role enabled; bridge cleanup completed."
      no_role_cleanup_done=1
    else
      clean_veth_host_network_state
    fi
    next_sleep="$LOOP_SLEEP_STEADY"
  elif [ "${#active_wired_ifs[@]}" -eq 0 ]; then
    if [ "$isi_wanted" -eq 1 ]; then
      if maybe_auto_disable_role_group "isi" "no wired interfaces with carrier"; then
        isi_wanted=0
        isi_valid_latched=0
      fi
    fi

    if [ "$no_carrier_cleanup_done" -eq 0 ]; then
      teardown_bridge
      cleanup_isi_runtime_leftovers
      isi_valid_latched=0
      log "No wired interfaces with carrier; bridge not active. Cleaned ISI/veth leftovers."
      no_carrier_cleanup_done=1
    else
      clean_veth_host_network_state
    fi
    next_sleep="$LOOP_SLEEP_STEADY"
  elif [ "$sniff_wanted" -eq 1 ] && [ "$sniff_topology_ok" -eq 1 ]; then
    ensure_bridge_for_ports "${active_wired_ifs[@]}"

    if [ "$isi_wanted" -eq 1 ] && [ "$isi_network_ok" -eq 0 ] && [ "$bridge_steady" -eq 1 ]; then
      if maybe_auto_disable_isi_after_startup "no 10.x.x.x ISI network detected"; then
        isi_wanted=0
        isi_valid_latched=0
      fi
    fi

    if [ "$bridge_steady" -eq 1 ]; then
      next_sleep="$LOOP_SLEEP_STEADY"
    fi
  elif [ "$isi_wanted" -eq 1 ]; then
    # ISI needs br0 before ns1/ns2/ns3 can exist and request COPILOT DHCP.
    # Therefore 10.x.x.x is a post-start validation, not a pre-start gate.
    ensure_bridge_for_ports "${active_wired_ifs[@]}"

    if [ "$isi_network_ok" -eq 0 ] && [ "$bridge_steady" -eq 1 ]; then
      if maybe_auto_disable_isi_after_startup "no 10.x.x.x ISI network detected"; then
        isi_wanted=0
        isi_valid_latched=0
      fi
    fi

    if [ "$bridge_steady" -eq 1 ] && [ "$isi_network_ok" -eq 1 ]; then
      next_sleep="$LOOP_SLEEP_STEADY"
    fi
  else
    teardown_bridge
    isi_valid_latched=0
    clear_isi_startup_timer

    if [ "$sniff_wanted" -eq 1 ]; then
      log "Sniff role enabled but eth0+eth1 topology not detected; preserving lab Ethernet DHCP."
    fi
  fi

  sleep "$next_sleep"
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
Restart=on-failure
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
Environment=RESTORE_IFACE=${UPSTREAM_IFACE}
Environment=DHCPCD_CONF=${DHCPCD_CONF}
Environment=NM_UNMANAGED_FILE=/etc/NetworkManager/conf.d/99-initbox-bridge-unmanaged.conf
Environment=RESTORE_DHCP_MIN_INTERVAL=60
Environment=AUTO_DISABLE_INVALID_ROLES=1
Environment=INVALID_ROLE_GRACE_SECONDS=6
Environment=ISI_STARTUP_GRACE_SECONDS=90
Environment=LOOP_SLEEP_ACTIVE=3
Environment=LOOP_SLEEP_STEADY=15
ExecStart=${BRIDGE_SCRIPT}
Restart=on-failure
RestartSec=3
KillSignal=SIGTERM
TimeoutStopSec=30
ExecStopPost=${BRIDGE_SCRIPT} cleanup
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
  write_dhcpcd_bridge_safety
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
  local tmp_file=""
  local stale_port=""
  local stale_ns=""

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

  if command -v nmcli >/dev/null 2>&1; then
    rm -f /etc/NetworkManager/conf.d/99-initbox-bridge-unmanaged.conf 2>/dev/null || true
    nmcli general reload >/dev/null 2>&1 || true
    nmcli device set eth0 managed yes >/dev/null 2>&1 || true
    nmcli device set eth1 managed yes >/dev/null 2>&1 || true
  fi

  if ip link show br0 >/dev/null 2>&1; then
    while IFS= read -r port; do
      [ -n "$port" ] && ip link set "$port" nomaster 2>/dev/null || true
    done < <(ip -o link show master br0 2>/dev/null | awk -F': ' '{print $2}' | cut -d'@' -f1)

    ip addr flush dev br0 2>/dev/null || true
    ip link set br0 down 2>/dev/null || true
    ip link del br0 type bridge 2>/dev/null || true
  fi

  for stale_port in veth1_host veth2_host veth3_host; do
    ip route flush dev "$stale_port" 2>/dev/null || true
    ip addr flush dev "$stale_port" 2>/dev/null || true
    ip link delete "$stale_port" 2>/dev/null || true
  done

  for stale_ns in ns1 ns2 ns3; do
    ip netns delete "$stale_ns" 2>/dev/null || true
  done

  remove_managed_dhcpcd_bridge_block

  if [ -f "$DHCPCD_CONF" ]; then
    tmp_file="$(mktemp)"
    awk '
      BEGIN { skip = 0 }
      /^# START INITBOX-BRIDGE-ACTIVE$/ { skip = 1; next }
      /^# END INITBOX-BRIDGE-ACTIVE$/ { skip = 0; next }
      /^# START INITBOX-LAB-NM-OWNER$/ { skip = 1; next }
      /^# END INITBOX-LAB-NM-OWNER$/ { skip = 0; next }
      skip == 0 { print }
    ' "$DHCPCD_CONF" >"$tmp_file"
    install -m 0644 "$tmp_file" "$DHCPCD_CONF"
    rm -f "$tmp_file"
  fi

  if ip link show "$UPSTREAM_IFACE" >/dev/null 2>&1; then
    ip link set "$UPSTREAM_IFACE" up 2>/dev/null || true
  fi

  if command -v nmcli >/dev/null 2>&1 \
    && command -v systemctl >/dev/null 2>&1 \
    && systemctl is-active --quiet NetworkManager.service; then
    if command -v dhcpcd >/dev/null 2>&1; then
      dhcpcd -k "$UPSTREAM_IFACE" >/dev/null 2>&1 || true
    fi
    nmcli device set "$UPSTREAM_IFACE" managed yes >/dev/null 2>&1 || true
    nmcli device reapply "$UPSTREAM_IFACE" >/dev/null 2>&1 \
      || nmcli device connect "$UPSTREAM_IFACE" >/dev/null 2>&1 \
      || true
  else
    systemctl start dhcpcd.service 2>/dev/null || true
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

  Bridge starts only when the live topology matches the requested role:
    isi requires at least one wired carrier so br0 can be created first
    sniff requires eth0 and eth1 carrier

  ISI validation happens after bridge startup:
    br0 is created first
    isirunall.service then creates ns1/ns2/ns3 and requests COPILOT DHCP
    isi is removed only if no 10.x.x.x ISI network appears after startup grace

  Invalid requested roles are auto-cleared:
    isi is removed when no 10.x.x.x ISI network is detected after startup grace
    sniff/wireshark/sniffer/sniffer-bridge are removed when eth0+eth1 carrier is missing

Dashboard availability:
  This module sets:
    WSBR0=1 on install
    WSBR0=0 on uninstall/purge

  If ${DASHBOARD_SERVICE} exists, it is restarted after the flag update.
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
