#!/usr/bin/env bash

# InitBox Raspberry Pi 3 / 4 / 5 FMS/CAN replay module
#
# Installs:
#   - MCP2515 CAN overlay configuration
#   - can0 network interface block
#   - fms.py CAN replay helper
#   - fms.service
#
# Pi 3 / 4 / 5 role model:
#   - Dashboard/Node-RED owns /etc/pi_roles.conf.
#   - fms.py sends CAN frames only when the role file contains: fms
#
# Actions:
#   install    Install/update FMS service and helper files
#   uninstall  Disable/remove FMS service and helper files created by this module
#   purge      Compatibility alias for uninstall; packages are not purged

set -euo pipefail

ACTION="${1:-install}"

: "${OWNER:=initbox}"

LOG_DIR="/home/${OWNER}/pi_logs"
LOGFILE="${LOGFILE:-${LOG_DIR}/initbox-install.log}"

ROLE_FILE="${ROLE_FILE:-/etc/pi_roles.conf}"
FMS_SCRIPT="/usr/local/bin/fms.py"
FMS_SERVICE="/etc/systemd/system/fms.service"
TRC_FILE="/usr/local/bin/CAN.trc"

ts() {
  date +"%Y-%m-%d %H:%M:%S"
}

log() {
  echo "[FMS $(ts)] $*" | tee -a "$LOGFILE"
}

ok() {
  echo "[FMS $(ts)] [OK] $*" | tee -a "$LOGFILE"
}

warn() {
  echo "[FMS $(ts)] [WARN] $*" | tee -a "$LOGFILE" >&2
}

err() {
  echo "[FMS $(ts)] [ERR] $*" | tee -a "$LOGFILE" >&2
}

require_root() {
  if [ "$(id -u)" -ne 0 ]; then
    err "This module must be run as root."
    echo "Run with:"
    echo "  sudo ./scripts/pi-3-4-5/module-fms.sh ${ACTION}"
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
  log "Installing FMS dependencies."

  if ! apt_safe update; then
    err "apt-get update failed."
    exit 1
  fi

  if ! apt_safe install -y can-utils ifupdown python3 iproute2; then
    err "FMS dependency installation failed."
    exit 1
  fi
}

ensure_role_file() {
  if [ ! -f "$ROLE_FILE" ]; then
    log "Creating ${ROLE_FILE} with no roles enabled."

    cat >"$ROLE_FILE" <<'EOF'
# InitBox role file managed by the dashboard.
#
# Supported role words:
#   isi
#   fms
#   sniff
#   wireshark
#   sniffer
#   sniffer-bridge
#
# Example:
#   ROLES="isi fms sniff"

ROLES=""
EOF

    chmod 664 "$ROLE_FILE"
    chown root:"$OWNER" "$ROLE_FILE" 2>/dev/null || chown root:root "$ROLE_FILE" || true
  else
    log "${ROLE_FILE} already exists; leaving contents unchanged."
    chmod 664 "$ROLE_FILE" || true
    chown root:"$OWNER" "$ROLE_FILE" 2>/dev/null || true
  fi
}

patch_mcp2515_overlay() {
  local cfg=""
  local overlay_line="dtoverlay=mcp2515-can0,oscillator=8000000,interrupt=25"

  if [ -f /boot/firmware/config.txt ]; then
    cfg="/boot/firmware/config.txt"
  elif [ -f /boot/config.txt ]; then
    cfg="/boot/config.txt"
  else
    warn "No /boot/firmware/config.txt or /boot/config.txt found; cannot configure MCP2515 overlay."
    return 0
  fi

  log "Patching MCP2515 overlay in ${cfg}."

  if grep -q '^#dtparam=spi=on' "$cfg"; then
    sed -i 's/^#dtparam=spi=on/dtparam=spi=on/' "$cfg"
    log "Uncommented dtparam=spi=on."
  elif ! grep -q '^dtparam=spi=on' "$cfg"; then
    printf '\n%s\n' 'dtparam=spi=on' >>"$cfg"
    log "Appended dtparam=spi=on."
  fi

  if ! grep -q "^${overlay_line}\$" "$cfg"; then
    printf '%s\n' "$overlay_line" >>"$cfg"
    log "Appended MCP2515 overlay."
  else
    log "MCP2515 overlay already present."
  fi

  log "NOTE: changes to ${cfg} require a reboot before can0 appears."
}

install_can_interface_block() {
  local interfaces_file="/etc/network/interfaces"
  local tmp_file=""

  log "Updating ${interfaces_file} with managed CAN0 block."

  touch "$interfaces_file"

  tmp_file="$(mktemp)"

  awk '
    BEGIN { skip = 0 }
    /^###START: INITBOX-CAN0$/ { skip = 1; next }
    /^###END: INITBOX-CAN0$/ { skip = 0; next }
    skip == 0 { print }
  ' "$interfaces_file" >"$tmp_file"

  cat >>"$tmp_file" <<'EOF'

###START: INITBOX-CAN0
allow-hotplug can0
iface can0 can static
    bitrate 250000
    up   /sbin/ip link set $IFACE type can bitrate 250000 restart-ms 10
    up   /sbin/ip link set $IFACE txqueuelen 15000
    up   /sbin/ip link set $IFACE up
    down /sbin/ip link set $IFACE down
###END: INITBOX-CAN0
EOF

  install -m 0644 "$tmp_file" "$interfaces_file"
  rm -f "$tmp_file"
}

write_fms_script() {
  log "Writing ${FMS_SCRIPT}."

  cat >"$FMS_SCRIPT" <<'EOF'
#!/usr/bin/env python3
import os
import subprocess
import sys
import time

TRC_FILE = os.environ.get("FMS_TRC_FILE", "/usr/local/bin/CAN.trc")
CAN_IFACE = os.environ.get("FMS_CAN_IFACE", "can0")
FRAME_SLEEP = float(os.environ.get("FMS_FRAME_SLEEP", "0.1"))
LOOP_SLEEP = float(os.environ.get("FMS_LOOP_SLEEP", "0.5"))
ROLE_FILE = os.environ.get("ROLE_FILE", "/etc/pi_roles.conf")
ROLE_CHECK_INTERVAL = float(os.environ.get("FMS_ROLE_CHECK_INTERVAL", "5"))


def log(msg: str) -> None:
    sys.stderr.write(msg + "\n")
    sys.stderr.flush()


def read_roles() -> list[str]:
    if not os.path.exists(ROLE_FILE):
        return []

    roles_value = ""

    try:
        with open(ROLE_FILE, "r", encoding="utf-8", errors="ignore") as handle:
            for raw_line in handle:
                line = raw_line.strip().replace("\r", "")
                if not line or line.startswith("#"):
                    continue

                if line.startswith("ROLES=") or line.startswith("roles="):
                    _, value = line.split("=", 1)
                    roles_value = value.strip().strip('"').strip("'")
                    break
    except OSError as exc:
        log(f"[FMS] Failed to read role file {ROLE_FILE}: {exc!r}")
        return []

    return [item.strip().lower() for item in roles_value.split() if item.strip()]


def fms_role_enabled() -> bool:
    roles = read_roles()

    if "fms" in roles:
      return True

    if not roles:
        log(f"[FMS] No roles found in {ROLE_FILE}; FMS disabled.")
    else:
        log(f"[FMS] FMS role not enabled in {ROLE_FILE}; roles='{' '.join(roles)}'.")

    return False


def is_hex_string(value: str) -> bool:
    if not value:
        return False

    try:
        int(value, 16)
        return True
    except ValueError:
        return False


def can_iface_exists() -> bool:
    return os.path.exists(f"/sys/class/net/{CAN_IFACE}")


def bring_can_iface_up() -> None:
    if not can_iface_exists():
        log(f"[FMS] CAN interface not present: {CAN_IFACE}")
        return

    subprocess.run(
        ["ip", "link", "set", CAN_IFACE, "type", "can", "bitrate", "250000", "restart-ms", "10"],
        check=False,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )

    subprocess.run(
        ["ip", "link", "set", CAN_IFACE, "txqueuelen", "15000"],
        check=False,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )

    subprocess.run(
        ["ip", "link", "set", CAN_IFACE, "up"],
        check=False,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )


def send_fms_message(can_id: str, data: str) -> None:
    can_id = can_id.strip()
    data = data.strip()

    if not can_id or not data:
        return

    if len(data) % 2 != 0:
        log(f"[FMS] Skipping odd-length data: '{data}'")
        return

    if not (is_hex_string(can_id) and is_hex_string(data)):
        log(f"[FMS] Skipping non-hex frame: id='{can_id}' data='{data}'")
        return

    msg = f"{can_id}#{data}"

    try:
        subprocess.run(
            ["cansend", CAN_IFACE, msg],
            check=False,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
    except Exception as exc:
        log(f"[FMS] cansend failed: {exc!r}")


def replay_trc_once(path: str) -> None:
    try:
        with open(path, "r", encoding="utf-8", errors="ignore") as handle:
            for line in handle:
                if not fms_role_enabled():
                    log("[FMS] FMS role disabled during replay; pausing.")
                    return

                line = line.rstrip("\r\n")

                if not line:
                    continue

                if line.lstrip().startswith(";") or line.lstrip().startswith("---"):
                    continue

                parts = line.split()

                if len(parts) < 6:
                    continue

                can_id = parts[3]
                dlc_str = parts[4]

                try:
                    dlc = int(dlc_str)
                except ValueError:
                    continue

                data_bytes = parts[5 : 5 + dlc]

                if len(data_bytes) != dlc:
                    continue

                data_hex = "".join(data_bytes)
                send_fms_message(can_id, data_hex)
                time.sleep(FRAME_SLEEP)

    except FileNotFoundError:
        log(f"[FMS] TRC file not found: {path}")
        time.sleep(2)
    except Exception as exc:
        log(f"[FMS] Error reading TRC file: {exc!r}")
        time.sleep(2)


def wait_for_role() -> None:
    while not fms_role_enabled():
        time.sleep(ROLE_CHECK_INTERVAL)


def main() -> None:
    log(f"[FMS] Starting CAN replay service on {CAN_IFACE} from {TRC_FILE}")

    while True:
        wait_for_role()
        bring_can_iface_up()

        if not can_iface_exists():
            log(f"[FMS] Waiting for {CAN_IFACE}. If MCP2515 was just enabled, reboot once.")
            time.sleep(ROLE_CHECK_INTERVAL)
            continue

        replay_trc_once(TRC_FILE)
        time.sleep(LOOP_SLEEP)


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        log("[FMS] Transmission terminated by user.")
EOF

  chmod 755 "$FMS_SCRIPT"
  chown "$OWNER:$OWNER" "$FMS_SCRIPT" 2>/dev/null || true
}

install_default_trc_placeholder() {
  if [ -f "$TRC_FILE" ]; then
    log "${TRC_FILE} already exists; leaving contents unchanged."
    return 0
  fi

  log "Creating placeholder ${TRC_FILE}."

  cat >"$TRC_FILE" <<'EOF'
; InitBox FMS placeholder CAN.trc
; Replace this file with the real CAN trace before enabling the fms role.
EOF

  chmod 644 "$TRC_FILE"
  chown "$OWNER:$OWNER" "$TRC_FILE" 2>/dev/null || true
}

write_service() {
  log "Installing ${FMS_SERVICE}."

  cat >"$FMS_SERVICE" <<EOF
[Unit]
Description=InitBox FMS CAN replay on can0
After=network.target
Wants=network.target

[Service]
Type=simple
User=${OWNER}
Group=${OWNER}
Environment=ROLE_FILE=${ROLE_FILE}
Environment=FMS_TRC_FILE=${TRC_FILE}
Environment=FMS_CAN_IFACE=can0
ExecStart=/usr/bin/python3 ${FMS_SCRIPT}
Restart=on-failure
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
}

enable_service() {
  log "Enabling fms.service."

  systemctl daemon-reload
  systemctl enable fms.service 2>/dev/null || true

  log "Starting fms.service. It will wait unless the fms role is enabled."
  systemctl restart fms.service 2>/dev/null || true
}

install_module() {
  require_root
  prepare_log

  log "Starting FMS module installation."

  install_packages
  ensure_role_file
  patch_mcp2515_overlay
  install_can_interface_block
  write_fms_script
  install_default_trc_placeholder
  write_service
  enable_service

  ok "FMS module installed."
  ok "Dashboard role file controls startup: ${ROLE_FILE}"
  ok "Enable role with dashboard or set: ROLES=\"fms\""
  warn "If MCP2515 overlay was just added, reboot once so can0 exists."
}

uninstall_module() {
  require_root
  prepare_log

  log "Uninstalling FMS module."

  systemctl stop fms.service 2>/dev/null || true
  systemctl disable fms.service 2>/dev/null || true

  rm -f "$FMS_SERVICE"
  rm -f "$FMS_SCRIPT"

  systemctl daemon-reload

  ok "FMS service and helper script removed."
  warn "Installed packages were left in place intentionally."
  warn "CAN overlay configuration was left in place intentionally."
  warn "CAN trace file was left in place intentionally: ${TRC_FILE}"
  warn "Role file was left in place intentionally: ${ROLE_FILE}"
}

usage() {
  cat <<EOF
Usage:
  sudo ./scripts/pi-3-4-5/module-fms.sh [install|uninstall|purge]

Actions:
  install    Install/update FMS CAN replay service
  uninstall  Remove FMS service and helper script
  purge      Compatibility alias for uninstall; packages are not purged

Role control:
  Dashboard writes:
    ${ROLE_FILE}

  FMS sends frames only when the role file includes:
    fms

CAN trace:
  ${TRC_FILE}

Hardware note:
  MCP2515 overlay changes require one reboot before can0 appears.
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
