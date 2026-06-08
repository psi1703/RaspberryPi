#!/usr/bin/env bash
set -euo pipefail

: "${OWNER:=initbox}"
: "${LOGFILE=/home/${OWNER}/pi_logs/initbox-install.log}"

ts(){ date +"%Y-%m-%d %H:%M:%S"; }
log(){  echo "[FMS  $(ts)] $*" | tee -a "$LOGFILE"; }
ok(){   echo "[FMS  $(ts)] [OK] $*" | tee -a "$LOGFILE"; }
warn(){ echo "[FMS  $(ts)] [WARN] $*" | tee -a "$LOGFILE" >&2; }
err(){  echo "[FMS  $(ts)] [ERR] $*" | tee -a "$LOGFILE" >&2; }

apt_safe(){ apt-get -o Dpkg::Use-Pty=0 -o Acquire::Retries=5 "$@" 2>&1 | tee -a "$LOGFILE"; }

# ---------- 1) APT deps ----------
log "Installing FMS dependencies …"
apt_safe update -y
apt_safe install -y can-utils ifupdown

# ---------- 2) Patch boot config for MCP2515 (8MHz, INT=25) ----------
patch_mcp2515_overlay() {
  local cfg

  if [[ -f /boot/firmware/config.txt ]]; then
    cfg=/boot/firmware/config.txt
  elif [[ -f /boot/config.txt ]]; then
    cfg=/boot/config.txt
  else
    warn "No /boot/firmware/config.txt or /boot/config.txt found; cannot configure MCP2515 overlay."
    return 0
  fi

  log "Patching MCP2515 overlay in ${cfg} …"

  local overlay_line='dtoverlay=mcp2515-can0,oscillator=8000000,interrupt=25'

   if grep -q '^#dtparam=spi=on' "$cfg"; then
    if grep -q "^${overlay_line}\$" "$cfg"; then
      # Overlay already somewhere; just uncomment spi
      sed -i 's/^#dtparam=spi=on/dtparam=spi=on/' "$cfg"
      log "Uncommented dtparam=spi=on; overlay already present elsewhere."
    else
      # Replace the single commented line with dtparam + overlay, no extra blank lines
      sed -i "s|^#dtparam=spi=on\$|dtparam=spi=on\n${overlay_line}|" "$cfg"
      log "Uncommented dtparam=spi=on and inserted MCP2515 overlay directly below."
    fi
  else
    # Fallback if file is in some other state: just ensure both exist somewhere
    if ! grep -q '^dtparam=spi=on' "$cfg"; then
      echo 'dtparam=spi=on' >> "$cfg"
      log "Appended dtparam=spi=on at end of ${cfg} (fallback mode)."
    fi
    if ! grep -q "^${overlay_line}\$" "$cfg"; then
      echo "$overlay_line" >> "$cfg"
      log "Appended MCP2515 overlay at end of ${cfg} (fallback mode)."
    fi
  fi

  log "NOTE: Changes to ${cfg} require a REBOOT before can0 will appear."
}

patch_mcp2515_overlay

# ---------- 3) Bring can0 up ----------
log "Writing /etc/network/interfaces …"
cat >/etc/network/interfaces <<'EOF'
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

# ---------- 4) fms.py ----------
log "Writing /usr/local/bin/fms.py …"
cat >/usr/local/bin/fms.py <<'EOF'
#!/usr/bin/env python3
import os, sys, time, subprocess

# -------- Config (via environment) --------
TRC_FILE   = os.environ.get("FMS_TRC_FILE", "/usr/local/bin/CAN.trc")
CAN_IFACE  = os.environ.get("FMS_CAN_IFACE", "can0")
FRAME_SLEEP = float(os.environ.get("FMS_FRAME_SLEEP", "0.1"))
LOOP_SLEEP  = float(os.environ.get("FMS_LOOP_SLEEP", "0.5"))

def log(msg: str) -> None:
    sys.stderr.write(msg + "\n")
    sys.stderr.flush()

def is_hex_string(s: str) -> bool:
    if not s:
        return False
    try:
        int(s, 16)
        return True
    except ValueError:
        return False

def send_fms_message(can_id: str, data: str) -> None:
    can_id = can_id.strip()
    data   = data.strip()

    if not can_id or not data:
        return

    # Validate – avoid triggering cansend usage
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
                # Skip header / comment lines
                if line.lstrip().startswith(";") or line.lstrip().startswith("---"):
                    continue

                parts = line.split()
                # Expect: idx, time, type, id, dlc, d0 .. dN
                if len(parts) < 6:
                    continue

                # Extract fields
                msg_num = parts[0]          # "1)"
                time_off = parts[1]         # "376182.3"
                msg_type = parts[2]         # "Rx" / "Tx"
                can_id   = parts[3]         # "0CFE6CEE"
                dlc_str  = parts[4]         # "8"

                try:
                    dlc = int(dlc_str)
                except ValueError:
                    continue

                data_bytes = parts[5:5+dlc]
                if len(data_bytes) != dlc:
                    # Malformed line; skip
                    continue

                data_hex = "".join(b for b in data_bytes)
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

chmod 755 /usr/local/bin/fms.py
chown "$OWNER:$OWNER" /usr/local/bin/fms.py || true

# ---------- 5) fms.service ----------
log "Installing /etc/systemd/system/fms.service …"
cat >/etc/systemd/system/fms.service <<'EOF'
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

systemctl daemon-reload
systemctl enable fms.service
systemctl restart fms.service || true

log "FMS module installed."
log "If MCP2515 overlay was just added to config.txt, REBOOT once so can0 exists at boot."
log "After reboot, fms.service will bring can0 up (if needed) and start replay automatically."
