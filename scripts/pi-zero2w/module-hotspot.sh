#!/usr/bin/env bash
set -euo pipefail

: "${OWNER:=initbox}"
: "${HOTSPOT_PASS:=TomatoH34d}"
: "${LOGFILE:=/home/${OWNER}/pi_logs/initbox-install.log}"

ts(){ date +"%Y-%m-%d %H:%M:%S"; }
log(){  echo "[HOTSPOT $(ts)] $*" | tee -a "$LOGFILE"; }
ok(){   echo "[HOTSPOT $(ts)] [OK] $*" | tee -a "$LOGFILE"; }
warn(){ echo "[HOTSPOT $(ts)] [WARN] $*" | tee -a "$LOGFILE" >&2; }
err(){  echo "[HOTSPOT $(ts)] [ERR] $*" | tee -a "$LOGFILE" >&2; }

apt_safe(){ apt-get -o Dpkg::Use-Pty=0 -o Acquire::Retries=5 "$@" 2>&1 | tee -a "$LOGFILE"; }

ask(){
  local prompt="$1" default="$2" reply
  if [ -t 0 ]; then
    read -rp "$prompt [$default]: " reply
    echo "${reply:-$default}"
  else
    echo "$default"
  fi
}

calc_hotspot_subnet(){
  local m
  m="$(tr -d '\0' </proc/device-tree/model 2>/dev/null || echo "")"
  case "$m" in
    *Zero*)                 echo "192.168.20" ;;
    *"Raspberry Pi 3"*)     echo "192.168.30" ;;
    *"Raspberry Pi 4"*)     echo "192.168.40" ;;
    *"Raspberry Pi 5"*)     echo "192.168.50" ;;
    *)                      echo "192.168.20" ;;
  esac
}

hostapd_stack_up(){
  log "Unmasking and enabling hotspot stack …"
  systemctl unmask hostapd 2>/dev/null || true

  if [[ -f /etc/default/hostapd ]]; then
    sed -i 's|^#\?DAEMON_CONF=.*|DAEMON_CONF="/etc/hostapd/hostapd.conf"|' /etc/default/hostapd 2>/dev/null || true
  else
    echo 'DAEMON_CONF="/etc/hostapd/hostapd.conf"' >/etc/default/hostapd
  fi

  rfkill unblock wifi 2>/dev/null || rfkill unblock all 2>/dev/null || true

  systemctl daemon-reload
  systemctl enable dhcpcd dnsmasq hostapd 2>/dev/null || true
  systemctl restart dhcpcd 2>/dev/null || systemctl start dhcpcd || true
  systemctl restart dnsmasq 2>/dev/null || systemctl start dnsmasq || true
  systemctl restart hostapd 2>/dev/null || systemctl start hostapd || true
}

log "Installing hotspot dependencies …"
apt_safe update -y
apt_safe install -y dnsmasq hostapd dhcpcd5 iproute2 iptables

BOXNO_FILE="/etc/pi-boxno"
if [[ -r "$BOXNO_FILE" ]]; then
  BOXNO="$(cat "$BOXNO_FILE" 2>/dev/null || echo 1)"
else
  BOXNO="$(ask 'Enter BOX number (last octet, e.g., 1)' '1')"
  echo "$BOXNO" >"$BOXNO_FILE"
fi

SSID="initbox_${BOXNO}"
BASEIP="$(calc_hotspot_subnet)"
HIP="${BASEIP}.${BOXNO}"
RANGE="${BASEIP}.10,${BASEIP}.20,24h"

log "Hotspot SSID=${SSID}, IP=${HIP}, range=${RANGE}"
log "HOTSPOT_PASS is set (not logged)."

log "Writing /etc/hostapd/hostapd.conf …"
cat >/etc/hostapd/hostapd.conf <<EOF
# initbox-hotspot
country_code=AE
interface=wlan0
driver=nl80211
ssid=${SSID}
hw_mode=g
channel=7
wmm_enabled=0
macaddr_acl=0
auth_algs=1
ignore_broadcast_ssid=0
wpa=2
wpa_passphrase=${HOTSPOT_PASS}
wpa_key_mgmt=WPA-PSK
rsn_pairwise=CCMP
EOF
chown root:root /etc/hostapd/hostapd.conf
chmod 600 /etc/hostapd/hostapd.conf

log "Configuring dnsmasq for wlan0 …"
if [[ -f /etc/dnsmasq.conf ]] && ! grep -q 'initbox-hotspot' /etc/dnsmasq.conf; then
  cp /etc/dnsmasq.conf /etc/dnsmasq.conf.initbox.bak 2>/dev/null || true
fi

cat >/etc/dnsmasq.conf <<EOF
# initbox-hotspot
interface=wlan0
dhcp-range=${RANGE}
domain=wlan0

# Local dashboard name
address=/#/${HIP}

# Captive portal / connectivity-check domains
# Android
address=/connectivitycheck.gstatic.com/${HIP}
address=/clients3.google.com/${HIP}

# Apple
address=/captive.apple.com/${HIP}
address=/www.apple.com/${HIP}

# Windows
address=/msftconnecttest.com/${HIP}
address=/msftncsi.com/${HIP}

# Firefox
address=/detectportal.firefox.com/${HIP}
EOF

DHCPCD_CONF="/etc/dhcpcd.conf"
log "Ensuring static IP for wlan0 in ${DHCPCD_CONF} …"
if [[ -f "$DHCPCD_CONF" ]]; then
  if grep -q '^# initbox-hotspot' "$DHCPCD_CONF"; then
    sed -i '/^# initbox-hotspot/,+4d' "$DHCPCD_CONF"
  fi
else
  touch "$DHCPCD_CONF"
fi

cat >>"$DHCPCD_CONF" <<EOF

# initbox-hotspot
interface wlan0
    static ip_address=${HIP}/24
    nohook wpa_supplicant
EOF

hostapd_stack_up

log "Hotspot module installed. Connect to SSID '${SSID}' with password '${HOTSPOT_PASS}' for SSH."
