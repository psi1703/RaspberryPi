#!/usr/bin/env bash
# InitBox Pi Zero W / Zero 2W FMS module
#
# Actions:
#   install    Install and enable CAN/FMS replay service.
#   uninstall  Remove FMS service and files created by this module.
#   remove     Alias for uninstall.
#   purge      Compatibility alias for uninstall. It does not purge packages.
#
# Offline field-mode policy:
#   - Debian packages are installed from the InitBox local package cache.
#   - Uninstall removes services/config only.
#   - Purge is disabled and behaves like uninstall.
#   - Installed packages and cached .deb files are kept.
#
# Config policy:
#   - Uses original boot config file directly for MCP2515 overlay.
#   - Does not use /etc/network/interfaces for can0.
#   - Does not use ifup@can0.service.
#   - Uses /etc/systemd/system/fms.service directly.
#   - No NetworkManager drop-ins.
#   - No systemd drop-ins.

set -euo pipefail

ACTION="${1:-install}"

: "${OWNER:=initbox}"
: "${LOGFILE:=/home/${OWNER}/pi_logs/initbox-install.log}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${INITBOX_REPO_ROOT:-$(cd "$SCRIPT_DIR/../.." && pwd)}"

INITBOX_PACKAGES_FILE="${INITBOX_PACKAGES_FILE:-$REPO_ROOT/scripts/packages.txt}"
INITBOX_PACKAGE_CACHE_DIR="${INITBOX_PACKAGE_CACHE_DIR:-/opt/initbox/packages}"
PACKAGES_LIB_FILE="$REPO_ROOT/scripts/lib/packages.sh"

FMS_SCRIPT="/usr/local/bin/fms.py"
FMS_SERVICE_FILE="/etc/systemd/system/fms.service"
FMS_TRC_FILE="/usr/local/bin/CAN.trc"
FMS_CACHE_DIR="/var/cache/initbox/fms"

NETWORK_INTERFACES_FILE="/etc/network/interfaces"
NETWORK_INTERFACES_BACKUP="/etc/network/interfaces.initbox.bak"

MCP2515_OVERLAY_LINE="dtoverlay=mcp2515-can0,oscillator=8000000,interrupt=25"

ts() {
  date '+%Y-%m-%d %H:%M:%S'
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

die() {
  err "$*"
  exit 1
}

require_root() {
  if [ "$(id -u)" -ne 0 ]; then
    die "this module must be run as root"
  fi
}

require_owner_user() {
  if ! id "$OWNER" >/dev/null 2>&1; then
    die "user '$OWNER' does not exist"
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
  log "Installing FMS dependencies from InitBox package cache"
  log "packages file: $INITBOX_PACKAGES_FILE"
  log "cache dir:     $INITBOX_PACKAGE_CACHE_DIR"

  load_package_helper

  initbox_packages_install \
    "$INITBOX_PACKAGES_FILE" \
    "$INITBOX_PACKAGE_CACHE_DIR" \
    can-utils \
    iproute2
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

  log "NOTE: changes to ${cfg} require a reboot before can0 will appear."
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
  log "NOTE: boot config changes require a reboot."
}

remove_network_interfaces_block() {
  if [ ! -f "$NETWORK_INTERFACES_FILE" ]; then
    return 0
  fi

  if grep -q '^###START: INITBOX CAN0$' "$NETWORK_INTERFACES_FILE"; then
    log "Removing InitBox CAN0 block from ${NETWORK_INTERFACES_FILE}"
    sed -i '/^###START: INITBOX CAN0$/,/^###END: INITBOX CAN0$/d' "$NETWORK_INTERFACES_FILE"
  fi

  if grep -q '^###START: CAN0$' "$NETWORK_INTERFACES_FILE"; then
    log "Removing legacy CAN0 block from ${NETWORK_INTERFACES_FILE}"
    sed -i '/^###START: CAN0$/,/^###END: CAN0$/d' "$NETWORK_INTERFACES_FILE"
  fi
}

disable_ifup_can0() {
  log "Disabling stale ifup@can0.service, if present"

  systemctl disable --now ifup@can0.service 2>/dev/null || true
  systemctl reset-failed ifup@can0.service 2>/dev/null || true
}

write_fms_script() {
  log "Writing ${FMS_SCRIPT}"

  cat >"$FMS_SCRIPT" <<'EOF'
#!/usr/bin/env python3
import json
import os
import socket
import struct
import subprocess
import sys
import time
from pathlib import Path
from typing import List, Optional

TRC_FILE = os.environ.get("FMS_TRC_FILE", "/usr/local/bin/CAN.trc")
CAN_IFACE = os.environ.get("FMS_CAN_IFACE", "can0")
FRAME_SLEEP = float(os.environ.get("FMS_FRAME_SLEEP", "0.2"))
LOOP_SLEEP = float(os.environ.get("FMS_LOOP_SLEEP", "0.5"))
CAN_READY_RETRY_SLEEP = float(os.environ.get("FMS_CAN_READY_RETRY_SLEEP", "2.0"))
CAN_L2_CLEAN_INTERVAL = float(os.environ.get("FMS_CAN_L2_CLEAN_INTERVAL", "30.0"))
CACHE_DIR = Path(os.environ.get("FMS_CACHE_DIR", "/var/cache/initbox/fms"))
CACHE_FRAMES = CACHE_DIR / "CAN.trc.frames"
CACHE_META = CACHE_DIR / "CAN.trc.meta.json"

CAN_EFF_FLAG = 0x80000000
CAN_SFF_MASK = 0x000007FF
CAN_EFF_MASK = 0x1FFFFFFF
CAN_FRAME_FMT = "=IB3x8s"
CAN_FRAME_SIZE = struct.calcsize(CAN_FRAME_FMT)

LAST_CAN_L2_CLEAN = 0.0
CAN_PREPARED = False
TRC_FRAMES: List[bytes] = []
CAN_SOCKET: Optional[socket.socket] = None


def log(msg: str) -> None:
    sys.stderr.write(msg + "\n")
    sys.stderr.flush()


def run_quiet(args: list[str]) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        args,
        check=False,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        text=True,
    )


def can_iface_exists() -> bool:
    return Path(f"/sys/class/net/{CAN_IFACE}").exists()


def can_iface_is_up() -> bool:
    if not can_iface_exists():
        return False

    operstate = Path(f"/sys/class/net/{CAN_IFACE}/operstate")
    try:
        state = operstate.read_text(encoding="utf-8").strip()
        return state in {"up", "unknown"}
    except Exception:
        result = subprocess.run(
            ["ip", "link", "show", CAN_IFACE],
            check=False,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
        )
        header = result.stdout.split(">", 1)[0] if ">" in result.stdout else result.stdout
        return "UP" in header


def wait_for_can_iface() -> None:
    while not can_iface_exists():
        log(f"[FMS] Waiting for {CAN_IFACE}; MCP2515 overlay may require reboot.")
        time.sleep(CAN_READY_RETRY_SLEEP)


def iface_has_ip_address() -> bool:
    result = subprocess.run(
        ["ip", "-o", "addr", "show", "dev", CAN_IFACE],
        check=False,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        text=True,
    )
    return bool(result.stdout.strip())


def prepare_can_l2_once() -> None:
    global CAN_PREPARED

    if CAN_PREPARED:
        return

    run_quiet(["nmcli", "device", "set", CAN_IFACE, "managed", "no"])
    run_quiet(["dhcpcd", "-k", CAN_IFACE])
    run_quiet(["ip", "addr", "flush", "dev", CAN_IFACE])
    CAN_PREPARED = True


def enforce_can_l2_only(force: bool = False) -> None:
    global LAST_CAN_L2_CLEAN

    prepare_can_l2_once()

    now = time.monotonic()
    if not force and (now - LAST_CAN_L2_CLEAN) < CAN_L2_CLEAN_INTERVAL:
        return

    LAST_CAN_L2_CLEAN = now

    if iface_has_ip_address():
        run_quiet(["ip", "addr", "flush", "dev", CAN_IFACE])


def ensure_can_iface_up() -> None:
    wait_for_can_iface()
    enforce_can_l2_only(force=True)

    if can_iface_is_up():
        return

    log(f"[FMS] Bringing {CAN_IFACE} up from Python fallback.")
    run_quiet(["ip", "link", "set", CAN_IFACE, "down"])
    enforce_can_l2_only(force=True)
    run_quiet(["ip", "link", "set", CAN_IFACE, "type", "can", "bitrate", "250000", "restart-ms", "10"])
    run_quiet(["ip", "link", "set", CAN_IFACE, "txqueuelen", "15000"])
    run_quiet(["ip", "link", "set", CAN_IFACE, "up"])
    enforce_can_l2_only(force=True)


def open_can_socket() -> socket.socket:
    global CAN_SOCKET

    ensure_can_iface_up()

    if CAN_SOCKET is not None:
        return CAN_SOCKET

    sock = socket.socket(socket.PF_CAN, socket.SOCK_RAW, socket.CAN_RAW)
    sock.bind((CAN_IFACE,))
    CAN_SOCKET = sock
    log(f"[FMS] Opened native SocketCAN sender on {CAN_IFACE}")
    return CAN_SOCKET


def reset_can_socket() -> None:
    global CAN_SOCKET

    if CAN_SOCKET is not None:
        try:
            CAN_SOCKET.close()
        except OSError:
            pass

    CAN_SOCKET = None


def build_can_frame(can_id_raw: str, data_parts: list[str]) -> Optional[bytes]:
    if not can_id_raw or not data_parts:
        return None

    try:
        can_id = int(can_id_raw, 16)
    except ValueError:
        return None

    if can_id > CAN_EFF_MASK:
        return None

    try:
        data = bytes(int(part, 16) for part in data_parts)
    except ValueError:
        return None

    if len(data) > 8:
        return None

    if can_id > CAN_SFF_MASK:
        can_id |= CAN_EFF_FLAG

    return struct.pack(CAN_FRAME_FMT, can_id, len(data), data.ljust(8, b"\x00"))


def trc_stat(path: str) -> dict[str, float | int | str]:
    stat_result = os.stat(path)
    return {
        "path": os.path.abspath(path),
        "mtime_ns": stat_result.st_mtime_ns,
        "size": stat_result.st_size,
        "format": "socketcan-frame-v1",
    }


def cache_meta_matches(path: str) -> bool:
    try:
        current = trc_stat(path)
        cached = json.loads(CACHE_META.read_text(encoding="utf-8"))
    except Exception:
        return False

    return cached == current and CACHE_FRAMES.exists()


def parse_trc_to_cache(path: str) -> int:
    CACHE_DIR.mkdir(parents=True, exist_ok=True)

    tmp_frames = CACHE_FRAMES.with_suffix(".frames.tmp")
    frame_count = 0

    with open(path, "r", encoding="utf-8", errors="ignore") as src, open(tmp_frames, "wb") as dst:
        for line in src:
            stripped = line.strip()

            if not stripped or stripped.startswith(";") or stripped.startswith("---"):
                continue

            parts = stripped.split()

            if len(parts) < 6:
                continue

            can_id = parts[3]
            try:
                dlc = int(parts[4])
            except ValueError:
                continue

            if dlc < 0 or dlc > 8:
                continue

            data_parts = parts[5:5 + dlc]
            if len(data_parts) != dlc:
                continue

            frame = build_can_frame(can_id, data_parts)
            if frame is None:
                continue

            dst.write(frame)
            frame_count += 1

    os.replace(tmp_frames, CACHE_FRAMES)
    CACHE_META.write_text(json.dumps(trc_stat(path), sort_keys=True), encoding="utf-8")

    return frame_count


def ensure_frame_cache(path: str) -> bool:
    try:
        if cache_meta_matches(path):
            return True

        count = parse_trc_to_cache(path)
        log(f"[FMS] Compiled {count} CAN frame(s) from {path} to {CACHE_FRAMES}")
        return count > 0
    except FileNotFoundError:
        log(f"[FMS] TRC file not found: {path}")
        return False
    except Exception as exc:
        log(f"[FMS] Failed to compile TRC cache: {exc!r}")
        return False


def load_cached_frames() -> bool:
    global TRC_FRAMES

    if not ensure_frame_cache(TRC_FILE):
        TRC_FRAMES = []
        return False

    try:
        data = CACHE_FRAMES.read_bytes()
    except Exception as exc:
        log(f"[FMS] Failed to read frame cache: {exc!r}")
        TRC_FRAMES = []
        return False

    if len(data) % CAN_FRAME_SIZE != 0:
        log("[FMS] Frame cache size is invalid; rebuilding.")
        try:
            CACHE_FRAMES.unlink(missing_ok=True)
            CACHE_META.unlink(missing_ok=True)
        except Exception:
            pass
        return False

    TRC_FRAMES = [
        data[offset:offset + CAN_FRAME_SIZE]
        for offset in range(0, len(data), CAN_FRAME_SIZE)
    ]

    log(f"[FMS] Loaded {len(TRC_FRAMES)} cached CAN frame(s)")
    return bool(TRC_FRAMES)


def send_frame(frame: bytes) -> None:
    sock = open_can_socket()

    try:
        sock.send(frame)
    except OSError as exc:
        log(f"[FMS] SocketCAN send failed: {exc!r}; reopening socket.")
        reset_can_socket()
        time.sleep(0.2)


def replay_cached_frames_once() -> None:
    ensure_can_iface_up()
    enforce_can_l2_only()

    if not TRC_FRAMES and not load_cached_frames():
        time.sleep(2)
        return

    for frame in TRC_FRAMES:
        send_frame(frame)
        if FRAME_SLEEP > 0:
            time.sleep(FRAME_SLEEP)


def compile_cache_only() -> int:
    if ensure_frame_cache(TRC_FILE):
        return 0
    return 1


def main() -> None:
    if len(sys.argv) > 1 and sys.argv[1] == "--compile-cache":
        raise SystemExit(compile_cache_only())

    log(f"[FMS] Starting native SocketCAN replay on {CAN_IFACE} from {TRC_FILE}")

    while True:
        replay_cached_frames_once()
        if LOOP_SLEEP > 0:
            time.sleep(LOOP_SLEEP)


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        log("[FMS] Transmission terminated by user.")
    finally:
        reset_can_socket()

EOF

  chmod 0755 "$FMS_SCRIPT"
  chown root:root "$FMS_SCRIPT" 2>/dev/null || true
  install -d -m 0755 "$FMS_CACHE_DIR"
}

write_fms_service() {
  log "Installing ${FMS_SERVICE_FILE}"

  cat >"$FMS_SERVICE_FILE" <<EOF
[Unit]
Description=InitBox native SocketCAN/FMS replay on can0
After=multi-user.target
Wants=multi-user.target

[Service]
Type=simple
User=root
Environment=FMS_TRC_FILE=${FMS_TRC_FILE}
Environment=FMS_CAN_IFACE=can0
Environment=FMS_FRAME_SLEEP=0.2
Environment=FMS_LOOP_SLEEP=0.5
Environment=FMS_CAN_L2_CLEAN_INTERVAL=30.0
Environment=FMS_CACHE_DIR=${FMS_CACHE_DIR}
ExecStartPre=/usr/bin/env sh -c 'if command -v nmcli >/dev/null 2>&1; then nmcli device set can0 managed no >/dev/null 2>&1 || true; fi'
ExecStartPre=/usr/bin/env sh -c 'if command -v dhcpcd >/dev/null 2>&1; then dhcpcd -k can0 >/dev/null 2>&1 || true; fi'
ExecStartPre=/usr/sbin/ip addr flush dev can0
ExecStartPre=/usr/sbin/ip link set can0 down
ExecStartPre=/usr/sbin/ip link set can0 type can bitrate 250000 restart-ms 10
ExecStartPre=/usr/sbin/ip link set can0 txqueuelen 15000
ExecStartPre=/usr/sbin/ip link set can0 up
ExecStartPre=-/usr/bin/python3 ${FMS_SCRIPT} --compile-cache
ExecStart=/usr/bin/python3 ${FMS_SCRIPT}
Restart=on-failure
RestartSec=2
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

  log "Stopping and disabling ${unit_name} if present"
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
    ip addr flush dev can0 2>/dev/null || true
  fi
}

print_install_summary() {
  echo
  echo "FMS module installed"
  echo "--------------------"
  echo "Service: ${FMS_SERVICE_FILE}"
  echo "Script:  ${FMS_SCRIPT}"
  echo "TRC:     ${FMS_TRC_FILE}"
  echo "Cache:   ${FMS_CACHE_DIR}"
  echo
  echo "Config files:"
  echo "  /boot/firmware/config.txt or /boot/config.txt"
  echo "  ${FMS_SERVICE_FILE}"
  echo
  echo "Config policy:"
  echo "  - no drop-ins"
  echo "  - MCP2515 overlay is written directly to boot config"
  echo "  - CAN0 is configured directly by fms.service"
  echo "  - CAN.trc is compiled to a binary frame cache and reused until the file changes"
  echo "  - CAN frames are sent with native SocketCAN, not subprocess cansend"
  echo "  - Default frame pacing is 0.2s to reduce Pi Zero CPU load"
  echo "  - /etc/network/interfaces is not used for CAN0"
  echo "  - stale InitBox CAN0 blocks are removed from ${NETWORK_INTERFACES_FILE}"
  echo "  - stale ifup@can0.service failure state is reset"
  echo
  echo "Offline field-mode behaviour:"
  echo "  - Debian packages are installed from ${INITBOX_PACKAGE_CACHE_DIR}"
  echo "  - python3 is expected from Raspberry Pi OS and is not installed by this module"
  echo "  - uninstall does not remove packages or cached .deb files"
  echo "  - purge is disabled and behaves like uninstall"
  echo
  echo "Important:"
  echo "  Reboot once if the MCP2515 overlay was just added."
  echo
  echo "Check:"
  echo "  sudo systemctl status fms.service --no-pager"
  echo "  sudo journalctl -u fms.service -n 100 --no-pager"
  echo "  ip -details link show can0"
  echo "  ip -4 addr show can0"
}

print_uninstall_summary() {
  echo
  echo "FMS module uninstalled"
  echo "----------------------"
  echo "Removed:"
  echo "  - fms.service"
  echo "  - ${FMS_SCRIPT}"
  echo "  - InitBox CAN0 block from ${NETWORK_INTERFACES_FILE}, if present"
  echo "  - InitBox MCP2515 overlay block from boot config"
  echo
  echo "Not removed:"
  echo "  - installed dependency packages"
  echo "  - cached .deb files under ${INITBOX_PACKAGE_CACHE_DIR}"
  echo "  - ${FMS_TRC_FILE}"
  echo "  - binary frame cache under ${FMS_CACHE_DIR}"
  echo "  - dtparam=spi=on"
  echo "  - ${NETWORK_INTERFACES_BACKUP}, if it exists"
  echo
  echo "Important:"
  echo "  Reboot once for boot config changes to fully apply."
}

install_main() {
  require_root
  ensure_log_dir
  require_owner_user
  install_dependencies
  patch_mcp2515_overlay
  remove_network_interfaces_block
  disable_ifup_can0
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
  stop_and_disable_unit "ifup@can0.service"
  bring_can0_down
  remove_fms_files
  remove_network_interfaces_block
  remove_mcp2515_overlay

  systemctl daemon-reload
  systemctl reset-failed 2>/dev/null || true

  print_uninstall_summary
  ok "FMS module uninstalled."
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

#!/usr/bin/env bash
# InitBox Pi Zero W / Zero 2W Hotspot module
#
# Actions:
#   install    Install and enable InitBox hotspot.
#   uninstall  Remove services/config created by this module, but keep packages.
#   remove     Alias for uninstall.
#   purge      Compatibility alias for uninstall. It does not purge packages.
#
# Pi Zero policy:
#   - stable hotspot gateway: 192.168.20.1/24
#   - BOX number affects SSID only, for example initbox_3
#   - original config files are used directly; no dnsmasq.d or systemd drop-ins
#   - package install uses the local InitBox package cache helper

set -euo pipefail

ACTION="${1:-install}"

: "${OWNER:=initbox}"
: "${HOTSPOT_PASS:=TomatoH34d}"
: "${HOTSPOT_INTERFACE:=wlan0}"
: "${HOTSPOT_COUNTRY:=AE}"
: "${HOTSPOT_CHANNEL:=1}"
: "${HOTSPOT_GATEWAY:=192.168.20.1}"
: "${HOTSPOT_DHCP_START:=192.168.20.10}"
: "${HOTSPOT_DHCP_END:=192.168.20.20}"
: "${HOTSPOT_DHCP_LEASE:=24h}"
: "${LOGFILE:=/home/${OWNER}/pi_logs/initbox-install.log}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${INITBOX_REPO_ROOT:-$(cd "$SCRIPT_DIR/../.." && pwd)}"

INITBOX_PACKAGES_FILE="${INITBOX_PACKAGES_FILE:-$REPO_ROOT/scripts/packages.txt}"
INITBOX_PACKAGE_CACHE_DIR="${INITBOX_PACKAGE_CACHE_DIR:-/opt/initbox/packages}"
PACKAGES_LIB_FILE="$REPO_ROOT/scripts/lib/packages.sh"

HOSTAPD_CONF="/etc/hostapd/hostapd.conf"
HOSTAPD_DEFAULT="/etc/default/hostapd"

DNSMASQ_CONF="/etc/dnsmasq.conf"
DNSMASQ_BACKUP="${DNSMASQ_CONF}.initbox.bak"
DNSMASQ_DIR="/etc/dnsmasq.d"

DHCPCD_CONF="/etc/dhcpcd.conf"
NETWORKMANAGER_UNMANAGED_FILE="/etc/NetworkManager/conf.d/initbox-unmanaged-wlan0.conf"
BOXNO_FILE="/etc/pi-boxno"

ts() {
  date '+%Y-%m-%d %H:%M:%S'
}

log() {
  echo "[HOTSPOT $(ts)] $*" | tee -a "$LOGFILE"
}

ok() {
  echo "[HOTSPOT $(ts)] [OK] $*" | tee -a "$LOGFILE"
}

warn() {
  echo "[HOTSPOT $(ts)] [WARN] $*" | tee -a "$LOGFILE" >&2
}

err() {
  echo "[HOTSPOT $(ts)] [ERR] $*" | tee -a "$LOGFILE" >&2
}

die() {
  err "$*"
  exit 1
}

ask() {
  local prompt="$1"
  local default="$2"
  local reply=""

  if [ -t 0 ]; then
    read -r -p "$prompt [$default]: " reply
    printf '%s\n' "${reply:-$default}"
  else
    printf '%s\n' "$default"
  fi
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

command_exists() {
  command -v "$1" >/dev/null 2>&1
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
  log "Installing hotspot dependencies from InitBox package cache"
  log "packages file: $INITBOX_PACKAGES_FILE"
  log "cache dir:     $INITBOX_PACKAGE_CACHE_DIR"

  load_package_helper

  initbox_packages_install \
    "$INITBOX_PACKAGES_FILE" \
    "$INITBOX_PACKAGE_CACHE_DIR" \
    dnsmasq \
    hostapd \
    dhcpcd5 \
    iproute2 \
    iptables \
    rfkill
}

validate_hotspot_values() {
  case "$HOTSPOT_GATEWAY" in
    192.168.20.*)
      ;;
    *)
      die "HOTSPOT_GATEWAY must stay inside 192.168.20.0/24 for pi-zero2w. Current: $HOTSPOT_GATEWAY"
      ;;
  esac

  if [ "${#HOTSPOT_PASS}" -lt 8 ] || [ "${#HOTSPOT_PASS}" -gt 63 ]; then
    die "HOTSPOT_PASS must be 8-63 characters for WPA2."
  fi

  case "$HOTSPOT_CHANNEL" in
    ''|*[!0-9]*)
      die "HOTSPOT_CHANNEL must be numeric."
      ;;
  esac

  if [ "$HOTSPOT_CHANNEL" -lt 1 ] || [ "$HOTSPOT_CHANNEL" -gt 13 ]; then
    die "HOTSPOT_CHANNEL must be between 1 and 13."
  fi
}

get_box_number() {
  local boxno=""

  if [ -r "$BOXNO_FILE" ]; then
    boxno="$(cat "$BOXNO_FILE" 2>/dev/null || printf '1')"
  else
    boxno="$(ask 'Enter BOX number, used in SSID initbox_<number>' '1')"
    printf '%s\n' "$boxno" >"$BOXNO_FILE"
  fi

  if ! printf '%s\n' "$boxno" | grep -Eq '^[0-9]+$'; then
    warn "invalid BOX number '$boxno'; using 1"
    boxno="1"
    printf '%s\n' "$boxno" >"$BOXNO_FILE"
  fi

  if [ "$boxno" -lt 1 ] || [ "$boxno" -gt 254 ]; then
    warn "BOX number '$boxno' outside valid range 1-254; using 1"
    boxno="1"
    printf '%s\n' "$boxno" >"$BOXNO_FILE"
  fi

  printf '%s\n' "$boxno"
}

stop_conflicting_wifi_clients() {
  log "Disabling interface-specific client Wi-Fi services for ${HOTSPOT_INTERFACE}"

  systemctl stop "wpa_supplicant@${HOTSPOT_INTERFACE}.service" 2>/dev/null || true
  systemctl disable "wpa_supplicant@${HOTSPOT_INTERFACE}.service" 2>/dev/null || true

  if systemctl list-unit-files NetworkManager.service >/dev/null 2>&1; then
    warn "NetworkManager exists; marking ${HOTSPOT_INTERFACE} unmanaged"
    install -d -m 0755 /etc/NetworkManager/conf.d

    cat >"$NETWORKMANAGER_UNMANAGED_FILE" <<EOF
[keyfile]
unmanaged-devices=interface-name:${HOTSPOT_INTERFACE}
EOF

    systemctl reload NetworkManager.service 2>/dev/null || systemctl restart NetworkManager.service 2>/dev/null || true
  fi
}

write_hostapd_conf() {
  local ssid="$1"

  log "Writing ${HOSTAPD_CONF}"

  install -d -m 0755 /etc/hostapd

  cat >"$HOSTAPD_CONF" <<EOF
# initbox-hotspot
country_code=${HOTSPOT_COUNTRY}
interface=${HOTSPOT_INTERFACE}
driver=nl80211
ssid=${ssid}
hw_mode=g
channel=${HOTSPOT_CHANNEL}
wmm_enabled=1
ieee80211n=1
macaddr_acl=0
auth_algs=1
ignore_broadcast_ssid=0
wpa=2
wpa_passphrase=${HOTSPOT_PASS}
wpa_key_mgmt=WPA-PSK
rsn_pairwise=CCMP
EOF

  chown root:root "$HOSTAPD_CONF"
  chmod 0600 "$HOSTAPD_CONF"

  cat >"$HOSTAPD_DEFAULT" <<EOF
DAEMON_CONF="${HOSTAPD_CONF}"
DAEMON_OPTS=""
EOF
}

remove_legacy_dnsmasq_dropins() {
  log "Removing old InitBox dnsmasq drop-ins, if present"

  rm -f "${DNSMASQ_DIR}/initbox-wlan.conf"
  rm -f "${DNSMASQ_DIR}/initbox-captive-portal.conf"
  rm -f "${DNSMASQ_DIR}/initbox-hotspot.conf"
}

backup_dnsmasq_conf_if_needed() {
  if [ -f "$DNSMASQ_CONF" ] && ! grep -q '^# initbox-hotspot' "$DNSMASQ_CONF"; then
    if [ ! -f "$DNSMASQ_BACKUP" ]; then
      log "Backing up existing dnsmasq config to ${DNSMASQ_BACKUP}"
      cp "$DNSMASQ_CONF" "$DNSMASQ_BACKUP"
    else
      log "Existing dnsmasq backup already present: ${DNSMASQ_BACKUP}"
    fi
  fi
}

write_dnsmasq_conf() {
  log "Writing ${DNSMASQ_CONF}"

  backup_dnsmasq_conf_if_needed
  remove_legacy_dnsmasq_dropins

  cat >"$DNSMASQ_CONF" <<EOF
# initbox-hotspot
interface=${HOTSPOT_INTERFACE}
bind-dynamic
dhcp-authoritative

dhcp-range=${HOTSPOT_DHCP_START},${HOTSPOT_DHCP_END},${HOTSPOT_DHCP_LEASE}
dhcp-option=3,${HOTSPOT_GATEWAY}
dhcp-option=6,${HOTSPOT_GATEWAY}

domain=initbox.wlan
local=/initbox.wlan/

# Local InitBox names
address=/initbox.wlan/${HOTSPOT_GATEWAY}
address=/initbox.local/${HOTSPOT_GATEWAY}

# Field captive mode:
# Resolve all DNS names to the InitBox hotspot IP.
address=/#/${HOTSPOT_GATEWAY}

# Android captive portal checks
address=/connectivitycheck.gstatic.com/${HOTSPOT_GATEWAY}
address=/connectivitycheck.android.com/${HOTSPOT_GATEWAY}
address=/clients3.google.com/${HOTSPOT_GATEWAY}
address=/www.gstatic.com/${HOTSPOT_GATEWAY}
address=/www.google.com/${HOTSPOT_GATEWAY}

# Apple captive portal checks
address=/captive.apple.com/${HOTSPOT_GATEWAY}
address=/www.apple.com/${HOTSPOT_GATEWAY}
address=/www.appleiphonecell.com/${HOTSPOT_GATEWAY}

# Windows captive portal checks
address=/msftconnecttest.com/${HOTSPOT_GATEWAY}
address=/www.msftconnecttest.com/${HOTSPOT_GATEWAY}
address=/ipv6.msftconnecttest.com/${HOTSPOT_GATEWAY}
address=/msftncsi.com/${HOTSPOT_GATEWAY}
address=/www.msftncsi.com/${HOTSPOT_GATEWAY}
address=/dns.msftncsi.com/${HOTSPOT_GATEWAY}

# Firefox captive portal check
address=/detectportal.firefox.com/${HOTSPOT_GATEWAY}
EOF
}

write_dhcpcd_conf() {
  log "Ensuring static IP for ${HOTSPOT_INTERFACE} in ${DHCPCD_CONF}"

  touch "$DHCPCD_CONF"

  if grep -q '^# initbox-hotspot$' "$DHCPCD_CONF"; then
    sed -i '/^# initbox-hotspot$/,/^$/d' "$DHCPCD_CONF"
  fi

  cat >>"$DHCPCD_CONF" <<EOF

# initbox-hotspot
interface ${HOTSPOT_INTERFACE}
    static ip_address=${HOTSPOT_GATEWAY}/24
    nohook wpa_supplicant

EOF
}

validate_configs() {
  log "Validating dnsmasq configuration"

  dnsmasq --test 2>&1 | tee -a "$LOGFILE"

  if [ ! -s "$HOSTAPD_CONF" ]; then
    die "hostapd config is missing or empty: $HOSTAPD_CONF"
  fi

  if ! grep -q "^interface=${HOTSPOT_INTERFACE}$" "$HOSTAPD_CONF"; then
    die "hostapd config does not target ${HOTSPOT_INTERFACE}"
  fi

  if [ ! -s "$DNSMASQ_CONF" ]; then
    die "dnsmasq config is missing or empty: $DNSMASQ_CONF"
  fi

  if ! grep -q "^interface=${HOTSPOT_INTERFACE}$" "$DNSMASQ_CONF"; then
    die "dnsmasq config does not target ${HOTSPOT_INTERFACE}"
  fi

  if ! grep -q "^address=/#/${HOTSPOT_GATEWAY}$" "$DNSMASQ_CONF"; then
    die "dnsmasq wildcard captive DNS rule is missing"
  fi
}

restart_hotspot_stack() {
  log "Unmasking and enabling hotspot stack"

  systemctl unmask hostapd 2>/dev/null || true
  rfkill unblock wifi 2>/dev/null || rfkill unblock all 2>/dev/null || true

  systemctl daemon-reload

  systemctl enable dhcpcd.service 2>/dev/null || true
  systemctl enable hostapd.service 2>/dev/null || true
  systemctl enable dnsmasq.service 2>/dev/null || true

  log "Restarting dhcpcd"
  systemctl restart dhcpcd.service 2>/dev/null || systemctl start dhcpcd.service 2>/dev/null || true

  log "Preparing ${HOTSPOT_INTERFACE}"
  ip link set "$HOTSPOT_INTERFACE" up
  ip addr replace "${HOTSPOT_GATEWAY}/24" dev "$HOTSPOT_INTERFACE"

  log "Restarting hostapd"
  systemctl restart hostapd.service

  sleep 2

  log "Restarting dnsmasq"
  systemctl restart dnsmasq.service

  ok "Hotspot stack restarted"
}

stop_and_disable_unit() {
  local unit_name="$1"

  log "Stopping and disabling ${unit_name} if present"
  systemctl disable --now "$unit_name" 2>/dev/null || true
  systemctl reset-failed "$unit_name" 2>/dev/null || true
}

restore_dnsmasq_conf_if_possible() {
  if [ -f "$DNSMASQ_CONF" ] && grep -q '^# initbox-hotspot' "$DNSMASQ_CONF"; then
    if [ -f "$DNSMASQ_BACKUP" ]; then
      log "Restoring previous dnsmasq config from ${DNSMASQ_BACKUP}"
      cp "$DNSMASQ_BACKUP" "$DNSMASQ_CONF"
      rm -f "$DNSMASQ_BACKUP"
    else
      log "Removing InitBox-owned dnsmasq config"
      rm -f "$DNSMASQ_CONF"
    fi
  else
    log "dnsmasq config is not InitBox-owned; leaving unchanged"
  fi
}

remove_dhcpcd_hotspot_block() {
  if [ -f "$DHCPCD_CONF" ] && grep -q '^# initbox-hotspot$' "$DHCPCD_CONF"; then
    log "Removing InitBox dhcpcd hotspot block"
    sed -i '/^# initbox-hotspot$/,/^$/d' "$DHCPCD_CONF"
  fi
}

remove_hostapd_config_if_owned() {
  if [ -f "$HOSTAPD_CONF" ] && grep -q '^# initbox-hotspot' "$HOSTAPD_CONF"; then
    log "Removing InitBox-owned hostapd config"
    rm -f "$HOSTAPD_CONF"
  else
    log "hostapd config is not InitBox-owned; leaving unchanged"
  fi

  if [ -f "$HOSTAPD_DEFAULT" ] && grep -q "$HOSTAPD_CONF" "$HOSTAPD_DEFAULT"; then
    log "Removing hostapd default config pointer"
    rm -f "$HOSTAPD_DEFAULT"
  fi
}

remove_networkmanager_unmanaged_config() {
  if [ -f "$NETWORKMANAGER_UNMANAGED_FILE" ]; then
    log "Removing NetworkManager unmanaged config for ${HOTSPOT_INTERFACE}"
    rm -f "$NETWORKMANAGER_UNMANAGED_FILE"

    if systemctl list-unit-files NetworkManager.service >/dev/null 2>&1; then
      systemctl reload NetworkManager.service 2>/dev/null || systemctl restart NetworkManager.service 2>/dev/null || true
    fi
  fi
}

release_hotspot_interface() {
  log "Removing InitBox hotspot IP from ${HOTSPOT_INTERFACE} if present"

  if command_exists ip; then
    ip -4 addr del "${HOTSPOT_GATEWAY}/24" dev "$HOTSPOT_INTERFACE" 2>/dev/null || true
    ip link set "$HOTSPOT_INTERFACE" down 2>/dev/null || true
  fi
}

remove_hotspot_services_and_config() {
  log "Removing InitBox hotspot services and configuration"

  stop_and_disable_unit "dnsmasq.service"
  stop_and_disable_unit "hostapd.service"

  remove_legacy_dnsmasq_dropins
  restore_dnsmasq_conf_if_possible
  remove_dhcpcd_hotspot_block
  remove_hostapd_config_if_owned
  remove_networkmanager_unmanaged_config
  release_hotspot_interface

  systemctl daemon-reload
  systemctl reset-failed 2>/dev/null || true
}

print_summary() {
  local ssid="$1"

  echo
  echo "InitBox hotspot installed"
  echo "-------------------------"
  echo "SSID:       ${ssid}"
  echo "Password:   ${HOTSPOT_PASS}"
  echo "Interface:  ${HOTSPOT_INTERFACE}"
  echo "IP:         ${HOTSPOT_GATEWAY}/24"
  echo "DHCP range: ${HOTSPOT_DHCP_START},${HOTSPOT_DHCP_END},${HOTSPOT_DHCP_LEASE}"
  echo
  echo "Captive DNS:"
  echo "  address=/#/${HOTSPOT_GATEWAY}"
  echo
  echo "Local URLs:"
  echo "  http://initbox.wlan/"
  echo "  http://${HOTSPOT_GATEWAY}/"
  echo
  echo "Config files:"
  echo "  ${HOSTAPD_CONF}"
  echo "  ${HOSTAPD_DEFAULT}"
  echo "  ${DNSMASQ_CONF}"
  echo "  ${DHCPCD_CONF}"
  echo
  echo "Offline field-mode behavior:"
  echo "  - Debian packages are installed from ${INITBOX_PACKAGE_CACHE_DIR}"
  echo "  - uninstall does not remove packages or cached .deb files"
  echo "  - purge is disabled and behaves like uninstall"
  echo
  echo "Check services:"
  echo "  sudo systemctl status hostapd dnsmasq dhcpcd --no-pager"
  echo
  echo "Check wlan0:"
  echo "  ip -4 addr show ${HOTSPOT_INTERFACE}"
  echo
  echo "Check DNS config:"
  echo "  sudo dnsmasq --test"
  echo "  sudo grep -n 'address=/#' ${DNSMASQ_CONF}"
  echo
  echo "Check logs:"
  echo "  sudo journalctl -u hostapd -u dnsmasq -u dhcpcd -b --no-pager -n 120"
}

print_uninstall_summary() {
  echo
  echo "InitBox hotspot uninstalled"
  echo "---------------------------"
  echo "Removed/restored:"
  echo "  - InitBox hostapd config if owned by InitBox"
  echo "  - InitBox dnsmasq config if owned by InitBox"
  echo "  - previous dnsmasq config from ${DNSMASQ_BACKUP}, if backup exists"
  echo "  - InitBox dhcpcd hotspot block"
  echo "  - old InitBox dnsmasq drop-ins, if present"
  echo "  - NetworkManager unmanaged config written by this module"
  echo "  - hotspot IP ${HOTSPOT_GATEWAY}/24 from ${HOTSPOT_INTERFACE}"
  echo
  echo "Not removed:"
  echo "  - installed packages"
  echo "  - cached .deb files under ${INITBOX_PACKAGE_CACHE_DIR}"
  echo "  - ${BOXNO_FILE}"
  echo
  echo "Check:"
  echo "  sudo systemctl status hostapd dnsmasq dhcpcd --no-pager"
  echo "  ip -4 addr show ${HOTSPOT_INTERFACE}"
}

install_main() {
  local boxno=""
  local ssid=""

  require_root
  ensure_log_dir
  validate_hotspot_values
  install_dependencies

  boxno="$(get_box_number)"
  ssid="initbox_${boxno}"

  log "Hotspot SSID=${ssid}, gateway=${HOTSPOT_GATEWAY}, DHCP=${HOTSPOT_DHCP_START}-${HOTSPOT_DHCP_END}"
  log "HOTSPOT_PASS is set but not logged"

  stop_conflicting_wifi_clients
  write_hostapd_conf "$ssid"
  write_dnsmasq_conf
  write_dhcpcd_conf
  validate_configs
  restart_hotspot_stack
  print_summary "$ssid"

  ok "Hotspot module installed. Connect to SSID '${ssid}'."
}

uninstall_main() {
  require_root
  ensure_log_dir

  remove_hotspot_services_and_config
  print_uninstall_summary
  ok "Hotspot module uninstalled."
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
      die "unknown action '$ACTION'. Use install or uninstall."
      ;;
  esac
}

main "$@"

#!/usr/bin/env bash
# InitBox Pi Zero W / Zero 2W ISI module
#
# Actions:
#   install    Install and enable ISI simulator service, but do not start it.
#   uninstall  Remove ISI service and files created by this module.
#   remove     Alias for uninstall.
#   purge      Compatibility alias for uninstall. It does not purge packages.
#
# Offline field-mode policy:
#   - Debian packages are installed from the InitBox local package cache.
#   - Uninstall removes services/config/runtime files only.
#   - Purge is disabled and behaves like uninstall.
#   - Installed packages and cached .deb files are kept.
#
# COPILOT network safety policy:
#   - Installing this module must not bridge Ethernet immediately.
#   - isirunall.service is enabled but stopped after install.
#   - At runtime, the runner waits until a wired Ethernet interface has carrier
#     and a 10.x.x.x IPv4 address before creating br0.
#   - If the COPILOT 10.x network is not ready at boot, the runner retries
#     without changing Ethernet bridge state.
#   - After br0 is created, all bridge member interfaces are kept L2-only.
#
# Config policy:
#   - No NetworkManager drop-ins.
#   - No systemd drop-ins.
#   - No dnsmasq drop-ins.
#   - This module owns only:
#       /usr/local/bin/isirunall.sh
#       /etc/systemd/system/isirunall.service
#       /usr/local/bin/isi1.txt
#       /usr/local/bin/isi2.txt
#       /usr/local/bin/isi3.txt

set -euo pipefail

ACTION="${1:-install}"

: "${OWNER:=initbox}"
: "${LOGFILE:=/home/${OWNER}/pi_logs/initbox-install.log}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${INITBOX_REPO_ROOT:-$(cd "$SCRIPT_DIR/../.." && pwd)}"

INITBOX_PACKAGES_FILE="${INITBOX_PACKAGES_FILE:-$REPO_ROOT/scripts/packages.txt}"
INITBOX_PACKAGE_CACHE_DIR="${INITBOX_PACKAGE_CACHE_DIR:-/opt/initbox/packages}"
PACKAGES_LIB_FILE="$REPO_ROOT/scripts/lib/packages.sh"

ISI_RUNNER="/usr/local/bin/isirunall.sh"
ISI_SERVICE_FILE="/etc/systemd/system/isirunall.service"
ISI_PAYLOAD_1="/usr/local/bin/isi1.txt"
ISI_PAYLOAD_2="/usr/local/bin/isi2.txt"
ISI_PAYLOAD_3="/usr/local/bin/isi3.txt"
ISI_DHCP_RUNTIME_DIR="/run/initbox-isi"

OLD_NM_ISI_CONF="/etc/NetworkManager/conf.d/99-initbox-isi-unmanaged.conf"
DHCPCD_CONF="/etc/dhcpcd.conf"
DHCPCD_BLOCK_START="# BEGIN InitBox ISI bridge unmanaged"
DHCPCD_BLOCK_END="# END InitBox ISI bridge unmanaged"

ts() {
  date '+%Y-%m-%d %H:%M:%S'
}

log() {
  echo "[ISI $(ts)] $*" | tee -a "$LOGFILE"
}

ok() {
  echo "[ISI $(ts)] [OK] $*" | tee -a "$LOGFILE"
}

warn() {
  echo "[ISI $(ts)] [WARN] $*" | tee -a "$LOGFILE" >&2
}

err() {
  echo "[ISI $(ts)] [ERR] $*" | tee -a "$LOGFILE" >&2
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
  log "Installing ISI simulator dependencies from InitBox package cache"
  log "packages file: $INITBOX_PACKAGES_FILE"
  log "cache dir:     $INITBOX_PACKAGE_CACHE_DIR"

  load_package_helper

  initbox_packages_install \
    "$INITBOX_PACKAGES_FILE" \
    "$INITBOX_PACKAGE_CACHE_DIR" \
    isc-dhcp-client \
    netcat-openbsd \
    iproute2 \
    bridge-utils
}

remove_old_dhcpcd_isi_block() {
  local tmp_file=""

  [ -f "$DHCPCD_CONF" ] || return 0

  if ! grep -qF "$DHCPCD_BLOCK_START" "$DHCPCD_CONF"; then
    return 0
  fi

  log "Removing old InitBox ISI dhcpcd block from ${DHCPCD_CONF}"

  tmp_file="$(mktemp)"
  awk -v start="$DHCPCD_BLOCK_START" -v end="$DHCPCD_BLOCK_END" '
    $0 == start { skip=1; next }
    $0 == end { skip=0; next }
    skip != 1 { print }
  ' "$DHCPCD_CONF" >"$tmp_file"

  cat "$tmp_file" >"$DHCPCD_CONF"
  rm -f "$tmp_file"
}

remove_old_isi_network_dropins() {
  log "Removing old ISI network drop-ins, if present"

  rm -f "$OLD_NM_ISI_CONF" 2>/dev/null || true
  remove_old_dhcpcd_isi_block

  systemctl reload NetworkManager.service 2>/dev/null || true
  systemctl restart NetworkManager.service 2>/dev/null || true
  systemctl restart dhcpcd.service 2>/dev/null || true
}

write_isi_runner() {
  log "Writing ${ISI_RUNNER}"

  cat >"$ISI_RUNNER" <<'RUNNER_EOF'
#!/usr/bin/env bash
set -euo pipefail

BRIDGE="${BRIDGE:-br0}"
DHCP_RUNTIME_DIR="${DHCP_RUNTIME_DIR:-/run/initbox-isi}"
DRIFT_THRESHOLD="${DRIFT_THRESHOLD:-5}"
TIME_SYNC_INTERVAL="${TIME_SYNC_INTERVAL:-60}"
TIME_SYNC_RETRY_INTERVAL="${TIME_SYNC_RETRY_INTERVAL:-30}"
MAX_COPILOT_TIME_JUMP="${MAX_COPILOT_TIME_JUMP:-172800}"
COPILOT_GATE_RETRY_SECONDS="${COPILOT_GATE_RETRY_SECONDS:-5}"
BRIDGE_IP_CLEAN_INTERVAL="${BRIDGE_IP_CLEAN_INTERVAL:-2}"
UPLINK_IF="${UPLINK_IF:-}"

ISI_FILES=(
  "/usr/local/bin/isi1.txt"
  "/usr/local/bin/isi2.txt"
  "/usr/local/bin/isi3.txt"
)

NAMES=(
  "DRACHE"
  "NIX"
  "ZEITNEHMER"
)

NS=(
  "ns1"
  "ns2"
  "ns3"
)

DEST_IP=""
NS_IPS=()
BRIDGE_CREATED_BY_ISI=0
BRIDGE_PORTS_ADDED_BY_ISI=()
IP_CLEANER_PID=""
NM_UNMANAGED_BY_ISI=()
L2_PREPARED_BY_ISI=()
DHCP_CLIENT_PIDS=()

log() {
  echo "[ISI $(date '+%F_%T')] $*"
}

is_positive_integer() {
  local value="$1"

  [[ "$value" =~ ^[0-9]+$ ]] && [ "$value" -gt 0 ]
}

array_contains() {
  local needle="$1"
  shift
  local item=""

  for item in "$@"; do
    [ "$item" = "$needle" ] && return 0
  done

  return 1
}

sanitize_runtime_settings() {
  if ! is_positive_integer "$COPILOT_GATE_RETRY_SECONDS"; then
    log "WARN: invalid COPILOT_GATE_RETRY_SECONDS=${COPILOT_GATE_RETRY_SECONDS}; using 5."
    COPILOT_GATE_RETRY_SECONDS="5"
  fi

  if ! is_positive_integer "$BRIDGE_IP_CLEAN_INTERVAL"; then
    log "WARN: invalid BRIDGE_IP_CLEAN_INTERVAL=${BRIDGE_IP_CLEAN_INTERVAL}; using 2."
    BRIDGE_IP_CLEAN_INTERVAL="2"
  fi
}

is_excluded_interface() {
  local iface="$1"

  case "$iface" in
    lo|wlan*|wifi*|br*|veth*|docker*|virbr*|tap*|tun*|wg*|tailscale*|zt*|dummy*|ifb*|sit*|ip6tnl*|gre*|gretap*)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

is_wired_ethernet_candidate() {
  local iface="$1"
  local dev_type=""

  is_excluded_interface "$iface" && return 1
  [ -r "/sys/class/net/${iface}/type" ] || return 1

  dev_type="$(cat "/sys/class/net/${iface}/type" 2>/dev/null || printf '')"
  [ "$dev_type" = "1" ] || return 1

  case "$iface" in
    eth*|en*|usb*)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

detect_wired_ethernet_ports() {
  local iface_path=""
  local iface=""
  local detected=()

  for iface_path in /sys/class/net/*; do
    iface="$(basename "$iface_path")"

    if is_wired_ethernet_candidate "$iface"; then
      detected+=("$iface")
    fi
  done

  if [ "${#detected[@]}" -gt 0 ]; then
    printf '%s\n' "${detected[@]}" | sort -V
  fi
}

detect_bridge_ports() {
  local wired_ifs=()

  if [ -n "$UPLINK_IF" ]; then
    if ! ip link show "$UPLINK_IF" >/dev/null 2>&1; then
      log "ERROR: UPLINK_IF=${UPLINK_IF} does not exist."
      exit 1
    fi

    if ! is_wired_ethernet_candidate "$UPLINK_IF"; then
      log "ERROR: UPLINK_IF=${UPLINK_IF} is not a valid wired Ethernet candidate."
      exit 1
    fi

    printf '%s\n' "$UPLINK_IF"
    return 0
  fi

  mapfile -t wired_ifs < <(detect_wired_ethernet_ports)

  if [ "${#wired_ifs[@]}" -eq 0 ]; then
    log "ERROR: No wired Ethernet interfaces found for ${BRIDGE}."
    log "ERROR: Check carrier board, USB Ethernet adapters, cabling, and interface names."
    exit 1
  fi

  printf '%s\n' "${wired_ifs[@]}"
}

interface_has_carrier() {
  local iface="$1"

  [ -r "/sys/class/net/${iface}/carrier" ] || return 1
  [ "$(cat "/sys/class/net/${iface}/carrier" 2>/dev/null || printf '0')" = "1" ]
}

interface_has_10_network() {
  local iface="$1"

  ip -4 -o addr show dev "$iface" 2>/dev/null \
    | awk '{print $4}' \
    | grep -Eq '^10\.'
}

detect_copilot_gate_port() {
  local iface=""

  while IFS= read -r iface; do
    [ -z "$iface" ] && continue

    if ! interface_has_carrier "$iface"; then
      log "Gate: ${iface} has no carrier; retrying later." >&2
      continue
    fi

    if interface_has_10_network "$iface"; then
      log "Gate: COPILOT candidate detected on ${iface}; IPv4 is in 10.x.x.x." >&2
      printf '%s\n' "$iface"
      return 0
    fi

    log "Gate: ${iface} has carrier but no 10.x.x.x IPv4 address yet; retrying later." >&2
  done < <(detect_wired_ethernet_ports)

  return 1
}

require_copilot_network_gate() {
  local gate_port=""

  while true; do
    if gate_port="$(detect_copilot_gate_port)"; then
      log "COPILOT network gate passed on ${gate_port}."

      if [ -n "$UPLINK_IF" ]; then
        log "Operator supplied UPLINK_IF=${UPLINK_IF}; only that interface will be bridged."
      else
        log "UPLINK_IF is not set; all detected wired Ethernet ports will be bridged."
        log "This supports Pi-in-the-middle mode, for example eth0 to COPILOT and eth1 to switch."
      fi

      return 0
    fi

    log "COPILOT network gate not passed yet."
    log "Waiting for wired Ethernet carrier and 10.x.x.x IPv4 before creating ${BRIDGE}."
    log "Ethernet is still untouched. Retrying in ${COPILOT_GATE_RETRY_SECONDS}s."
    sleep "$COPILOT_GATE_RETRY_SECONDS"
  done
}

is_pi_zero_like() {
  local model=""

  model="$(tr -d '\0' </proc/device-tree/model 2>/dev/null || printf '')"

  case "$model" in
    *"Zero"*)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

release_dhcp_on_interface() {
  local iface="$1"

  if command -v dhclient >/dev/null 2>&1; then
    dhclient -r "$iface" >/dev/null 2>&1 || true
  fi
}

stop_dhcpcd_on_interface() {
  local iface="$1"

  if command -v dhcpcd >/dev/null 2>&1; then
    dhcpcd -k "$iface" >/dev/null 2>&1 || true
  fi
}

interface_has_any_ip_address() {
  local iface="$1"

  ip -o addr show dev "$iface" 2>/dev/null | grep -q .
}

flush_interface_addresses() {
  local iface="$1"

  ip -4 addr flush dev "$iface" 2>/dev/null || true
  ip -6 addr flush dev "$iface" 2>/dev/null || true
  ip -4 route flush dev "$iface" 2>/dev/null || true
  ip -6 route flush dev "$iface" 2>/dev/null || true
}

set_interface_ipv6_disabled() {
  local iface="$1"

  if [ -w "/proc/sys/net/ipv6/conf/${iface}/accept_ra" ]; then
    printf '0\n' >"/proc/sys/net/ipv6/conf/${iface}/accept_ra" 2>/dev/null || true
  fi

  if [ -w "/proc/sys/net/ipv6/conf/${iface}/autoconf" ]; then
    printf '0\n' >"/proc/sys/net/ipv6/conf/${iface}/autoconf" 2>/dev/null || true
  fi

  if [ -w "/proc/sys/net/ipv6/conf/${iface}/disable_ipv6" ]; then
    printf '1\n' >"/proc/sys/net/ipv6/conf/${iface}/disable_ipv6" 2>/dev/null || true
  fi
}

set_interface_ipv6_enabled() {
  local iface="$1"

  if [ -w "/proc/sys/net/ipv6/conf/${iface}/disable_ipv6" ]; then
    printf '0\n' >"/proc/sys/net/ipv6/conf/${iface}/disable_ipv6" 2>/dev/null || true
  fi
}

mark_nm_unmanaged_runtime() {
  local iface="$1"

  if ! command -v nmcli >/dev/null 2>&1; then
    return 0
  fi

  if ! array_contains "$iface" "${NM_UNMANAGED_BY_ISI[@]+"${NM_UNMANAGED_BY_ISI[@]}"}"; then
    NM_UNMANAGED_BY_ISI+=("$iface")
  fi

  nmcli device set "$iface" managed no >/dev/null 2>&1 || true
  nmcli device disconnect "$iface" >/dev/null 2>&1 || true
}

restore_nm_managed_runtime() {
  local iface=""

  if ! command -v nmcli >/dev/null 2>&1; then
    return 0
  fi

  for iface in "${NM_UNMANAGED_BY_ISI[@]+"${NM_UNMANAGED_BY_ISI[@]}"}"; do
    [ -n "$iface" ] || continue
    nmcli device set "$iface" managed yes >/dev/null 2>&1 || true
  done

  NM_UNMANAGED_BY_ISI=()
}

prepare_l2_runtime_once() {
  local iface="$1"

  if array_contains "$iface" "${L2_PREPARED_BY_ISI[@]+"${L2_PREPARED_BY_ISI[@]}"}"; then
    return 0
  fi

  L2_PREPARED_BY_ISI+=("$iface")
  mark_nm_unmanaged_runtime "$iface"
  stop_dhcpcd_on_interface "$iface"
  release_dhcp_on_interface "$iface"
  set_interface_ipv6_disabled "$iface"
  flush_interface_addresses "$iface"
}

prepare_port_for_bridge() {
  local iface="$1"

  ip link set "$iface" up 2>/dev/null || true
  prepare_l2_runtime_once "$iface"
}

attach_port_to_bridge() {
  local iface="$1"
  local current_master=""

  if ! ip link show "$iface" >/dev/null 2>&1; then
    log "WARN: Interface ${iface} disappeared before bridge attach; skipping it."
    return 0
  fi

  current_master="$(basename "$(readlink "/sys/class/net/${iface}/master" 2>/dev/null || printf '')")"

  if [ -n "$current_master" ] && [ "$current_master" != "$BRIDGE" ]; then
    log "ERROR: ${iface} is already enslaved to ${current_master}, refusing to steal it."
    exit 1
  fi

  prepare_port_for_bridge "$iface"

  if [ "$current_master" != "$BRIDGE" ]; then
    log "Adding wired port ${iface} to ${BRIDGE}"
    ip link set "$iface" master "$BRIDGE"
    BRIDGE_PORTS_ADDED_BY_ISI+=("$iface")
  fi

  ip link set "$iface" up 2>/dev/null || true
  flush_interface_addresses "$iface"
}

bridge_member_interfaces() {
  ip -o link show master "$BRIDGE" 2>/dev/null \
    | awk -F': ' '{print $2}' \
    | cut -d'@' -f1 \
    | while IFS= read -r iface; do
        [ -n "$iface" ] || continue

        case "$iface" in
          lo|wlan*|wifi*|br*|docker*|virbr*|tap*|tun*|wg*|tailscale*|zt*|dummy*|ifb*|sit*|ip6tnl*|gre*|gretap*)
            continue
            ;;
          veth[0-9]*_host|eth*|en*|usb*)
            printf '%s\n' "$iface"
            ;;
          *)
            printf '%s\n' "$iface"
            ;;
        esac
      done
}

enforce_l2_only_on_interface() {
  local iface="$1"
  local still_has_address=0

  prepare_l2_runtime_once "$iface"

  if ! interface_has_any_ip_address "$iface"; then
    return 0
  fi

  flush_interface_addresses "$iface"

  if interface_has_any_ip_address "$iface"; then
    sleep 1
    flush_interface_addresses "$iface"
  fi

  if interface_has_any_ip_address "$iface"; then
    still_has_address=1
  fi

  if [ "$still_has_address" -eq 1 ]; then
    log "WARN: ${iface} still has an IP address after L2-only cleanup."
    ip -o addr show dev "$iface" 2>/dev/null || true
  else
    log "Removed IP address from ${BRIDGE} member ${iface}; kept it L2-only."
  fi
}

flush_bridge_member_ips_once() {
  local iface=""

  while IFS= read -r iface; do
    [ -n "$iface" ] || continue
    enforce_l2_only_on_interface "$iface"
  done < <(bridge_member_interfaces)
}

keep_bridge_members_ip_free() {
  log "Starting ${BRIDGE} member IP cleaner; interval=${BRIDGE_IP_CLEAN_INTERVAL}s."

  while true; do
    flush_bridge_member_ips_once
    sleep "$BRIDGE_IP_CLEAN_INTERVAL"
  done
}

start_bridge_ip_cleaner() {
  if [ -n "$IP_CLEANER_PID" ] && kill -0 "$IP_CLEANER_PID" 2>/dev/null; then
    return 0
  fi

  flush_bridge_member_ips_once
  keep_bridge_members_ip_free &
  IP_CLEANER_PID="$!"
}

stop_bridge_ip_cleaner() {
  if [ -n "$IP_CLEANER_PID" ]; then
    kill -TERM "$IP_CLEANER_PID" 2>/dev/null || true
    wait "$IP_CLEANER_PID" 2>/dev/null || true
    IP_CLEANER_PID=""
  fi
}

setup_bridge_for_isi() {
  local bridge_ports=()
  local iface=""

  if ! is_pi_zero_like; then
    log "ERROR: ISI auto bridge setup is only supported on Pi Zero W / Zero 2W by this module."
    exit 1
  fi

  mapfile -t bridge_ports < <(detect_bridge_ports)
  log "Detected wired Ethernet bridge ports: ${bridge_ports[*]}"

  if ip link show "$BRIDGE" >/dev/null 2>&1; then
    log "${BRIDGE} already exists; reusing it and ensuring all detected wired ports are attached."
  else
    log "Creating ${BRIDGE} for ISI."
    ip link add name "$BRIDGE" type bridge
    BRIDGE_CREATED_BY_ISI=1
  fi

  set_interface_ipv6_disabled "$BRIDGE"
  ip link set "$BRIDGE" type bridge stp_state 0 forward_delay 0 2>/dev/null || true
  ip addr flush dev "$BRIDGE" 2>/dev/null || true
  ip link set "$BRIDGE" up

  for iface in "${bridge_ports[@]}"; do
    attach_port_to_bridge "$iface"
  done

  ip link set "$BRIDGE" up
  flush_bridge_member_ips_once
  start_bridge_ip_cleaner

  log "${BRIDGE} is ready with wired ports: ${bridge_ports[*]}"
  log "Current bridge membership:"
  bridge link 2>/dev/null || true
}

teardown_bridge_for_isi() {
  local iface=""

  stop_bridge_ip_cleaner

  for iface in "${BRIDGE_PORTS_ADDED_BY_ISI[@]+"${BRIDGE_PORTS_ADDED_BY_ISI[@]}"}"; do
    ip link set "$iface" nomaster 2>/dev/null || true
    set_interface_ipv6_enabled "$iface"
    ip link set "$iface" up 2>/dev/null || true
  done

  set_interface_ipv6_enabled "$BRIDGE"
  L2_PREPARED_BY_ISI=()
  restore_nm_managed_runtime

  if [ "$BRIDGE_CREATED_BY_ISI" -eq 1 ]; then
    log "Tearing down ${BRIDGE} created by ISI."
    ip link set "$BRIDGE" down 2>/dev/null || true
    ip link del "$BRIDGE" type bridge 2>/dev/null || true
  fi
}

cleanup_ns() {
  local ns=""
  local pid=""
  local link_name=""

  for ns in "${NS[@]}"; do
    if ip netns pids "$ns" >/dev/null 2>&1; then
      while read -r pid; do
        [ -n "$pid" ] && kill -TERM "$pid" 2>/dev/null || true
      done < <(ip netns pids "$ns" 2>/dev/null || true)
    fi

    ip netns del "$ns" 2>/dev/null || true
  done

  while read -r link_name; do
    [ -n "$link_name" ] && ip link del "$link_name" 2>/dev/null || true
  done < <(
    ip -o link show \
      | awk -F': ' '{print $2}' \
      | cut -d'@' -f1 \
      | grep -E '^veth[0-9]+_(host|ns)$' 2>/dev/null || true
  )
}

cleanup_dhcp_runtime() {
  mkdir -p "$DHCP_RUNTIME_DIR"
  rm -f "${DHCP_RUNTIME_DIR}"/dhclient-ns*.leases \
    "${DHCP_RUNTIME_DIR}"/dhclient-ns*.pid \
    "${DHCP_RUNTIME_DIR}"/dhclient-ns*.conf
}

uniq_mac() {
  local seed="$1"
  local hash=""

  hash="$(printf '%s' "$seed" | sha1sum | awk '{print $1}')"

  printf '02:%s:%s:%s:%s:%s\n' \
    "${hash:0:2}" \
    "${hash:2:2}" \
    "${hash:4:2}" \
    "${hash:6:2}" \
    "${hash:8:2}"
}

add_veth_to_br() {
  local idx="$1"
  local ns="$2"
  local ifh="veth${idx}_host"
  local ifn="veth${idx}_ns"

  ip link del "$ifh" 2>/dev/null || true
  ip link del "$ifn" 2>/dev/null || true

  ip link add "$ifh" type veth peer name "$ifn"
  ip link set "$ifh" address "$(uniq_mac "$ifh")"
  prepare_l2_runtime_once "$ifh"
  ip link set "$ifh" master "$BRIDGE"
  ip link set "$ifh" up
  flush_interface_addresses "$ifh"

  ip netns add "$ns"
  ip link set "$ifn" netns "$ns"
  ip netns exec "$ns" ip link set lo up
  ip netns exec "$ns" ip link set "$ifn" address "$(uniq_mac "$ifn")"
  ip netns exec "$ns" ip addr flush dev "$ifn" 2>/dev/null || true
  ip netns exec "$ns" ip link set "$ifn" up

  flush_bridge_member_ips_once
}

cleanup_dhcp_clients() {
  local pid=""

  for pid in "${DHCP_CLIENT_PIDS[@]+"${DHCP_CLIENT_PIDS[@]}"}"; do
    [ -n "$pid" ] || continue
    kill -TERM "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  done

  DHCP_CLIENT_PIDS=()

  pkill -f 'dhclient .*veth[0-9]+_ns' 2>/dev/null || true
}

write_minimal_dhclient_script() {
  local script_file="$1"

  cat >"$script_file" <<'EOF_DHCLIENT_SCRIPT'
#!/usr/bin/env bash
set -euo pipefail

mask_to_prefix() {
  local mask="${1:-255.255.255.0}"
  local old_ifs="$IFS"
  local octet=""
  local binary=""
  local prefix=0

  IFS='.'
  for octet in $mask; do
    case "$octet" in
      255) binary="${binary}11111111" ;;
      254) binary="${binary}11111110" ;;
      252) binary="${binary}11111100" ;;
      248) binary="${binary}11111000" ;;
      240) binary="${binary}11110000" ;;
      224) binary="${binary}11100000" ;;
      192) binary="${binary}11000000" ;;
      128) binary="${binary}10000000" ;;
      0) binary="${binary}00000000" ;;
      *) binary="${binary}11111111" ;;
    esac
  done
  IFS="$old_ifs"

  prefix="${binary%%0*}"
  printf '%s\n' "${#prefix}"
}

first_word() {
  local value="${1:-}"

  set -- $value
  printf '%s\n' "${1:-}"
}

case "${reason:-}" in
  BOUND|RENEW|REBIND|REBOOT)
    prefix="$(mask_to_prefix "${new_subnet_mask:-255.255.255.0}")"
    router="$(first_word "${new_routers:-}")"

    ip addr flush dev "$interface" 2>/dev/null || true
    ip addr add "${new_ip_address}/${prefix}" dev "$interface"
    ip link set "$interface" up

    if [ -n "$router" ]; then
      ip route replace default via "$router" dev "$interface" 2>/dev/null || true
    fi
    ;;
  EXPIRE|FAIL|RELEASE|STOP)
    ip addr flush dev "$interface" 2>/dev/null || true
    ;;
  *)
    ;;
esac

exit 0
EOF_DHCLIENT_SCRIPT

  chmod 0755 "$script_file"
  chown root:root "$script_file" 2>/dev/null || true
}

request_fresh_dhcp() {
  local ns="$1"
  local iface="$2"
  local lease_file="${DHCP_RUNTIME_DIR}/dhclient-${ns}.leases"
  local pid_file="${DHCP_RUNTIME_DIR}/dhclient-${ns}.pid"
  local conf_file="${DHCP_RUNTIME_DIR}/dhclient-${ns}.conf"
  local script_file="/usr/local/sbin/initbox-isi-dhclient-script.sh"
  local dhcp_out=""
  local dhcp_pid=""
  local status=0

  mkdir -p "$DHCP_RUNTIME_DIR"
  rm -f "$lease_file" "$pid_file" "$conf_file"
  : >"$lease_file"

  printf 'bootp-broadcast-always;\nrequest subnet-mask, routers, domain-name-servers, broadcast-address;\n' >"$conf_file"
  write_minimal_dhclient_script "$script_file"

  ip netns exec "$ns" ip addr flush dev "$iface" 2>/dev/null || true

  log "Requesting fresh DHCP for ${ns} on ${iface} (broadcast-mode, stable MAC, minimal script)"

  dhcp_out="$(
    set +e
    timeout 35s ip netns exec "$ns" dhclient \
      -4 \
      -1 \
      -d \
      -v \
      -sf "$script_file" \
      -cf "$conf_file" \
      -lf "$lease_file" \
      -pf "$pid_file" \
      "$iface" 2>&1
    status="$?"

    if [ -f "$pid_file" ]; then
      dhcp_pid="$(cat "$pid_file" 2>/dev/null || true)"
      if [ -n "$dhcp_pid" ]; then
        kill -TERM "$dhcp_pid" 2>/dev/null || true
        wait "$dhcp_pid" 2>/dev/null || true
      fi
      rm -f "$pid_file"
    fi

    exit "$status"
  )" || status="$?"

  if [ -f "$pid_file" ]; then
    dhcp_pid="$(cat "$pid_file" 2>/dev/null || true)"
    if [ -n "$dhcp_pid" ]; then
      kill -TERM "$dhcp_pid" 2>/dev/null || true
      wait "$dhcp_pid" 2>/dev/null || true
    fi
    rm -f "$pid_file"
  fi

  rm -f "$lease_file" "$conf_file"

  if [ "$status" -eq 124 ]; then
    printf '%s\n' "$dhcp_out"
    printf '%s\n' "DHCP timeout after 35 seconds"
    return 0
  fi

  printf '%s\n' "$dhcp_out"
}

discover_copilot_from_dhcp() {
  local dhcp_out="$1"
  local srv=""
  local gw=""

  [ -n "$DEST_IP" ] && return 0

  srv="$(
    printf '%s\n' "$dhcp_out" \
      | sed -nE 's/.*DHCPACK of [^ ]+ from ([0-9.]+).*/\1/p' \
      | tail -1
  )"

  if [[ "$srv" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
    DEST_IP="$srv"
    log "COPILOT discovered from DHCPACK server address: ${DEST_IP}"
    return 0
  fi

  gw="$(
    printf '%s\n' "$dhcp_out" \
      | sed -nE 's/.*option routers[[:space:]]+([0-9.]+).*/\1/p' \
      | tail -1
  )"

  if [[ "$gw" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
    DEST_IP="$gw"
    log "COPILOT discovered from DHCP routers option: ${DEST_IP}"
    return 0
  fi
}

start_isi_loop() {
  local ns="$1"
  local file="$2"
  local name="$3"

  log "Starting persistent ISI client ${name} in ${ns} -> ${DEST_IP}:51001"

  ip netns exec "$ns" bash -lc "
    while true; do
      nc '${DEST_IP}' 51001 < '${file}' >/dev/null 2>&1 || sleep 1
    done
  " &
}

full_cleanup() {
  stop_bridge_ip_cleaner
  cleanup_dhcp_clients
  cleanup_ns
  cleanup_dhcp_runtime
  teardown_bridge_for_isi
}

trap full_cleanup EXIT

sanitize_runtime_settings
require_copilot_network_gate
setup_bridge_for_isi
cleanup_dhcp_runtime
cleanup_ns

for _ in {1..10}; do
  ip -br link show "$BRIDGE" | grep -q '\<UP\>' && break
  sleep 1
done

if ! ip -br link show "$BRIDGE" | grep -q '\<UP\>'; then
  log "ERROR: ${BRIDGE} did not come UP"
  exit 1
fi

log "${BRIDGE} is UP"

if ! command -v dhclient >/dev/null 2>&1; then
  log "ERROR: dhclient missing"
  exit 1
fi

if ! command -v nc >/dev/null 2>&1 && ! command -v netcat >/dev/null 2>&1; then
  log "ERROR: nc/netcat missing"
  exit 1
fi

for i in "${!NS[@]}"; do
  ns="${NS[$i]}"
  idx=$((i + 1))

  add_veth_to_br "$idx" "$ns"

  DHCP_OUT="$(request_fresh_dhcp "$ns" "veth${idx}_ns")"

  if ! printf '%s' "$DHCP_OUT" | grep -q 'DHCPACK'; then
    log "ERROR: DHCP failed in ${ns}"
    log "--- DHCP output ---"
    printf '%s\n' "$DHCP_OUT" >&2
    log "-------------------"
    exit 1
  fi

  ns_ip="$(
    ip netns exec "$ns" ip -o -4 addr show "veth${idx}_ns" \
      | awk '{print $4}' \
      | cut -d/ -f1 || true
  )"

  NS_IPS+=("${ns_ip:-}")
  log "${ns} assigned IP ${ns_ip:-unknown}"

  discover_copilot_from_dhcp "$DHCP_OUT"

  if [ -z "$DEST_IP" ]; then
    gw="$(
      ip netns exec "$ns" ip route show default 2>/dev/null \
        | awk '/^default via /{print $3; exit}'
    )"

    if [[ "$gw" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
      DEST_IP="$gw"
      log "COPILOT discovered from namespace default gateway: ${DEST_IP}"
    fi
  fi
done

if [ -z "$DEST_IP" ]; then
  log "ERROR: Could not determine COPILOT IP from DHCP server, routers option, or default gateway."
  exit 1
fi

log "COPILOT target: ${DEST_IP}"

flush_bridge_member_ips_once

start_isi_loop "${NS[0]}" "${ISI_FILES[0]}" "${NAMES[0]}"
start_isi_loop "${NS[1]}" "${ISI_FILES[1]}" "${NAMES[1]}"
start_isi_loop "${NS[2]}" "${ISI_FILES[2]}" "${NAMES[2]}"

zeit_ns="${NS[2]}"

build_zeitnehmer_payload() {
  local item_name="$1"

  cat <<EOF_PAYLOAD
<IsiPut><AppName>ZEITNEHMER</AppName></IsiPut>
<IsiGet><Items>${item_name}</Items><Cyclic>0</Cyclic></IsiGet>
EOF_PAYLOAD
}

request_copilot_time_item() {
  local item_name="$1"
  local payload_file=""
  local response=""

  payload_file="$(mktemp)"
  build_zeitnehmer_payload "$item_name" >"$payload_file"

  response="$({
    timeout 10s ip netns exec "$zeit_ns" nc -w 5 "$DEST_IP" 51001 <"$payload_file"
  } 2>/dev/null || true)"

  rm -f "$payload_file"

  printf '%s\n' "$response"
}

parse_iso_time() {
  local response="$1"

  printf '%s\n' "$response" \
    | grep -oE '<Time_ISO8601>[^<]+</Time_ISO8601>|[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}([.,][0-9]+)?([Zz]|[+-][0-9]{2}:?[0-9]{2})?' \
    | sed -E 's#</?Time_ISO8601>##g' \
    | head -n 1 || true
}

parse_legacy_datetime() {
  local response="$1"

  printf '%s\n' "$response" \
    | grep -oE '<DateTime>[^<]+</DateTime>|[0-9]{2}\.[0-9]{2}\.[0-9]{4}-[0-9]{2}:[0-9]{2}:[0-9]{2}' \
    | sed -E 's#</?DateTime>##g' \
    | head -n 1 || true
}

epoch_from_iso() {
  local iso_dt="$1"

  date -d "$iso_dt" +%s 2>/dev/null || printf '0\n'
}

epoch_from_legacy_datetime() {
  local legacy_dt="$1"
  local dpart=""
  local tpart=""
  local dd=""
  local mm=""
  local yyyy=""

  dpart="${legacy_dt%%-*}"
  tpart="${legacy_dt#*-}"

  IFS='.' read -r dd mm yyyy <<EOF_DT
$dpart
EOF_DT

  date -d "${yyyy}-${mm}-${dd} ${tpart}" +%s 2>/dev/null || printf '0\n'
}

set_system_time_from_epoch() {
  local epoch="$1"

  if command -v timedatectl >/dev/null 2>&1; then
    timedatectl set-time "@${epoch}" >/dev/null 2>&1 || date -s "@${epoch}" >/dev/null 2>&1
  else
    date -s "@${epoch}" >/dev/null 2>&1
  fi
}

apply_copilot_epoch_if_needed() {
  local master_epoch="$1"
  local source_name="$2"
  local now_epoch=0
  local diff=0
  local adiff=0

  if [ "$master_epoch" -le 0 ]; then
    log "ZEITNEHMER: ${source_name} was present but could not be parsed; continuing without clock adjustment"
    return 1
  fi

  now_epoch="$(date +%s)"
  diff=$((master_epoch - now_epoch))
  adiff="${diff#-}"

  log "ZEITNEHMER: Pi=${now_epoch} COPILOT=${master_epoch} drift=${diff}s source=${source_name}"

  if [ "$adiff" -le "$DRIFT_THRESHOLD" ]; then
    log "ZEITNEHMER: drift ${adiff}s <= ${DRIFT_THRESHOLD}s; no adjust"
    return 0
  fi

  if [ "$adiff" -gt "$MAX_COPILOT_TIME_JUMP" ]; then
    log "ZEITNEHMER: drift ${adiff}s exceeds MAX_COPILOT_TIME_JUMP=${MAX_COPILOT_TIME_JUMP}; rejecting COPILOT time"
    return 1
  fi

  log "ZEITNEHMER: drift ${adiff}s > ${DRIFT_THRESHOLD}s; adjusting system clock from ${source_name}"

  if set_system_time_from_epoch "$master_epoch"; then
    log "ZEITNEHMER: system clock adjusted from ${source_name}"
    return 0
  fi

  log "ZEITNEHMER: clock set failed; continuing"
  return 1
}

sync_time_from_copilot() {
  local response=""
  local value=""
  local master_epoch=0

  response="$(request_copilot_time_item "Time_ISO8601")"
  value="$(parse_iso_time "$response")"

  if [ -n "$value" ]; then
    log "ZEITNEHMER: COPILOT Time_ISO8601=${value}"
    master_epoch="$(epoch_from_iso "$value")"
    apply_copilot_epoch_if_needed "$master_epoch" "Time_ISO8601"
    return $?
  fi

  log "ZEITNEHMER: no usable Time_ISO8601 returned; trying DateTime."

  response="$(request_copilot_time_item "DateTime")"
  value="$(parse_legacy_datetime "$response")"

  if [ -n "$value" ]; then
    log "ZEITNEHMER: COPILOT DateTime=${value}"
    master_epoch="$(epoch_from_legacy_datetime "$value")"
    apply_copilot_epoch_if_needed "$master_epoch" "DateTime"
    return $?
  fi

  log "ZEITNEHMER: no COPILOT Time_ISO8601 or DateTime found."
  return 1
}

log "ZEITNEHMER loop starting in ${zeit_ns}; sync interval=${TIME_SYNC_INTERVAL}s; retry interval=${TIME_SYNC_RETRY_INTERVAL}s."

NEXT_TIME_SYNC=0

while true; do
  NOW_EPOCH="$(date +%s)"

  if [ "$NOW_EPOCH" -ge "$NEXT_TIME_SYNC" ]; then
    if sync_time_from_copilot; then
      NEXT_TIME_SYNC=$((NOW_EPOCH + TIME_SYNC_INTERVAL))
    else
      NEXT_TIME_SYNC=$((NOW_EPOCH + TIME_SYNC_RETRY_INTERVAL))
    fi
  fi

  sleep 1
done
RUNNER_EOF

  chmod 0755 "$ISI_RUNNER"
  chown root:root "$ISI_RUNNER" 2>/dev/null || true
}

write_isi_payloads() {
  log "Writing ISI payload files"

  cat >"$ISI_PAYLOAD_1" <<'EOF'
<IsiPut><AppName>DRACHE</AppName></IsiPut>
<IsiGet><Items>CurrentSoftwareVersion</Items><Cyclic>1</Cyclic></IsiGet>
EOF

  cat >"$ISI_PAYLOAD_2" <<'EOF'
<IsiPut><AppName>NIX</AppName></IsiPut>
<IsiGet><Items>DeviceState</Items><Cyclic>1</Cyclic></IsiGet>
EOF

  cat >"$ISI_PAYLOAD_3" <<'EOF'
<IsiPut><AppName>ZEITNEHMER</AppName></IsiPut>
<IsiGet><Items>Time_ISO8601</Items><Cyclic>1</Cyclic></IsiGet>
EOF

  chown root:root "$ISI_PAYLOAD_1" "$ISI_PAYLOAD_2" "$ISI_PAYLOAD_3" 2>/dev/null || true
  chmod 0644 "$ISI_PAYLOAD_1" "$ISI_PAYLOAD_2" "$ISI_PAYLOAD_3"
}

write_isi_service() {
  log "Installing isirunall.service"

  cat >"$ISI_SERVICE_FILE" <<EOF
[Unit]
Description=ISI simulator (3 namespaces + persistent ISI clients over br0)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
ExecStart=${ISI_RUNNER}
Restart=on-failure
RestartSec=3
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
}

enable_but_do_not_start_isi_service() {
  systemctl daemon-reload
  systemctl enable isirunall.service
  systemctl stop isirunall.service 2>/dev/null || true
}

stop_and_disable_unit() {
  local unit_name="$1"

  log "Stopping and disabling ${unit_name}"
  systemctl disable --now "$unit_name" 2>/dev/null || true
  systemctl reset-failed "$unit_name" 2>/dev/null || true
}

cleanup_runtime_network_state() {
  local link_name=""
  local ns=""

  log "Cleaning runtime namespaces, veth links, and DHCP state"

  for ns in ns1 ns2 ns3; do
    ip netns del "$ns" 2>/dev/null || true
  done

  while read -r link_name; do
    [ -n "$link_name" ] && ip link del "$link_name" 2>/dev/null || true
  done < <(
    ip -o link show \
      | awk -F': ' '{print $2}' \
      | cut -d'@' -f1 \
      | grep -E '^veth[0-9]+_(host|ns)$' 2>/dev/null || true
  )

  rm -rf "$ISI_DHCP_RUNTIME_DIR" 2>/dev/null || true
}

remove_isi_files() {
  log "Removing ISI files"

  rm -f "$ISI_RUNNER" \
    "$ISI_PAYLOAD_1" \
    "$ISI_PAYLOAD_2" \
    "$ISI_PAYLOAD_3" \
    "$ISI_SERVICE_FILE"
}

print_install_summary() {
  cat <<SUMMARY

ISI simulator installed
-----------------------
Service : isirunall.service
Runner  : ${ISI_RUNNER}

Safety behaviour:
  - install does not start isirunall.service
  - install does not bridge, flush, or enslave Ethernet ports
  - runtime waits until a wired Ethernet port has carrier and 10.x.x.x IPv4
  - while COPILOT gate is not ready, Ethernet is left untouched and the service retries
  - when UPLINK_IF is unset, all detected wired Ethernet ports are bridged after the gate passes
  - when UPLINK_IF is set, only that interface is bridged
  - physical bridge ports and host-side veth ports are kept L2-only

Config policy:
  - no NetworkManager drop-ins
  - no systemd drop-ins
  - no dnsmasq drop-ins
  - stale old ISI NetworkManager/dhcpcd overrides are removed if found

Key behaviours:
  - STP disabled, forward_delay 0
  - bootp-broadcast-always in dhclient config
  - deterministic veth MACs
  - fresh DHCP per namespace
  - COPILOT IP discovered from DHCP server / routers option / default gateway
  - no hardcoded COPILOT IP
  - DRACHE, NIX, and ZEITNEHMER are started as persistent ISI clients
  - ZEITNEHMER time sync still requests Time_ISO8601 first, then DateTime fallback
  - Pi Zero system clock is corrected from COPILOT only when drift exceeds threshold
  - COPILOT gate retry interval defaults to 5 seconds
  - bridge member IP cleanup interval defaults to 2 seconds

Offline field-mode behaviour:
  - Debian packages are installed from ${INITBOX_PACKAGE_CACHE_DIR}
  - uninstall does not remove packages or cached .deb files
  - purge is disabled and behaves like uninstall

Check status:
  sudo systemctl status isirunall.service --no-pager
  sudo journalctl -u isirunall.service -n 100 --no-pager

Manual start when connected to COPILOT 10.x network:
  sudo systemctl restart isirunall.service
  sudo journalctl -u isirunall.service -n 100 --no-pager
SUMMARY
}

print_uninstall_summary() {
  cat <<SUMMARY

ISI simulator uninstalled
-------------------------
Removed:
  - isirunall.service
  - ${ISI_RUNNER}
  - ${ISI_PAYLOAD_1}, ${ISI_PAYLOAD_2}, ${ISI_PAYLOAD_3}
  - runtime namespaces ns1/ns2/ns3
  - runtime veth links
  - ${ISI_DHCP_RUNTIME_DIR}
  - stale old ISI NetworkManager/dhcpcd overrides, if present

Not removed:
  - dependency packages
  - cached .deb files under ${INITBOX_PACKAGE_CACHE_DIR}
SUMMARY
}

install_main() {
  require_root
  ensure_log_dir
  install_dependencies
  remove_old_isi_network_dropins
  write_isi_runner
  write_isi_payloads
  write_isi_service
  enable_but_do_not_start_isi_service
  print_install_summary
  ok "ISI simulator module installed. Service is enabled but not started."
}

uninstall_main() {
  require_root
  ensure_log_dir
  stop_and_disable_unit "isirunall.service"
  cleanup_runtime_network_state
  remove_old_isi_network_dropins
  remove_isi_files
  systemctl daemon-reload
  systemctl reset-failed 2>/dev/null || true
  print_uninstall_summary
  ok "ISI simulator module uninstalled."
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

#!/usr/bin/env bash
# InitBox Pi Zero W / Zero 2W Web Terminal and captive portal module
#
# Actions:
#   install    Install and enable ttyd plus captive portal socket responder.
#   uninstall  Remove services and files created by this module.
#   remove     Alias for uninstall.
#   purge      Compatibility alias for uninstall. It does not remove packages,
#              cached .deb files, or the cached ttyd binary.
#
# Installs and enables:
#   - ttyd Web Terminal on port 7681
#   - systemd socket-activated captive HTTP responder on port 80
#
# User-facing URLs:
#   http://initbox.wlan/
#   http://initbox.wlan:7681/
#   http://192.168.20.1/
#   http://192.168.20.1:7681/
#
# Policy:
#   - This module does not edit hotspot DHCP/DNS/hostapd config.
#   - Hotspot module owns /etc/dnsmasq.conf and /etc/hostapd/hostapd.conf.
#   - This module owns only its systemd service files and responder script.
#   - No Python captive portal.
#   - No iptables redirect service.
#   - No dnsmasq drop-ins.
#   - No systemd drop-ins.

set -euo pipefail

ACTION="${1:-install}"

: "${OWNER:=initbox}"
: "${PORTAL_HOSTNAME:=initbox.wlan}"
: "${TERMINAL_PORT:=7681}"
: "${CAPTIVE_PORTAL_PORT:=80}"
: "${HOTSPOT_INTERFACE:=wlan0}"
: "${TTYD_VERSION:=1.7.7}"
: "${LOGFILE:=/home/${OWNER}/pi_logs/initbox-install.log}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${INITBOX_REPO_ROOT:-$(cd "$SCRIPT_DIR/../.." && pwd)}"

INITBOX_PACKAGES_FILE="${INITBOX_PACKAGES_FILE:-$REPO_ROOT/scripts/packages.txt}"
INITBOX_PACKAGE_CACHE_DIR="${INITBOX_PACKAGE_CACHE_DIR:-/opt/initbox/packages}"
PACKAGES_LIB_FILE="$REPO_ROOT/scripts/lib/packages.sh"

TTYD_INSTALL_PATH="/usr/local/bin/ttyd"
TTYD_CACHE_DIR="$INITBOX_PACKAGE_CACHE_DIR/ttyd"
TTYD_SERVICE_FILE="/etc/systemd/system/ttyd.service"

CAPTIVE_RESPONDER="/usr/local/sbin/initbox-captive-responder.sh"
CAPTIVE_SOCKET_FILE="/etc/systemd/system/initbox-captive-http.socket"
CAPTIVE_SERVICE_FILE="/etc/systemd/system/initbox-captive-http@.service"

OLD_PORTAL_SCRIPT="/usr/local/bin/initbox-ttyd-portal.sh"
OLD_PORTAL_SERVICE_FILE="/etc/systemd/system/initbox-ttyd-portal.service"
OLD_CAPTIVE_SCRIPT="/usr/local/sbin/initbox-captive-portal.py"
OLD_CAPTIVE_SERVICE_FILE="/etc/systemd/system/initbox-captive-portal.service"

ts() {
  date '+%Y-%m-%d %H:%M:%S'
}

log() {
  echo "[TTYD $(ts)] $*" | tee -a "$LOGFILE"
}

ok() {
  echo "[TTYD $(ts)] [OK] $*" | tee -a "$LOGFILE"
}

warn() {
  echo "[TTYD $(ts)] [WARN] $*" | tee -a "$LOGFILE" >&2
}

err() {
  echo "[TTYD $(ts)] [ERR] $*" | tee -a "$LOGFILE" >&2
}

fail() {
  err "$*"
  exit 1
}

require_root() {
  if [ "$(id -u)" -ne 0 ]; then
    fail "this module must be run as root"
  fi
}

require_user() {
  if ! id "$OWNER" >/dev/null 2>&1; then
    fail "user '$OWNER' does not exist"
  fi
}

ensure_log_dir() {
  install -d -m 0755 "$(dirname "$LOGFILE")"
  touch "$LOGFILE"
  chown "$OWNER:$OWNER" "$LOGFILE" 2>/dev/null || true
}

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

load_package_helper() {
  if [ ! -f "$PACKAGES_LIB_FILE" ]; then
    fail "package helper missing: $PACKAGES_LIB_FILE"
  fi

  # shellcheck disable=SC1090
  . "$PACKAGES_LIB_FILE"

  if ! declare -F initbox_packages_install >/dev/null 2>&1; then
    fail "package helper does not define initbox_packages_install"
  fi
}

install_base_packages_from_cache() {
  log "Installing required Debian packages from InitBox package cache"
  log "packages file: $INITBOX_PACKAGES_FILE"
  log "cache dir:     $INITBOX_PACKAGE_CACHE_DIR"

  load_package_helper

  initbox_packages_install \
    "$INITBOX_PACKAGES_FILE" \
    "$INITBOX_PACKAGE_CACHE_DIR" \
    curl \
    ca-certificates
}

detect_ttyd_asset() {
  local machine=""

  machine="$(uname -m)"

  case "$machine" in
    aarch64|arm64)
      printf '%s\n' "ttyd.aarch64"
      ;;
    armv7l|armv6l)
      printf '%s\n' "ttyd.armhf"
      ;;
    arm*)
      printf '%s\n' "ttyd.arm"
      ;;
    x86_64|amd64)
      printf '%s\n' "ttyd.x86_64"
      ;;
    i386|i686)
      printf '%s\n' "ttyd.i686"
      ;;
    *)
      fail "unsupported CPU architecture for ttyd binary: $machine"
      ;;
  esac
}

get_cached_ttyd_path() {
  local ttyd_asset="$1"

  printf '%s\n' "$TTYD_CACHE_DIR/${TTYD_VERSION}-${ttyd_asset}"
}

download_ttyd_to_cache() {
  local ttyd_asset="$1"
  local cached_ttyd="$2"
  local ttyd_url=""
  local tmp_file=""

  if ! command_exists curl; then
    fail "curl is not installed. Prepare package cache first, then rerun this module."
  fi

  ttyd_url="https://github.com/tsl0922/ttyd/releases/download/${TTYD_VERSION}/${ttyd_asset}"
  tmp_file="${cached_ttyd}.tmp"

  install -d -m 0755 "$TTYD_CACHE_DIR"

  log "Cached ttyd binary not found; downloading once and keeping it."
  log "ttyd version: ${TTYD_VERSION}"
  log "ttyd asset:   ${ttyd_asset}"
  log "cache path:   ${cached_ttyd}"

  if ! curl -fL --retry 5 --retry-delay 3 "$ttyd_url" -o "$tmp_file"; then
    rm -f "$tmp_file"
    fail "failed to download ttyd binary. Run this module once in lab with Internet, or place the cached ttyd binary at: $cached_ttyd"
  fi

  chmod 0755 "$tmp_file"
  mv -f "$tmp_file" "$cached_ttyd"
}

install_ttyd_from_cache() {
  local ttyd_asset=""
  local cached_ttyd=""

  ttyd_asset="$(detect_ttyd_asset)"
  cached_ttyd="$(get_cached_ttyd_path "$ttyd_asset")"

  if [ ! -f "$cached_ttyd" ]; then
    download_ttyd_to_cache "$ttyd_asset" "$cached_ttyd"
  else
    log "Using cached ttyd binary: $cached_ttyd"
  fi

  if [ ! -x "$cached_ttyd" ]; then
    chmod 0755 "$cached_ttyd"
  fi

  install -m 0755 "$cached_ttyd" "$TTYD_INSTALL_PATH"

  if ! "$TTYD_INSTALL_PATH" --version >/dev/null 2>&1; then
    fail "installed ttyd binary did not run successfully: $TTYD_INSTALL_PATH"
  fi

  log "Installed ttyd at $TTYD_INSTALL_PATH"
}

install_packages() {
  install_base_packages_from_cache

  if command_exists ttyd; then
    log "ttyd already installed at $(command -v ttyd)"
    return 0
  fi

  if [ -x "$TTYD_INSTALL_PATH" ]; then
    log "ttyd already installed at $TTYD_INSTALL_PATH"
    return 0
  fi

  install_ttyd_from_cache
}

get_required_command_path() {
  local command_name="$1"
  local command_path=""

  command_path="$(command -v "$command_name" || true)"

  if [ -z "$command_path" ]; then
    fail "$command_name is not installed or not in PATH"
  fi

  if [ ! -x "$command_path" ]; then
    fail "$command_path exists but is not executable"
  fi

  printf '%s\n' "$command_path"
}

get_hotspot_ip() {
  local hotspot_ip=""

  hotspot_ip="$(
    ip -4 addr show "$HOTSPOT_INTERFACE" 2>/dev/null |
      awk '/inet / {print $2}' |
      cut -d/ -f1 |
      head -n 1
  )"

  if [ -z "$hotspot_ip" ]; then
    fail "could not detect IPv4 address on $HOTSPOT_INTERFACE. Run the hotspot module first."
  fi

  printf '%s\n' "$hotspot_ip"
}

check_hotspot_dns_owner() {
  local hotspot_ip="$1"

  if [ ! -f /etc/dnsmasq.conf ]; then
    fail "/etc/dnsmasq.conf does not exist. Run the hotspot module first."
  fi

  if ! grep -q "^address=/#/${hotspot_ip}$" /etc/dnsmasq.conf; then
    warn "wildcard captive DNS was not found in /etc/dnsmasq.conf"
    warn "expected: address=/#/${hotspot_ip}"
    warn "captive portal detection may not trigger"
  fi

  if ! grep -q "^dhcp-option=6,${hotspot_ip}$" /etc/dnsmasq.conf; then
    warn "DHCP DNS option was not found in /etc/dnsmasq.conf"
    warn "expected: dhcp-option=6,${hotspot_ip}"
  fi
}

remove_old_web_terminal_dns_fragments() {
  log "Removing old Web Terminal dnsmasq fragments, if present"

  rm -f /etc/dnsmasq.d/initbox-wlan.conf
  rm -f /etc/dnsmasq.d/initbox-captive-portal.conf
  rm -f /etc/dnsmasq.d/initbox-hotspot.conf
}

remove_old_portal_services() {
  log "Removing old captive portal services and scripts, if present"

  systemctl disable --now initbox-captive-portal.service 2>/dev/null || true
  systemctl disable --now initbox-ttyd-portal.service 2>/dev/null || true

  rm -f "$OLD_CAPTIVE_SERVICE_FILE"
  rm -f "$OLD_CAPTIVE_SCRIPT"
  rm -f "$OLD_PORTAL_SERVICE_FILE"
  rm -f "$OLD_PORTAL_SCRIPT"
}

remove_old_portal_redirect_rule() {
  log "Removing old wlan0 port 80 to 7681 redirect rule, if present"

  if ! command_exists iptables; then
    return 0
  fi

  while iptables -t nat -C PREROUTING -i "$HOTSPOT_INTERFACE" -p tcp --dport 80 \
    -j REDIRECT --to-ports "$TERMINAL_PORT" 2>/dev/null; do
    iptables -t nat -D PREROUTING -i "$HOTSPOT_INTERFACE" -p tcp --dport 80 \
      -j REDIRECT --to-ports "$TERMINAL_PORT"
  done

  while iptables -t nat -C PREROUTING -i "$HOTSPOT_INTERFACE" -p tcp --dport 80 \
    -j REDIRECT --to-ports 7681 2>/dev/null; do
    iptables -t nat -D PREROUTING -i "$HOTSPOT_INTERFACE" -p tcp --dport 80 \
      -j REDIRECT --to-ports 7681
  done
}

reset_captive_failed_units() {
  log "Resetting old captive HTTP failed instances, if present"

  systemctl reset-failed 'initbox-captive-http@*.service' 2>/dev/null || true
  systemctl reset-failed 2>/dev/null || true
}

write_ttyd_service() {
  local ttyd_bin="$1"

  log "Writing ttyd systemd service using $ttyd_bin on port $TERMINAL_PORT"

  cat >"$TTYD_SERVICE_FILE" <<EOF
[Unit]
Description=InitBox Web Terminal
After=network.target
Wants=network.target

[Service]
Type=simple
User=$OWNER
Group=$OWNER
WorkingDirectory=/home/$OWNER
Environment=HOME=/home/$OWNER
Environment=USER=$OWNER
ExecStart=$ttyd_bin -W --interface 0.0.0.0 --port $TERMINAL_PORT /bin/bash -l
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF
}

write_captive_responder_script() {
  log "Writing same-host captive HTTP responder"

  cat >"$CAPTIVE_RESPONDER" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail

TERMINAL_PORT="${INITBOX_TERMINAL_PORT:-7681}"
DEFAULT_HOST="${INITBOX_DEFAULT_HOST:-initbox.wlan}"
REQUEST_LINE=""
HEADER_LINE=""
HOST_HEADER=""
REDIRECT_HOST=""
LOCATION=""
BODY="InitBox captive portal redirect"

trap 'exit 0' PIPE

trim_spaces() {
  local value="$1"

  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"

  printf '%s\n' "$value"
}

send_response() {
  printf 'HTTP/1.1 302 Found\r\n'
  printf 'Location: %s\r\n' "$LOCATION"
  printf 'Content-Type: text/plain; charset=utf-8\r\n'
  printf 'Content-Length: %s\r\n' "${#BODY}"
  printf 'Cache-Control: no-store, no-cache, must-revalidate, max-age=0\r\n'
  printf 'Pragma: no-cache\r\n'
  printf 'Connection: close\r\n'
  printf '\r\n'
  printf '%s\n' "$BODY"
}

read -r REQUEST_LINE || true
REQUEST_LINE="${REQUEST_LINE%$'\r'}"

while IFS= read -r HEADER_LINE; do
  HEADER_LINE="${HEADER_LINE%$'\r'}"

  if [ -z "$HEADER_LINE" ]; then
    break
  fi

  case "$HEADER_LINE" in
    [Hh][Oo][Ss][Tt]:*)
      HOST_HEADER="${HEADER_LINE#*:}"
      ;;
  esac
done

HOST_HEADER="$(trim_spaces "$HOST_HEADER")"

if [ -n "$HOST_HEADER" ]; then
  REDIRECT_HOST="${HOST_HEADER%%:*}"
else
  REDIRECT_HOST="$DEFAULT_HOST"
fi

if [ -z "$REDIRECT_HOST" ]; then
  REDIRECT_HOST="$DEFAULT_HOST"
fi

LOCATION="http://${REDIRECT_HOST}:${TERMINAL_PORT}/"

send_response || true
exit 0
EOF

  chmod 0755 "$CAPTIVE_RESPONDER"
  chown root:root "$CAPTIVE_RESPONDER" 2>/dev/null || true
}

write_captive_socket_units() {
  log "Writing captive portal socket unit on port $CAPTIVE_PORTAL_PORT"

  cat >"$CAPTIVE_SOCKET_FILE" <<EOF
[Unit]
Description=InitBox captive portal HTTP socket

[Socket]
ListenStream=0.0.0.0:$CAPTIVE_PORTAL_PORT
Accept=yes
NoDelay=true

[Install]
WantedBy=sockets.target
EOF

  log "Writing captive portal per-connection service"

  cat >"$CAPTIVE_SERVICE_FILE" <<EOF
[Unit]
Description=InitBox captive portal HTTP responder

[Service]
Type=simple
User=$OWNER
Group=$OWNER
Environment=INITBOX_TERMINAL_PORT=$TERMINAL_PORT
Environment=INITBOX_DEFAULT_HOST=$PORTAL_HOSTNAME
ExecStart=-$CAPTIVE_RESPONDER
StandardInput=socket
StandardOutput=socket
StandardError=journal
SuccessExitStatus=0 1 141 SIGPIPE
EOF
}

restart_services() {
  log "Reloading systemd"
  systemctl daemon-reload

  if systemctl list-unit-files dnsmasq.service >/dev/null 2>&1; then
    log "Testing dnsmasq configuration"
    dnsmasq --test

    log "Restarting dnsmasq after removing old fragments"
    systemctl restart dnsmasq.service
  else
    fail "dnsmasq service not found. Run the hotspot module first."
  fi

  log "Enabling ttyd"
  systemctl enable --now ttyd.service
  systemctl restart ttyd.service

  log "Enabling captive HTTP socket"
  systemctl enable --now initbox-captive-http.socket
  systemctl restart initbox-captive-http.socket

  reset_captive_failed_units
}

stop_and_disable_unit() {
  local unit_name="$1"

  log "Stopping and disabling $unit_name, if present"
  systemctl disable --now "$unit_name" 2>/dev/null || true
  systemctl reset-failed "$unit_name" 2>/dev/null || true
}

remove_module_services() {
  log "Removing Web Terminal and captive portal services"

  stop_and_disable_unit "initbox-captive-http.socket"
  stop_and_disable_unit "ttyd.service"
  stop_and_disable_unit "initbox-captive-portal.service"
  stop_and_disable_unit "initbox-ttyd-portal.service"

  systemctl stop 'initbox-captive-http@*.service' 2>/dev/null || true
  systemctl reset-failed 'initbox-captive-http@*.service' 2>/dev/null || true

  rm -f "$CAPTIVE_SOCKET_FILE"
  rm -f "$CAPTIVE_SERVICE_FILE"
  rm -f "$CAPTIVE_RESPONDER"
  rm -f "$TTYD_SERVICE_FILE"

  rm -f "$OLD_CAPTIVE_SERVICE_FILE"
  rm -f "$OLD_CAPTIVE_SCRIPT"
  rm -f "$OLD_PORTAL_SERVICE_FILE"
  rm -f "$OLD_PORTAL_SCRIPT"

  remove_old_web_terminal_dns_fragments
  remove_old_portal_redirect_rule

  systemctl daemon-reload
  systemctl reset-failed 2>/dev/null || true
}

print_install_summary() {
  local hotspot_ip="$1"
  local ttyd_asset=""
  local cached_ttyd=""

  ttyd_asset="$(detect_ttyd_asset)"
  cached_ttyd="$(get_cached_ttyd_path "$ttyd_asset")"

  echo
  echo "Web Terminal and captive portal installed"
  echo "----------------------------------------"
  echo "Captive portal URL: http://$PORTAL_HOSTNAME/"
  echo "Web Terminal URL:   http://$PORTAL_HOSTNAME:$TERMINAL_PORT/"
  echo "Hotspot IP URL:     http://$hotspot_ip/"
  echo "Hotspot terminal:   http://$hotspot_ip:$TERMINAL_PORT/"
  echo "Hotspot IP:         $hotspot_ip"
  echo "ttyd binary:        $TTYD_INSTALL_PATH"
  echo "ttyd cache:         $cached_ttyd"
  echo
  echo "Expected behavior:"
  echo "  - port 80 is handled by systemd socket activation"
  echo "  - port 80 replies with HTTP 302 to the same host on port $TERMINAL_PORT"
  echo "  - closed or impatient captive-check clients do not pollute systemctl --failed"
  echo "  - http://$hotspot_ip/ redirects to http://$hotspot_ip:$TERMINAL_PORT/"
  echo "  - http://$PORTAL_HOSTNAME/ redirects to http://$PORTAL_HOSTNAME:$TERMINAL_PORT/"
  echo "  - ttyd runs on port $TERMINAL_PORT"
  echo "  - ttyd login user: $OWNER"
  echo "  - ttyd keyboard input is enabled by -W"
  echo "  - no Python captive portal"
  echo "  - no extra web server package"
  echo "  - no iptables redirect service"
  echo "  - no dnsmasq drop-ins"
  echo "  - no systemd drop-ins"
  echo
  echo "Offline field-mode behavior:"
  echo "  - Debian packages are installed from $INITBOX_PACKAGE_CACHE_DIR"
  echo "  - ttyd is cached and reused from $TTYD_CACHE_DIR"
  echo "  - uninstall does not remove shared packages or cached files"
  echo
  echo "DNS ownership:"
  echo "  - Hotspot module owns /etc/dnsmasq.conf"
  echo "  - Expected wildcard rule: address=/#/$hotspot_ip"
  echo
  echo "Check services:"
  echo "  sudo systemctl status hostapd dnsmasq ttyd initbox-captive-http.socket --no-pager"
  echo
  echo "Check ports:"
  echo "  sudo ss -tulpn | grep -E ':80|:$TERMINAL_PORT'"
  echo
  echo "Manual tests:"
  echo "  curl -I http://127.0.0.1/"
  echo "  curl -I -H 'Host: $hotspot_ip' http://127.0.0.1/"
  echo "  curl -I -H 'Host: $PORTAL_HOSTNAME' http://127.0.0.1/"
  echo "  curl -I http://127.0.0.1:$TERMINAL_PORT/"
}

print_uninstall_summary() {
  echo
  echo "Web Terminal and captive portal uninstalled"
  echo "------------------------------------------"
  echo "Removed:"
  echo "  - ttyd.service"
  echo "  - initbox-captive-http.socket"
  echo "  - initbox-captive-http@.service"
  echo "  - $CAPTIVE_RESPONDER"
  echo "  - old Python captive portal service/script, if present"
  echo "  - old ttyd portal service/script, if present"
  echo "  - old iptables redirect rule, if present"
  echo
  echo "Not removed:"
  echo "  - hotspot service"
  echo "  - dnsmasq hotspot configuration"
  echo "  - hostapd hotspot configuration"
  echo "  - ttyd binary at $TTYD_INSTALL_PATH"
  echo "  - cached ttyd files under $TTYD_CACHE_DIR"
  echo "  - cached Debian packages under $INITBOX_PACKAGE_CACHE_DIR"
  echo
  echo "Check:"
  echo "  sudo systemctl status ttyd initbox-captive-http.socket --no-pager"
  echo "  sudo ss -tulpn | grep -E ':80|:$TERMINAL_PORT'"
}

install_main() {
  local hotspot_ip=""
  local ttyd_bin=""

  require_root
  ensure_log_dir
  require_user
  install_packages

  ttyd_bin="$(get_required_command_path ttyd)"
  hotspot_ip="$(get_hotspot_ip)"

  check_hotspot_dns_owner "$hotspot_ip"
  remove_old_web_terminal_dns_fragments
  remove_old_portal_services
  remove_old_portal_redirect_rule
  reset_captive_failed_units
  write_ttyd_service "$ttyd_bin"
  write_captive_responder_script
  write_captive_socket_units
  restart_services
  print_install_summary "$hotspot_ip"

  ok "Web Terminal and captive portal module installed."
}

uninstall_main() {
  require_root
  ensure_log_dir

  remove_module_services
  print_uninstall_summary

  ok "Web Terminal and captive portal module uninstalled."
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
      fail "unknown action '$ACTION'. Use install or uninstall."
      ;;
  esac
}

main "$@"

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
