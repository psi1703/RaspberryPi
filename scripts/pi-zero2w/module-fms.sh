#!/usr/bin/env bash
set -euo pipefail

# InitBox Pi Zero 2W FMS module
#
# Actions:
#   install   Install and enable CAN/FMS replay service.
#   uninstall Remove FMS service and files created by this module.
#   purge     Uninstall and also purge FMS dependency packages.
#
# Default action:
#   install

ACTION="${1:-install}"

: "${OWNER:=initbox}"
: "${LOGFILE:=/home/${OWNER}/pi_logs/initbox-install.log}"

FMS_SCRIPT="/usr/local/bin/fms.py"
FMS_SERVICE_FILE="/etc/systemd/system/fms.service"
FMS_TRC_FILE="/usr/local/bin/CAN.trc"

NETWORK_INTERFACES_FILE="/etc/network/interfaces"
NETWORK_INTERFACES_BACKUP="/etc/network/interfaces.initbox.bak"

MCP2515_OVERLAY_LINE="dtoverlay=mcp2515-can0,oscillator=8000000,interrupt=25"

ts() {
  date +"%Y-%m-%d %H:%M:%S"
}

log() {
  echo "[FMS  $(ts)] $*" | tee -a "$LOGFILE"
}

ok() {
  echo "[FMS  $(ts)] [OK] $*" | tee -a "$LOGFILE"
}

warn() {
  echo "[FMS  $(ts)] [WARN] $*" | tee -a "$LOGFILE" >&2
}

err() {
  echo "[FMS  $(ts)] [ERR] $*" | tee -a "$LOGFILE" >&2
}

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

boot_config_path() {
  if [ -f /boot/firmware/config.txt ]; then
    printf '%s\n' "/boot/firmware/config.txt"
    return 0
  fi

  if [ -f /boot/config.txt ]; then
    printf '%s\n' "/boot/config.txt"
    return 0
  fi

  return 1
}

install_dependencies() {
  log "Installing FMS dependencies"
  apt_safe update
  apt_safe install -y can-utils ifupdown
}

patch_mcp2515_overlay() {
  local cfg=""

  if ! cfg="$(boot_config_path)"; then
    warn "No /boot/firmware/config.txt or /boot/config.txt found; cannot configure MCP2515 overlay."
    return 0
  fi

  log "Patching MCP2515 overlay in ${cfg}"

  if grep -q '^#dtparam=spi=on' "$cfg"; then
    sed -i 's/^#dtparam=spi=on/dtparam=spi=on/' "$cfg"
    log "Uncommented dtparam=spi=on."
  elif ! grep -q '^dtparam=spi=on' "$cfg"; then
    echo 'dtparam=spi=on' >>"$cfg"
    log "Appended dtparam=spi=on."
  fi

  sed -i '\|^# INITBOX-FMS-MCP2515-START$|,\|^# INITBOX-FMS-MCP2515-END$|d' "$cfg"

  if grep -q "^${MCP2515_OVERLAY_LINE}$" "$cfg"; then
    log "MCP2515 overlay already present."
  else
    cat >>"$cfg" <<EOF

# INITBOX-FMS-MCP2515-START
${MCP2515_OVERLAY_LINE}
# INITBOX-FMS-MCP2515-END
EOF
    log "Added InitBox MCP2515 overlay block."
  fi

  log "NOTE: Changes to ${cfg} require a reboot before can0 will appear."
}

remove_mcp2515_overlay() {
  local cfg=""

  if ! cfg="$(boot_config_path)"; then
    warn "No boot config found; skipping MCP2515 overlay removal."
    return 0
  fi

  log "Removing InitBox MCP2515 overlay from ${cfg}"

  sed -i '\|^# INITBOX-FMS-MCP2515-START$|,\|^# INITBOX-FMS-MCP2515-END$|d' "$cfg"

  if grep -q "^${MCP2515_OVERLAY_LINE}$" "$cfg"; then
    sed -i "\|^${MCP2515_OVERLAY_LINE}$|d" "$cfg"
    log "Removed legacy unmarked MCP2515 overlay line."
  fi

  log "Leaving dtparam=spi=on unchanged because it may be used by other hardware."
  log "NOTE: Boot config changes require a reboot."
}

write_network_interfaces() {
  log "Writing CAN0 block in ${NETWORK_INTERFACES_FILE}"

  touch "$NETWORK_INTERFACES_FILE"

  if [ -f "$NETWORK_INTERFACES_FILE" ] && [ ! -f "$NETWORK_INTERFACES_BACKUP" ]; then
    cp "$NETWORK_INTERFACES_FILE" "$NETWORK_INTERFACES_BACKUP" 2>/dev/null || true
  fi

  sed -i '/^###START: CAN0$/,/^###END: CAN0$/d' "$NETWORK_INTERFACES_FILE"

  cat >>"$NETWORK_INTERFACES_FILE" <<'EOF'

###START: CAN0
allow-hotplug can0
iface can0 can static
    bitrate 250000
    up   /sbin/ifconfig $IFACE txqueuelen 15000
    up   /sbin/ip link set $IFACE type can bitrate 250000 restart-ms 10
    up   /sbin/ip link set $IFACE up
    down /sbin/ip link set $IFACE down
###END: CAN0
EOF
}

remove_network_interfaces_block() {
  if [ ! -f "$NETWORK_INTERFACES_FILE" ]; then
    return 0
  fi

  if grep -q '^###START: CAN0$' "$NETWORK_INTERFACES_FILE"; then
    log "Removing CAN0 block from ${NETWORK_INTERFACES_FILE}"
    sed -i '/^###START: CAN0$/,/^###END: CAN0$/d' "$NETWORK_INTERFACES_FILE"
  fi
}

write_fms_script() {
  log "Writing ${FMS_SCRIPT}"

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


def log(msg: str) -> None:
    sys.stderr.write(msg + "\n")
    sys.stderr.flush()


def is_hex_string(value: str) -> bool:
    if not value:
        return False

    try:
        int(value, 16)
        return True
    except ValueError:
        return False


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
        with open(path, "r", encoding="utf-8", errors="ignore") as f:
            for line in f:
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

                data_bytes = parts[5:5 + dlc]

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


def main() -> None:
    log(f"[FMS] Starting CAN replay on {CAN_IFACE} from {TRC_FILE}")

    while True:
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

write_fms_service() {
  log "Installing ${FMS_SERVICE_FILE}"

  cat >"$FMS_SERVICE_FILE" <<'EOF'
[Unit]
Description=Send CAN/FMS messages on can0
After=network.target
Wants=network.target

[Service]
Type=simple
User=initbox
Group=initbox
ExecStart=/usr/bin/python3 /usr/local/bin/fms.py
Restart=on-failure
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
}

restart_fms_service() {
  systemctl daemon-reload
  systemctl enable fms.service
  systemctl restart fms.service || true
}

stop_and_disable_unit() {
  local unit_name="$1"

  log "stopping and disabling $unit_name if present"
  systemctl disable --now "$unit_name" 2>/dev/null || true
  systemctl reset-failed "$unit_name" 2>/dev/null || true
}

remove_fms_files() {
  log "Removing FMS files"

  rm -f "$FMS_SCRIPT"
  rm -f "$FMS_SERVICE_FILE"
}

bring_can0_down() {
  log "Bringing can0 down if present"

  if command -v ip >/dev/null 2>&1; then
    ip link set can0 down 2>/dev/null || true
  fi
}

purge_fms_packages() {
  log "Purging FMS dependency packages"

  apt_safe purge -y can-utils ifupdown
  apt_safe autoremove -y
}

print_install_summary() {
  echo
  echo "FMS module installed"
  echo "--------------------"
  echo "Service: ${FMS_SERVICE_FILE}"
  echo "Script:  ${FMS_SCRIPT}"
  echo "TRC:     ${FMS_TRC_FILE}"
  echo
  echo "Important:"
  echo "  Reboot once if the MCP2515 overlay was just added."
  echo
  echo "Check:"
  echo "  sudo systemctl status fms.service --no-pager"
  echo "  sudo journalctl -u fms.service -n 100 --no-pager"
  echo "  ip -details link show can0"
}

print_uninstall_summary() {
  echo
  echo "FMS module uninstalled"
  echo "----------------------"
  echo "Removed:"
  echo "  - fms.service"
  echo "  - ${FMS_SCRIPT}"
  echo "  - CAN0 block from ${NETWORK_INTERFACES_FILE}"
  echo "  - InitBox MCP2515 overlay block from boot config"
  echo
  echo "Not removed:"
  echo "  - installed dependency packages"
  echo "  - ${FMS_TRC_FILE}"
  echo "  - dtparam=spi=on"
  echo
  echo "Important:"
  echo "  Reboot once for boot config changes to fully apply."
}

print_purge_summary() {
  echo
  echo "FMS module purged"
  echo "-----------------"
  echo "Removed FMS service/configuration and purged:"
  echo "  - can-utils"
  echo "  - ifupdown"
  echo
  echo "Not removed:"
  echo "  - ${FMS_TRC_FILE}"
  echo "  - dtparam=spi=on"
}

install_main() {
  require_root
  ensure_log_dir
  install_dependencies
  patch_mcp2515_overlay
  write_network_interfaces
  write_fms_script
  write_fms_service
  restart_fms_service
  print_install_summary

  ok "FMS module installed."
  log "If MCP2515 overlay was just added to config.txt, reboot once so can0 exists at boot."
}

uninstall_main() {
  require_root
  ensure_log_dir

  stop_and_disable_unit "fms.service"
  bring_can0_down
  remove_fms_files
  remove_network_interfaces_block
  remove_mcp2515_overlay

  systemctl daemon-reload
  systemctl reset-failed 2>/dev/null || true

  print_uninstall_summary
  ok "FMS module uninstalled."
}

purge_main() {
  require_root
  ensure_log_dir

  stop_and_disable_unit "fms.service"
  bring_can0_down
  remove_fms_files
  remove_network_interfaces_block
  remove_mcp2515_overlay
  purge_fms_packages

  systemctl daemon-reload
  systemctl reset-failed 2>/dev/null || true

  print_purge_summary
  ok "FMS module purged."
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
      purge_main
      ;;
    *)
      err "unknown action '$ACTION'. Use install, uninstall, or purge."
      exit 1
      ;;
  esac
}

main "$@"
