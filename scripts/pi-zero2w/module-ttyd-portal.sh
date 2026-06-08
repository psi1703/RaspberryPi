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

# ---------- Embed portal.sh ----------
install_portal() {
  log "Writing /usr/local/bin/portal.sh …"
  cat >/usr/local/bin/portal.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

IFACE="${1:-wlan0}"
DASHBOARD_PORT="${DASHBOARD_PORT:-7681}"

if ! iptables -t nat -C PREROUTING -i "$IFACE" -p tcp --dport 80 \
       -j REDIRECT --to-ports "$DASHBOARD_PORT" 2>/dev/null; then
  iptables -t nat -A PREROUTING -i "$IFACE" -p tcp --dport 80 \
       -j REDIRECT --to-ports "$DASHBOARD_PORT"
fi
EOF

  chmod 755 /usr/local/bin/portal.sh
  chown "$OWNER:$OWNER" /usr/local/bin/portal.sh || true
}

install_services() {
  log "Installing portal.service …"
  cat >/etc/systemd/system/portal.service <<EOF
[Unit]
Description=INITbox captive-portal redirect (80 -> 7681)
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
log "Starting Web termianl (ttyd + portal) module …"

install_ttyd
install_portal
install_services

systemctl daemon-reload
systemctl enable ttyd.service portal.service 2>/dev/null || true
systemctl restart ttyd.service 2>/dev/null || true
systemctl restart portal.service 2>/dev/null || true

log "Web terminal installed. TTYD on port 7681; portal redirects wlan0:80 -> 7681."
log "Login link : http://initbox.wlan:7681/"
