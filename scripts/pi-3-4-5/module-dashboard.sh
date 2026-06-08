#!/usr/bin/env bash
set -euo pipefail

: "${OWNER:=initbox}"
: "${SCRIPT_DIR:=$(cd "$(dirname "$0")" && pwd)}"
: "${LOGFILE:=/home/${OWNER}/pi_logs/initbox-install.log}"

ts(){ date +"%Y-%m-%d %H:%M:%S"; }
log(){  echo "[DASH $(ts)] $*" | tee -a "$LOGFILE"; }
ok(){   echo "[DASH   $(ts)] [OK] $*" | tee -a "$LOGFILE"; }
warn(){ echo "[DASH $(ts)] [WARN] $*" | tee -a "$LOGFILE" >&2; }
err(){  echo "[DASH $(ts)] [ERR] $*" | tee -a "$LOGFILE" >&2; }

apt_safe(){ apt-get -o Dpkg::Use-Pty=0 -o Acquire::Retries=5 "$@" 2>&1 | tee -a "$LOGFILE"; }

have_internet() {
  ping -c1 -W1 8.8.8.8 >/dev/null 2>&1 || return 1
}

emit_unit() {
  local path="$1"
  local body="$2"
  printf '%s\n' "$body" >"$path"
}
# ------------ TTYD build + service ------------
install_ttyd() {
if ! build_ttyd_from_git; then
    warn "ttyd build failed or skipped; continuing without web terminal."
    return 0
  fi
  emit_ttyd_service
}

build_ttyd_from_git(){
  if command -v ttyd >/dev/null 2>&1; then
    log "ttyd already installed at $(command -v ttyd)"
    return 0
  fi

  if ! have_internet; then
    warn "No internet, skipping ttyd build (required for web terminal)."
    return 1
  fi

  log "Installing ttyd build dependencies …"
  if ! apt_safe update -y; then
    warn "apt update failed; skipping ttyd build."
    return 1
  fi
  if ! apt_safe install -y build-essential cmake git libjson-c-dev libwebsockets-dev; then
    warn "Failed to install ttyd build dependencies; skipping web terminal."
    return 1
  fi

  log "Building ttyd from git …"

  local tmp
  tmp="$(mktemp -d)" || { warn "mktemp failed, skipping ttyd build."; return 1; }

  log "Cloning and building ttyd from git …"

  if ! git clone https://github.com/tsl0922/ttyd.git "$tmp/ttyd"; then
    warn "git clone for ttyd failed; skipping web terminal."
    rm -rf "$tmp"
    return 1
  fi

  if ! cd "$tmp/ttyd"; then
    warn "Could not cd into ttyd source dir; skipping web terminal."
    rm -rf "$tmp"
    return 1
  fi

  mkdir -p build
  if ! cd build; then
    warn "Could not cd into ttyd build dir; skipping web terminal."
    rm -rf "$tmp"
    return 1
  fi

  if ! cmake ..; then
    warn "cmake for ttyd failed; skipping web terminal."
    rm -rf "$tmp"
    return 1
  fi

  if ! make -j"$(nproc)"; then
    warn "make for ttyd failed; skipping web terminal."
    rm -rf "$tmp"
    return 1
  fi

  if ! make install; then
    warn "make install for ttyd failed; skipping web terminal."
    rm -rf "$tmp"
    return 1
  fi

  cd /
  rm -rf "$tmp"
  ok "ttyd installed at $(command -v ttyd || echo /usr/local/bin/ttyd)"
  return 0
}

emit_ttyd_service(){
  if ! command -v ttyd >/dev/null 2>&1; then
    warn "ttyd binary not found; skipping ttyd.service creation."
    return
  fi

  emit_unit /etc/systemd/system/ttyd.service "[Unit]
Description=ttyd web terminal
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${OWNER}
Group=${OWNER}
ExecStart=$(command -v ttyd) -p 7681 --writable -i 0.0.0.0 bash -l
Restart=on-failure

[Install]
WantedBy=multi-user.target
"
}

# ---------- Node-RED install ----------
install_nodered() {
  log "Installing Node-RED via official installer (interactive) …"

  # Make sure basic tools are present
  apt_safe update -y
  apt_safe install -y curl ca-certificates build-essential || true

  # Official installer for Debian/RPi
  local url="https://github.com/node-red/linux-installers/releases/latest/download/update-nodejs-and-nodered-deb"
  local tmp_script="/tmp/update-nodejs-and-nodered-deb.sh"

  log "Downloading Node-RED installer script to ${tmp_script} …"
  if ! curl -fsSL "$url" -o "$tmp_script"; then
    err "Failed to download Node-RED installer from ${url}"
    return 1
  fi
  chmod +x "$tmp_script"

  if [ -e /dev/tty ]; then
    log "Launching official Node-RED installer (you will see its prompts; choose user: ${OWNER}) …"
    # Run as root, but feed stdin from the real terminal so the menu works
    if ! bash "$tmp_script" </dev/tty; then
      err "Node-RED installer failed; check its output and ${LOGFILE}."
      rm -f "$tmp_script"
      return 1
    fi
  else
    warn "No /dev/tty available; running Node-RED installer non-interactively; may fail."
    if ! bash "$tmp_script"; then
      err "Node-RED installer failed in non-interactive mode; check ${LOGFILE}."
      rm -f "$tmp_script"
      return 1
    fi
  fi

  rm -f "$tmp_script"

  # Sanity check: node-red must now exist
  if ! command -v node-red >/dev/null 2>&1; then
    err "node-red command not found after installer; aborting dashboard module."
    return 1
  fi
  log "Node-RED installed: $(node-red --version 2>&1 | head -n1)"

  # Disable upstream nodered.service; we manage our own pi-nodered.service
  if systemctl list-unit-files | grep -q '^nodered\.service'; then
    log "Disabling upstream nodered.service …"
    systemctl disable --now nodered.service 2>/dev/null || true
  fi

  # Ensure ~/.node-red exists and is owned by OWNER
  install -d -m 0755 -o "${OWNER}" -g "${OWNER}" "/home/${OWNER}/.node-red"

  # As OWNER: ensure .node-red/public exists, copy logo.png, and install node-red-dashboard
  su - "${OWNER}" -s /bin/bash <<'EOS'
set -e

NR_DIR="${HOME}/.node-red"
PUBLIC_DIR="${NR_DIR}/public"

mkdir -p "${PUBLIC_DIR}"

# Copy logo.png from home into public if present
if [ -f "${HOME}/logo.png" ]; then
  cp -f "${HOME}/logo.png" "${PUBLIC_DIR}/logo.png"
fi

cd "${NR_DIR}"

# Make sure we have a basic package.json so npm has metadata
if [ ! -f package.json ]; then
  npm init -y >/dev/null 2>&1 || true
fi

# Ensure node-red-dashboard is installed
if ! npm list node-red-dashboard --depth=0 >/dev/null 2>&1; then
  npm install --unsafe-perm node-red-dashboard
fi
EOS

}

# ---------- Deploy flows/settings ----------
deploy_flows_settings() {
  local NR_DIR="/home/${OWNER}/.node-red"
  local HOST; HOST="$(hostname 2>/dev/null || echo raspberrypi)"

  local FLOWS_SRC=""
  if   [[ -f "${SCRIPT_DIR}/flows_initbox.json" ]]; then
    FLOWS_SRC="${SCRIPT_DIR}/flows_initbox.json"
  elif [[ -f "${SCRIPT_DIR}/flows_dashboard.json" ]]; then
    FLOWS_SRC="${SCRIPT_DIR}/flows_dashboard.json"
  elif [[ -f "${SCRIPT_DIR}/flows.json" ]]; then
    FLOWS_SRC="${SCRIPT_DIR}/flows.json"
  fi

  if [[ -n "$FLOWS_SRC" ]]; then
    log "Deploying Node-RED flows from $(basename "$FLOWS_SRC") …"
    install -m 0644 "$FLOWS_SRC" "${NR_DIR}/flows_initbox.json"
    install -m 0644 "$FLOWS_SRC" "${NR_DIR}/flows_${HOST}.json"
  else
    log "No flows_initbox.json/flows_dashboard.json/flows.json found; leaving default flows."
  fi

  if [[ -f "${SCRIPT_DIR}/settings.js" ]]; then
    log "Deploying Node-RED settings.js …"
    install -m 0644 "${SCRIPT_DIR}/settings.js" "${NR_DIR}/settings.js"
  else
    log "No custom settings.js found; using default Node-RED settings."
  fi

  chown -R "${OWNER}:${OWNER}" "$NR_DIR" || true
}

# ---------- module flag ----------
install_initbox_mods() {
  log "Ensuring /etc/initbox-mods.conf exists …"
  if [[ ! -f /etc/initbox-mods.conf ]]; then
    cat >/etc/initbox-mods.conf <<'EOF'
ISI=0
FMS=0
WSBR0=0
EOF
    chmod 644 /etc/initbox-mods.conf
    log "Created /etc/initbox-mods.conf with default flags."
  else
    log "/etc/initbox-mods.conf already exists; leaving contents unchanged."
  fi
}

# ---------- pi-nodered.service ----------
install_nodered_service() {
  log "Installing pi-nodered.service …"
  cat >/etc/systemd/system/pi-nodered.service <<EOF
[Unit]
Description=Pi Node-RED (dashboard controller)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${OWNER}
Group=${OWNER}
WorkingDirectory=/home/${OWNER}
ExecStart=/usr/bin/env node-red --max-old-space-size=128
Restart=on-failure
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
}

# ---------- Embed pi-rolectl.sh ----------
install_pi_rolectl() {
  log "Writing /usr/local/bin/pi-rolectl.sh …"
  cat >/usr/local/bin/pi-rolectl.sh <<'EOF'
#!/usr/bin/env bash
exec /usr/local/bin/pi-servsync.sh "$@"
EOF

  chmod 755 /usr/local/bin/pi-rolectl.sh
  chown root:root /usr/local/bin/pi-rolectl.sh || true
}

# ---------- Embed pi-servsync.sh ----------
install_pi_servsync() {
  log "Writing /usr/local/bin/pi-servsync.sh …"
  cat >/usr/local/bin/pi-servsync.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

: "${ROLE_FILE=/etc/pi_roles.conf}"
SVC_ISI="isirunall.service"
SVC_FMS="fms.service"
SVC_SNIFF="wireshark-autostart.service"

log() {
  echo "[servsync] $*"
  logger -t pi-servsync -- "$*"
}

# --- robust role reader: source the file, normalize, strip CR/WS ---
read_roles() {
  local R=""

  if [[ -r "$ROLE_FILE" ]]; then
    # shellcheck disable=SC1090
    . "$ROLE_FILE" || true
    # Accept ROLES or roles, normalize to lower-case
    R="${ROLES:-${roles:-}}"
    R="${R,,}"                # lower-case
    R="${R//$'\r'/}"          # strip CR
  fi

  printf '%s' "$R"
}

start_enable() {
  local unit="$1"
  systemctl enable --now "$unit" >/dev/null 2>&1 || true
  # give systemd a moment to settle
  sleep 0.2
  if systemctl is-active --quiet "$unit"; then
    log "started $unit"
  else
    log "failed to start $unit"
  fi
}

stop_disable() {
  local unit="$1"
  systemctl stop "$unit" >/dev/null 2>&1 || true

  systemctl disable "$unit" >/dev/null 2>&1 || true

  log "stopped+disabled $unit"
}

mode="${1:-apply}"
force_stop=0
case "$mode" in
  stop|stopall|--force-stop)
    force_stop=1
    ;;
  *)
    force_stop=0
    ;;
esac

roles="$(read_roles)"

want_isi=0
want_sniff=0
want_fms=0

if (( ! force_stop )); then
  for word in $roles; do
    case "$word" in
      isi)      want_isi=1 ;;
      sniff)    want_sniff=1 ;;
      fms)      want_fms=1 ;;
    esac
  done
fi

log "parsed roles='${roles}' -> isi:${want_isi} sniff:${want_sniff} fms:${want_fms}"

(( want_sniff )) && start_enable "$SVC_SNIFF" || stop_disable "$SVC_SNIFF"
(( want_isi   )) && start_enable "$SVC_ISI"   || stop_disable "$SVC_ISI"
(( want_fms   )) && start_enable "$SVC_FMS"   || stop_disable "$SVC_FMS"

exit 0
EOF

  chmod 755 /usr/local/bin/pi-servsync.sh
  chown "$OWNER:$OWNER" /usr/local/bin/pi-servsync.sh || true
}

# ---------- Embed portal.sh ----------
install_portal() {
  log "Writing /usr/local/bin/portal.sh …"
  cat >/usr/local/bin/portal.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

IFACE="${1:-wlan0}"
DASHBOARD_PORT="${DASHBOARD_PORT:-1880}"

if ! iptables -t nat -C PREROUTING -i "$IFACE" -p tcp --dport 80 \
       -j REDIRECT --to-ports "$DASHBOARD_PORT" 2>/dev/null; then
  iptables -t nat -A PREROUTING -i "$IFACE" -p tcp --dport 80 \
       -j REDIRECT --to-ports "$DASHBOARD_PORT"
fi
EOF

  chmod 755 /usr/local/bin/portal.sh
  chown "$OWNER:$OWNER" /usr/local/bin/portal.sh || true
}

# ---------- Embed pi-stats.sh ----------
install_pi_stats() {
  log "Writing /usr/local/bin/pi-stats.sh …"
  cat >/usr/local/bin/pi-stats.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

# ----- small helper to escape JSON strings -----
escape_json() {
  local s=${1:-}
  s=${s//\\/\\\\}   # backslash
  s=${s//\"/\\\"}   # double quote
  printf '%s' "$s"
}

# ----- Basic hardware info -----
model="$(tr -d '\0' </proc/device-tree/model 2>/dev/null || echo Unknown)"
serial="$(awk -F: '/Serial/{print $2}' /proc/cpuinfo | xargs || true)"

# ----- CPU % -----
read -r u1 n1 s1 i1 io1 irq1 sirq1 st1 _ < <(awk '/^cpu /{print $2,$3,$4,$5,$6,$7,$8,$9}' /proc/stat)
sleep 0.5
read -r u2 n2 s2 i2 io2 irq2 sirq2 st2 _ < <(awk '/^cpu /{print $2,$3,$4,$5,$6,$7,$8,$9}' /proc/stat)
t=$(( (u2+n2+s2+i2+io2+irq2+sirq2+st2) - (u1+n1+s1+i1+io1+irq1+sirq1+st1) ))
id=$(( i2 - i1 ))
cpu_pct=$(awk -v t="$t" -v id="$id" 'BEGIN{ if(t>0) printf "%.1f", 100*(t-id)/t; else print "0.0" }')

# ----- Memory % -----
mem_total_kb=$(awk '/MemTotal/{print $2}' /proc/meminfo)
mem_avail_kb=$(awk '/MemAvailable/{print $2}' /proc/meminfo)
mem_used_pct=$(awk -v t="$mem_total_kb" -v a="$mem_avail_kb" 'BEGIN{ if(t>0) printf "%.1f", 100*(t-a)/t; else print "0.0" }')

# ----- Disk (root) -----
disk_used_pct=$(df -P / | awk 'NR==2{gsub(/%/,"",$5); print $5}')
disk_avail_gb=$(df -P -BG / | awk 'NR==2{gsub(/G/,"",$4); print $4}')

# ----- Temp, uptime, load -----
temp_raw="$(cat /sys/class/thermal/thermal_zone0/temp 2>/dev/null || echo 0)"
temp_c=$(awk -v v="$temp_raw" 'BEGIN{ printf "%.1f", v/1000 }')
uptime_s=$(awk '{printf "%d",$1}' /proc/uptime)
load1=$(awk '{print $1}' /proc/loadavg)

# ----- Device / OS / IP / SSID -----
hostname_val="$(hostname 2>/dev/null || echo raspberrypi)"

os_name="Linux"
if [[ -r /etc/os-release ]]; then
  # shellcheck disable=SC1091
  . /etc/os-release || true
  os_name="${PRETTY_NAME:-${NAME:-Linux}}"
fi

ipaddr="$(ip -4 addr show wlan0 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1 | head -n1)"
if [[ -z "$ipaddr" ]]; then
  ipaddr="$(hostname -I 2>/dev/null | awk '{print $1}')"
fi

ssid=""
if [[ -r /etc/hostapd/hostapd.conf ]]; then
  ssid="$(awk -F= '/^ssid=/{print $2}' /etc/hostapd/hostapd.conf 2>/dev/null | head -n1)"
fi
if [[ -z "$ssid" ]]; then
  ssid="$hostname_val"
fi

device_id="$ssid"

# ----- Print JSON on a single line -----
printf '{'
printf '"device_id":"%s",' "$(escape_json "$device_id")"
printf '"ip":"%s",'          "$(escape_json "$ipaddr")"
printf '"hostname":"%s",'    "$(escape_json "$hostname_val")"
printf '"os":"%s",'          "$(escape_json "$os_name")"
printf '"model":"%s",'       "$(escape_json "$model")"
printf '"serial":"%s",'      "$(escape_json "$serial")"
printf '"cpu_pct":%.1f,'     "$cpu_pct"
printf '"mem_used_pct":%.1f,' "$mem_used_pct"
printf '"disk_used_pct":%.1f,' "$disk_used_pct"
printf '"disk_avail_gb":%.1f,' "$disk_avail_gb"
printf '"temp_c":%.1f,'      "$temp_c"
printf '"uptime_s":%d,'      "$uptime_s"
printf '"load1":%.2f'        "$load1"
printf '}\n'
EOF

  chmod 755 /usr/local/bin/pi-stats.sh
  chown "$OWNER:$OWNER" /usr/local/bin/pi-stats.sh || true
}

# ---------- pi-servsync & portal.service ----------
  install_services() {
  log "Installing pi-servsync.service …"
  cat >/etc/systemd/system/pi-servsync.service <<EOF
[Unit]
Description=Apply /etc/pi_roles.conf to services (ISI / Wireshark / FMS)
After=multi-user.target

[Service]
Type=simple
User=initbox
Group=initbox
Environment=ROLES_CONF=/etc/pi_roles.conf
ExecStart=/usr/local/bin/pi-servsync.sh
Restart=always
RestartSec=2
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

  log "Installing portal.service …"
  cat >/etc/systemd/system/portal.service <<EOF
[Unit]
Description=INITbox captive-portal redirect (80 -> 1880)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
User=initbox
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_RAW
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_RAW
ExecStart=/usr/local/bin/portal.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
}

# ---------- Main ----------
log "Starting Dashboard (ttyd + portal) module …"

install_ttyd
install_nodered
deploy_flows_settings
install_nodered_service
install_pi_rolectl
install_pi_servsync
install_portal
install_pi_stats
install_services

systemctl daemon-reload
systemctl enable pi-nodered.service pi-servsync.service ttyd.service portal.service 2>/dev/null || true
systemctl restart pi-nodered.service 2>/dev/null || true
systemctl restart pi-servsync.service 2>/dev/null || true
systemctl restart ttyd.service 2>/dev/null || true
systemctl restart portal.service 2>/dev/null || true

log "Dashboard module installed. Node-RED on port 1880; portal redirects wlan0:80 -> 1880."
log "Login link : http://initbox.wlan:1880/ui"
