#!/usr/bin/env bash
set -euo pipefail

: "${OWNER:=initbox}"

LOG_DIR="/home/${OWNER}/pi_logs"
mkdir -p "$LOG_DIR"
: "${LOGFILE:=${LOG_DIR}/initbox-install.log}"

ts(){ date +"%Y-%m-%d %H:%M:%S"; }
log(){  echo "[WS-BR0 $(ts)] $*"       | tee -a "$LOGFILE"; }
ok(){   echo "[WS-BR0 $(ts)] [OK] $*"  | tee -a "$LOGFILE"; }
warn(){ echo "[WS-BR0 $(ts)] [WARN] $*"| tee -a "$LOGFILE" >&2; }
err(){  echo "[WS-BR0 $(ts)] [ERR] $*" | tee -a "$LOGFILE" >&2; }

apt_safe(){
  apt-get -o Dpkg::Use-Pty=0 -o Acquire::Retries=5 "$@" >>"$LOGFILE" 2>&1
}

log "Wireshark module needs tshark (CLI capture engine). Installing it automatically"

log "Updating APT and Installing tshark +zip …"
    apt_safe update -y

    SAVED="${DEBIAN_FRONTEND:-}"
    export DEBIAN_FRONTEND=dialog

    echo "[INFO $(ts)] Installing tshark (debconf may prompt once) …" | tee -a "$LOGFILE"
    if ! apt-get install -y tshark 2>&1 | tee -a "$LOGFILE"; then
      export DEBIAN_FRONTEND="$SAVED"
      err "tshark install failed, aborting Wireshark module."
      exit 1
    fi

    export DEBIAN_FRONTEND="$SAVED"

    log "Ensuring zip is installed for log-prep …"
    apt_safe install -y zip

log "Ensuring wireshark group and membership …"
getent group wireshark >/dev/null 2>&1 || groupadd -r wireshark || true
usermod -aG wireshark "$OWNER" || true

log "Setting dumpcap capabilities for non-root capture …"
DUMPCAP_BIN="$(command -v dumpcap || true)"
if [[ -n "$DUMPCAP_BIN" ]]; then
  setcap 'CAP_NET_RAW,CAP_NET_ADMIN=+eip' "$DUMPCAP_BIN" || \
    log "Warning: setcap on dumpcap failed (capture may need root)."
else
  log "Warning: dumpcap not found; tshark capture permissions may be limited."
fi

log "Ensuring /usr/tracefiles exists and is writable to initbox:wireshark …"
install -d -m 0770 -o "$OWNER" -g wireshark /usr/tracefiles

log "Writing /usr/local/bin/wireshark.sh …"
cat >/usr/local/bin/wireshark.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
umask 077

TRACE_DIR="${TRACE_DIR:-/usr/tracefiles}"
BOXNO_FILE="${BOXNO_FILE:-/etc/pi-boxno}"
IFACE_FILE="${IFACE_FILE:-/etc/pi-capture.iface}"
DEFAULT_IFACE="${DEFAULT_IFACE:-br0}"
TSHARK_BIN="${TSHARK_BIN:-/usr/bin/tshark}"

mkdir -p "$TRACE_DIR"

BOXNO="$(cat "$BOXNO_FILE" 2>/dev/null || echo 1)"
OUT="${TRACE_DIR}/initbox_${BOXNO}.pcap"

IFACE="$(cat "$IFACE_FILE" 2>/dev/null || echo "$DEFAULT_IFACE")"

# wait up to ~20s for the interface to appear (bridge-check / br0)
for _ in {1..20}; do
  if ip link show "$IFACE" >/dev/null 2>&1; then
    break
  fi
  sleep 1
done

if ! ip link show "$IFACE" >/dev/null 2>&1; then
  echo "[WS] $IFACE not present"
  exit 0
fi

exec "$TSHARK_BIN" -Q -i "$IFACE" -f ip \
  -b files:80 -b filesize:50000 \
  -w "$OUT"
EOF

chmod 755 /usr/local/bin/wireshark.sh
chown "$OWNER:wireshark" /usr/local/bin/wireshark.sh || true

log "Installing /etc/systemd/system/wireshark-autostart.service …"
cat >/etc/systemd/system/wireshark-autostart.service <<EOF
[Unit]
Description=Wireshark auto capture on br0 (ring buffer)
After=network-online.target bridge-check.service
Wants=network-online.target

[Service]
Type=simple
User=${OWNER}
Group=wireshark
ExecStart=/usr/local/bin/wireshark.sh
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

log "Wireshark service will start after bridge installation"
log "Wireshark module installed. Captures go to /usr/tracefiles."

log "Writing /usr/local/bin/log-prep.sh …"
cat >/usr/local/bin/log-prep.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

TRACE_DIR="${TRACE_DIR:-/usr/tracefiles}"
BOXNO_FILE="${BOXNO_FILE:-/etc/pi-boxno}"
ROLE_FILE="${ROLE_FILE:-/etc/pi_roles.conf}"
SVC_SNIFF="${SVC_SNIFF:-wireshark-autostart.service}"

BOXNO="$(cat "$BOXNO_FILE" 2>/dev/null || echo 1)"
ARCHIVE="${ARCHIVE:-initbox_${BOXNO}_$(date +%Y%m%d).zip}"

# Who should own the resulting ZIP?
OWNER_USER="${SUDO_USER:-$(logname 2>/dev/null || echo initbox)}"
OWNER_GROUP="$OWNER_USER"

log(){ echo "[log-prep] $*"; }

# --- same style role reader as pi-servsync.sh ---
read_roles() {
  local R=""

  if [[ -r "$ROLE_FILE" ]]; then
    # shellcheck disable=SC1090
    . "$ROLE_FILE" || true
    # Accept ROLES or roles, normalize to lower-case, strip CR + spaces
    R="${ROLES:-${roles:-}}"
    R="${R,,}"                # lower
    R="${R//$'\r'/}"          # strip CR
  fi

  printf '%s' "$R"
}

roles="$(read_roles)"

want_sniff=0
if [[ -n "$roles" ]]; then
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

# Remember whether sniffer was active before we stop it
was_active=0
if systemctl is-active --quiet "$SVC_SNIFF"; then
  was_active=1
  log "$SVC_SNIFF active before prep (will be stopped)"
else
  log "$SVC_SNIFF inactive before prep"
fi

systemctl stop "$SVC_SNIFF" 2>/dev/null || true

shopt -s nullglob
files=("$TRACE_DIR"/*.pcap "$TRACE_DIR"/*.pcapng "$TRACE_DIR"/*.pcap.gz "$TRACE_DIR"/*.pcapng.gz)
files=("${files[@]}")

if (( ${#files[@]} == 0 )); then
  echo "[log-prep] No capture files found in ${TRACE_DIR}."
else
  echo "[log-prep] Compressing ${#files[@]} file(s) into ${TRACE_DIR}/${ARCHIVE} ..."
  zip -j -q "${TRACE_DIR}/${ARCHIVE}" "${files[@]}"
  chown "$OWNER_USER":"$OWNER_GROUP" "${TRACE_DIR}/${ARCHIVE}" 2>/dev/null || true
  echo "[log-prep] Deleting original capture files ..."
  rm -f -- "${files[@]}"
fi

chown "$OWNER_USER":"$OWNER_GROUP" "$TRACE_DIR" 2>/dev/null || true
echo "[log-prep] Files are stored at: ${TRACE_DIR}"

# Only restart sniffer if it was running AND role still includes a sniffing role
if (( want_sniff )); then
  log "Restarting $SVC_SNIFF (want_sniff=1)"
  systemctl start "$SVC_SNIFF" 2>/dev/null || true
else
  log "Not restarting $SVC_SNIFF (want_sniff=${want_sniff})"
fi

echo "[log-prep] ... preparation completed."
EOF

chmod 755 /usr/local/bin/log-prep.sh
chown "$OWNER:$OWNER" /usr/local/bin/log-prep.sh || true

ok "Wireshark + log-prep module installed."

install_bridge_script() {
log "Writing /usr/local/bin/bridge-check.sh …"
cat >/usr/local/bin/bridge-check.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

BR="${BRIDGE:-br0}"

log() { echo "[BRIDGE $(date +%F_%T)] $*"; }

is_pi_zero_like() {
  local m
  m="$(tr -d '\0' </proc/device-tree/model 2>/dev/null || echo '')"
  case "$m" in
    *"Zero"*)  return 0 ;;  # Zero, Zero W, Zero 2 W
    *)         return 1 ;;
  esac
}

get_wired_ifs() {
  find /sys/class/net -maxdepth 1 -mindepth 1 -type l -printf '%f\n' \
    | grep -E '^(eth[0-9]+|enx[0-9A-Fa-f]{12})$' \
    | sort || true
}

ensure_bridge_1nic() {
  local IF="$1"

  if ! ip link show "$BR" &>/dev/null; then
    ip link add name "$BR" type bridge
    log "Created "$BR" (1-NIC ISI mode)."
  fi

  # pure L2: no IP on port or bridge
  ip addr flush dev "$IF"  || true
  ip addr flush dev "$BR"  || true

  ip link set "$IF" master "$BR" 2>/dev/null || true
  ip link set "$IF" up       2>/dev/null || true
  ip link set "$BR"  up      2>/dev/null || true

  log "${BR} up with single port ${IF} (pure L2 for ISI namespaces)."
}

ensure_bridge_2nic() {
  local A="$1" B="$2"

  if ! ip link show "$BR" &>/dev/null; then
    ip link add name "$BR" type bridge
    log "Created ${BR} (2-NIC sniff mode)."
  fi

  # pure L2: no IP on ports or bridge
  ip addr flush dev "$A" || true
  ip addr flush dev "$B" || true
  ip addr flush dev "$BR" || true

  ip link set "$A" master "$BR" 2>/dev/null || true
  ip link set "$B" master "$BR" 2>/dev/null || true

  ip link set "$A" up 2>/dev/null || true
  ip link set "$B" up 2>/dev/null || true
  ip link set "$BR" up 2>/dev/null || true

  log "${BR} up with ports ${A}+${B} (pure L2 for Wireshark + ISI)."
}

teardown_bridge() {
  if ! ip link show "$BR" &>/dev/null; then
    return 0
  fi

  mapfile -t PORTS < <(ip -o link show master "$BR" 2>/dev/null \
                       | awk -F': ' '{print $2}' | cut -d'@' -f1)

  if ((${#PORTS[@]} > 0)); then
    log "Releasing ports from ${BR}: ${PORTS[*]}"
    for IF in "${PORTS[@]}"; do
      ip link set "$IF" nomaster 2>/dev/null || true
      ip link set "$IF" up       2>/dev/null || true
    done
  fi

  ip link set "$BR" down 2>/dev/null || true
  ip link del "$BR" type bridge 2>/dev/null || true
  log "Removed ${BR} (no longer needed)."
}

# On Pi Zero/Zero 2W we let isirunall manage its own local bridge; no dynamic br0.
if is_pi_zero_like; then
  log "Pi Zero/Zero 2W detected; dynamic ${BR} disabled."
  exit 0
fi

while true; do
  mapfile -t WIRED_IFS < <(get_wired_ifs)
  CNT=${#WIRED_IFS[@]}

  ISI_ACTIVE=0
  if systemctl is-active --quiet isirunall.service; then
    ISI_ACTIVE=1
  fi

  # Wireshark only matters in 2-NIC mode; we just log it for visibility.
  WS_ACTIVE=0
  if systemctl is-active --quiet wireshark-autostart.service; then
    WS_ACTIVE=1
  fi

  case "$CNT" in
    0)
      # No wired NICs: no bridge
      teardown_bridge
      ;;
    1)
      # 1 NIC: only create bridge if ISI is actually running.
      if (( ISI_ACTIVE )); then
        ensure_bridge_1nic "${WIRED_IFS[0]}"
      else
        teardown_bridge
        log "1 NIC present, ISI not active -> leaving NIC alone for normal IP/internet."
      fi
      ;;
    *)
      # >=2 NICs: always maintain a pure L2 bridge for sniffing.
      ensure_bridge_2nic "${WIRED_IFS[0]}" "${WIRED_IFS[1]}"
      log "status: CNT=${CNT}, ISI_ACTIVE=${ISI_ACTIVE}, WS_ACTIVE=${WS_ACTIVE}"
      ;;
  esac

  sleep 3
done
EOF

  chmod 755 /usr/local/bin/bridge-check.sh
  chown root:root /usr/local/bin/bridge-check.sh || true
}

install_bridge_service() {
log "Writing bridge-check.service …"
cat >/etc/systemd/system/bridge-check.service <<EOF
[Unit]
Description=Dynamic bridge manager for ISI + Wireshark (br0)
After=network-pre.target
Wants=network-pre.target

[Service]
Type=simple
ExecStart=/usr/local/bin/bridge-check.sh
Restart=on-failure
RestartSec=3
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
}

log "Starting Bridge module …"

install_bridge_script
install_bridge_service

systemctl daemon-reload
systemctl enable bridge-check.service 2>/dev/null || true
systemctl restart bridge-check.service 2>/dev/null || true
systemctl enable wireshark-autostart.service || true
systemctl restart wireshark-autostart.service || true

ok "Wireshark + Bridge + log-prep module installed. Dynamic br0 will now be managed for ISI + Wireshark on Pi 3/4/5."
