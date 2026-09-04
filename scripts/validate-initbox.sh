#!/usr/bin/env bash
# InitBox installation validator.
#
# Read-only validation for InitBox runtime layout, hotspot/captive portal,
# Dashboard/Web Terminal, operator-controlled Pi-full field modules, and network
# safety. It does not repair services, change roles, or restart units.

set -uo pipefail

ACTION="validate"
PROFILE_OVERRIDE=""
REPORT_DIR="${INITBOX_LOG_DIR:-/var/log/initbox}"
REPORT_FILE=""
STATE_FILE="${INITBOX_STATE_FILE:-/etc/initbox/install-state.env}"
RUNTIME_ROOT="${INITBOX_RUNTIME_ROOT:-/usr/local/share/initbox}"
BIN_DIR="${INITBOX_BIN_DIR:-/usr/local/bin}"
HOTSPOT_IFACE="${HOTSPOT_IFACE:-wlan0}"
ROLE_FILE="${ROLE_FILE:-/etc/pi_roles.conf}"
MODS_FILE="${MODS_FILE:-/etc/initbox/dashboard-modules.env}"
PORTAL_TARGET_FILE="${PORTAL_TARGET_FILE:-/etc/initbox/portal-target.env}"
HOTSPOT_STATE_FILE="${HOTSPOT_STATE_FILE:-/etc/initbox/hotspot-state.env}"
DNSMASQ_CONF="${DNSMASQ_CONF:-/etc/dnsmasq.d/initbox-hotspot.conf}"
HOSTAPD_CONF="${HOSTAPD_CONF:-/etc/hostapd/hostapd.conf}"
DHCPCD_CONF="${DHCPCD_CONF:-/etc/dhcpcd.conf}"
NM_HOTSPOT_FILE="${NM_HOTSPOT_FILE:-/etc/NetworkManager/conf.d/99-initbox-hotspot-unmanaged.conf}"
OLD_LOG_GLOBS=(/home/*/pi_logs /home/pi_logs)

PASS_COUNT=0
WARN_COUNT=0
FAIL_COUNT=0
INFO_COUNT=0

usage() {
  cat <<'EOF_USAGE'
Usage:
  sudo initbox-validate.sh
  sudo initbox-validate.sh validate
  sudo initbox-validate.sh summary

Options:
  --profile pi-full|pi-zero2w   Override detected profile.
  --report FILE                 Write report to FILE.
  --help, -h                    Show this help.

The validator is read-only. It does not change roles, restart services, or repair configs.
EOF_USAGE
}

die_now() {
  printf '[VALIDATE] [ERR] %s\n' "$*" >&2
  exit 2
}

parse_args() {
  if [ "$#" -gt 0 ]; then
    case "$1" in
      validate|summary)
        ACTION="$1"
        shift
        ;;
    esac
  fi

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --profile)
        [ "$#" -ge 2 ] || die_now "--profile requires pi-full or pi-zero2w"
        PROFILE_OVERRIDE="$2"
        shift 2
        ;;
      --report)
        [ "$#" -ge 2 ] || die_now "--report requires a file path"
        REPORT_FILE="$2"
        shift 2
        ;;
      --help|-h|help)
        usage
        exit 0
        ;;
      *)
        usage >&2
        die_now "unknown argument: $1"
        ;;
    esac
  done

  case "$ACTION" in
    validate|summary) ;;
    *) die_now "unknown action: $ACTION" ;;
  esac

  case "$PROFILE_OVERRIDE" in
    ""|pi-full|pi-zero2w) ;;
    *) die_now "unsupported profile override: $PROFILE_OVERRIDE" ;;
  esac
}

setup_report() {
  local stamp=""
  stamp="$(date +%Y%m%d-%H%M%S)"

  if [ -z "$REPORT_FILE" ]; then
    if [ "$(id -u)" -eq 0 ]; then
      install -d -m 0755 "$REPORT_DIR"
      REPORT_FILE="${REPORT_DIR}/validate-${stamp}.log"
    else
      REPORT_FILE="/tmp/initbox-validate-${stamp}.log"
    fi
  else
    install -d -m 0755 "$(dirname "$REPORT_FILE")" 2>/dev/null || true
  fi

  : >"$REPORT_FILE" 2>/dev/null || REPORT_FILE="/tmp/initbox-validate-${stamp}.log"
  : >"$REPORT_FILE"

  exec > >(tee -a "$REPORT_FILE") 2>&1

  if [ "$(id -u)" -eq 0 ] && [ "$(dirname "$REPORT_FILE")" = "$REPORT_DIR" ]; then
    ln -sfn "$(basename "$REPORT_FILE")" "${REPORT_DIR}/validate-latest.log" 2>/dev/null || true
  fi
}

section() { echo; echo "== $* =="; }
info() { INFO_COUNT=$((INFO_COUNT + 1)); printf '[INFO] %s\n' "$*"; }
pass() { PASS_COUNT=$((PASS_COUNT + 1)); printf '[PASS] %s\n' "$*"; }
warn() { WARN_COUNT=$((WARN_COUNT + 1)); printf '[WARN] %s\n' "$*"; }
fail() { FAIL_COUNT=$((FAIL_COUNT + 1)); printf '[FAIL] %s\n' "$*"; }

have_cmd() { command -v "$1" >/dev/null 2>&1; }
unit_exists() { have_cmd systemctl && systemctl cat "$1" >/dev/null 2>&1; }
unit_active() { have_cmd systemctl && systemctl is-active --quiet "$1"; }
unit_enabled() { have_cmd systemctl && systemctl is-enabled --quiet "$1" 2>/dev/null; }

state_get() {
  local key="$1"
  local line=""
  local value=""

  [ -f "$STATE_FILE" ] || return 1
  line="$(grep -m 1 "^${key}=" "$STATE_FILE" 2>/dev/null || true)"
  [ -n "$line" ] || return 1
  value="${line#*=}"
  value="${value#\"}"
  value="${value%\"}"
  printf '%s\n' "$value"
}

file_has() {
  local file="$1"
  local pattern="$2"
  [ -f "$file" ] && grep -Eq "$pattern" "$file"
}

check_file() {
  local path="$1"
  local label="$2"

  if [ -e "$path" ]; then
    pass "$label exists: $path"
  else
    fail "$label missing: $path"
  fi
}

check_executable() {
  local path="$1"
  local label="$2"

  if [ -x "$path" ]; then
    pass "$label executable: $path"
  elif [ -e "$path" ]; then
    fail "$label exists but is not executable: $path"
  else
    fail "$label missing: $path"
  fi
}

check_required_unit_active() {
  local unit="$1"

  if ! unit_exists "$unit"; then
    fail "systemd unit missing: $unit"
    return 0
  fi

  pass "systemd unit installed: $unit"
  if unit_active "$unit"; then
    pass "systemd unit active: $unit"
  else
    fail "systemd unit not active: $unit"
  fi
}

check_optional_unit_installed() {
  local unit="$1"
  local label="$2"

  if unit_exists "$unit"; then
    pass "$label installed: $unit"
  else
    pass "$label not installed; optional for current role state: $unit"
  fi
}

service_status_line() {
  local unit="$1"
  local active="unknown"
  local enabled="unknown"

  if have_cmd systemctl; then
    active="$(systemctl is-active "$unit" 2>/dev/null || true)"
    enabled="$(systemctl is-enabled "$unit" 2>/dev/null || true)"
  fi

  printf '%s active=%s enabled=%s\n' "$unit" "$active" "$enabled"
}

port_listening() {
  local port="$1"
  have_cmd ss || return 1
  ss -ltn 2>/dev/null | awk -v port=":$port" '$4 ~ port "$" {found=1} END {exit found ? 0 : 1}'
}

curl_status() {
  local url="$1"
  shift
  have_cmd curl || return 127
  curl -sS -o /dev/null -w '%{http_code}' --connect-timeout 3 --max-time 6 "$@" "$url" 2>/dev/null
}

curl_header_location() {
  local url="$1"
  shift
  have_cmd curl || return 127
  curl -sS -D - -o /dev/null --connect-timeout 3 --max-time 6 "$@" "$url" 2>/dev/null \
    | awk 'BEGIN{IGNORECASE=1} /^Location:/ {sub(/\r$/, ""); print; exit}'
}

detect_profile() {
  local profile=""
  local gateway=""
  local model=""

  if [ -n "$PROFILE_OVERRIDE" ]; then
    printf '%s\n' "$PROFILE_OVERRIDE"
    return 0
  fi

  profile="$(state_get PROFILE_ID 2>/dev/null || true)"
  if [ -n "$profile" ]; then
    printf '%s\n' "$profile"
    return 0
  fi

  gateway="$(state_get HOTSPOT_GATEWAY 2>/dev/null || true)"
  case "$gateway" in
    192.168.20.1) printf '%s\n' pi-zero2w; return 0 ;;
    192.168.30.1|192.168.40.1|192.168.50.1) printf '%s\n' pi-full; return 0 ;;
  esac

  model="$(tr -d '\0' </proc/device-tree/model 2>/dev/null || true)"
  case "$model" in
    *"Zero"*) printf '%s\n' pi-zero2w ;;
    *"Raspberry Pi 3"*|*"Raspberry Pi 4"*|*"Raspberry Pi 5"*|*"Compute Module 4"*|*"Compute Module 5"*) printf '%s\n' pi-full ;;
    *) printf '%s\n' unknown ;;
  esac
}

detect_hotspot_ip() {
  local ip_from_state=""
  local ip_from_iface=""
  local prefix=""

  ip_from_state="$(state_get HOTSPOT_GATEWAY 2>/dev/null || true)"
  if [ -n "$ip_from_state" ]; then
    printf '%s\n' "$ip_from_state"
    return 0
  fi

  if [ -f "$HOTSPOT_STATE_FILE" ]; then
    prefix="$(sed -n 's/^HOTSPOT_SUBNET_PREFIX=//p' "$HOTSPOT_STATE_FILE" | tail -n 1)"
    if [ -n "$prefix" ]; then
      printf '%s.1\n' "$prefix"
      return 0
    fi
  fi

  ip_from_iface="$(ip -4 addr show "$HOTSPOT_IFACE" 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1 | head -n 1 || true)"
  if [ -n "$ip_from_iface" ]; then
    printf '%s\n' "$ip_from_iface"
    return 0
  fi

  printf 'unknown\n'
}

check_baseline() {
  local profile="$1"
  local gateway="$2"
  local old=""

  section "Baseline state"
  info "Report: $REPORT_FILE"
  info "Profile: $profile"
  info "Expected hotspot IP: $gateway"
  info "State file: $STATE_FILE"

  if [ "$(id -u)" -eq 0 ]; then
    pass "validator is running as root"
  else
    warn "validator is not running as root; some checks may be incomplete"
  fi

  check_file "$STATE_FILE" "install state"
  check_file "$RUNTIME_ROOT" "runtime root"
  check_file "$RUNTIME_ROOT/manifest.json" "runtime manifest"
  check_file "$RUNTIME_ROOT/scripts/manifest.json" "runtime source manifest"
  check_file "$RUNTIME_ROOT/scripts/lib/hardware.sh" "hardware library"
  check_file "$RUNTIME_ROOT/scripts/lib/profile.sh" "profile library"
  check_file "$RUNTIME_ROOT/scripts/lib/module-runner.sh" "module runner library"
  check_file "$RUNTIME_ROOT/scripts/bin/initbox-module-runner.sh" "runtime source module runner wrapper"
  check_file "$RUNTIME_ROOT/scripts/bin/initbox-package-cache.sh" "runtime source package cache wrapper"

  check_executable "$BIN_DIR/initbox-bootstrap.sh" "bootstrap command"
  check_executable "$BIN_DIR/initbox-installer.sh" "installer command"
  check_executable "$BIN_DIR/initbox-sync.sh" "sync command"
  check_executable "$BIN_DIR/initbox-module-runner.sh" "module runner command"
  check_executable "$BIN_DIR/initbox-package-cache.sh" "package cache command"
  check_executable "$BIN_DIR/initbox-validate.sh" "validator command"

  if [ -d "$REPORT_DIR" ]; then
    pass "central log directory exists: $REPORT_DIR"
  else
    fail "central log directory missing: $REPORT_DIR"
  fi

  for old in "${OLD_LOG_GLOBS[@]}"; do
    if compgen -G "$old" >/dev/null 2>&1; then
      fail "legacy log directory still exists: $old"
    else
      pass "legacy log directory absent: $old"
    fi
  done
}

check_systemd_failed() {
  section "Systemd failed units"

  if ! have_cmd systemctl; then
    warn "systemctl not available"
    return 0
  fi

  if systemctl --failed --no-legend --no-pager 2>/dev/null | grep -q .; then
    fail "systemd has failed units"
    systemctl --failed --no-pager || true
  else
    pass "systemd has no failed units"
  fi
}

check_hotspot() {
  local gateway="$1"
  local assigned=""
  local dhcp_range=""

  section "Hotspot"

  if ip link show "$HOTSPOT_IFACE" >/dev/null 2>&1; then
    pass "hotspot interface exists: $HOTSPOT_IFACE"
  else
    fail "hotspot interface missing: $HOTSPOT_IFACE"
  fi

  assigned="$(ip -4 addr show "$HOTSPOT_IFACE" 2>/dev/null | awk '/inet /{print $2}' | head -n 1 || true)"
  if [ "$assigned" = "${gateway}/24" ]; then
    pass "$HOTSPOT_IFACE has expected IP ${gateway}/24"
  else
    fail "$HOTSPOT_IFACE expected ${gateway}/24, got ${assigned:-none}"
  fi

  check_file "$HOSTAPD_CONF" "hostapd config"
  if file_has "$HOSTAPD_CONF" "^interface=${HOTSPOT_IFACE}$"; then
    pass "hostapd binds $HOTSPOT_IFACE"
  else
    fail "hostapd config does not bind $HOTSPOT_IFACE"
  fi

  check_file "$DNSMASQ_CONF" "dnsmasq hotspot config"
  if file_has "$DNSMASQ_CONF" "^interface=${HOTSPOT_IFACE}$"; then pass "dnsmasq binds $HOTSPOT_IFACE"; else fail "dnsmasq config does not bind $HOTSPOT_IFACE"; fi
  if file_has "$DNSMASQ_CONF" "^listen-address=${gateway}$"; then pass "dnsmasq listens on hotspot IP $gateway"; else fail "dnsmasq listen-address missing or wrong for $gateway"; fi
  if file_has "$DNSMASQ_CONF" "^dhcp-option=3,${gateway}$"; then pass "dnsmasq DHCP gateway option points to $gateway"; else fail "dnsmasq DHCP gateway option missing/wrong"; fi
  if file_has "$DNSMASQ_CONF" "^dhcp-option=6,${gateway}$"; then pass "dnsmasq DHCP DNS option points to $gateway"; else fail "dnsmasq DHCP DNS option missing/wrong"; fi
  if file_has "$DNSMASQ_CONF" "^address=/#/${gateway}$"; then pass "dnsmasq captive DNS catch-all points to $gateway"; else fail "dnsmasq captive DNS catch-all missing/wrong"; fi

  dhcp_range="$(sed -n 's/^dhcp-range=//p' "$DNSMASQ_CONF" 2>/dev/null | head -n 1 || true)"
  if [ -n "$dhcp_range" ]; then pass "dnsmasq DHCP range present: $dhcp_range"; else fail "dnsmasq DHCP range missing"; fi

  if file_has "$DHCPCD_CONF" "static ip_address=${gateway}/24"; then
    pass "dhcpcd contains hotspot static IP block"
  else
    warn "dhcpcd hotspot static IP block not found for $gateway; direct IP may still be applied"
  fi

  if [ -f "$NM_HOTSPOT_FILE" ] && file_has "$NM_HOTSPOT_FILE" "interface-name:${HOTSPOT_IFACE}"; then
    pass "NetworkManager leaves hotspot interface unmanaged"
  else
    warn "NetworkManager hotspot unmanaged policy missing; wlan0 may be disturbed on NM-based images"
  fi

  check_required_unit_active hostapd.service
  check_required_unit_active dnsmasq.service

  if have_cmd dnsmasq; then
    if dnsmasq --test >/tmp/initbox-dnsmasq-test.$$ 2>&1; then
      pass "dnsmasq --test passes"
    else
      fail "dnsmasq --test fails"
      sed 's/^/[dnsmasq] /' /tmp/initbox-dnsmasq-test.$$ || true
    fi
    rm -f /tmp/initbox-dnsmasq-test.$$
  else
    fail "dnsmasq command missing"
  fi
}

check_captive_dns_rules() {
  local gateway="$1"
  local domain=""

  section "Captive DNS probe domains"

  for domain in \
    initbox.wlan \
    connectivitycheck.gstatic.com \
    clients3.google.com \
    captive.apple.com \
    www.apple.com \
    msftconnecttest.com \
    www.msftconnecttest.com \
    msftncsi.com \
    www.msftncsi.com \
    dns.msftncsi.com \
    detectportal.firefox.com \
    neverssl.com \
    www.neverssl.com; do
    if file_has "$DNSMASQ_CONF" "^address=/${domain}/${gateway}$"; then
      pass "captive DNS rule present: $domain -> $gateway"
    else
      fail "captive DNS rule missing: $domain -> $gateway"
    fi
  done
}

check_portal_http() {
  local gateway="$1"
  local target_port=""
  local target_name="terminal"
  local status=""
  local location=""

  section "Captive portal HTTP"

  check_executable /usr/local/sbin/initbox-portal-target "portal target helper"
  check_executable /usr/local/sbin/initbox-captive-responder.sh "captive responder"
  check_file /etc/systemd/system/initbox-captive-http.socket "captive HTTP socket unit"
  check_file /etc/systemd/system/initbox-captive-http@.service "captive HTTP service unit"
  check_required_unit_active initbox-captive-http.socket

  if port_listening 80; then pass "TCP port 80 is listening"; else fail "TCP port 80 is not listening; Windows captive portal cannot trigger"; fi

  if [ -r "$PORTAL_TARGET_FILE" ]; then
    target_port="$(sed -n 's/^INITBOX_PORTAL_TARGET_PORT=//p' "$PORTAL_TARGET_FILE" | tail -n 1)"
    target_name="$(sed -n 's/^INITBOX_PORTAL_TARGET_NAME=//p' "$PORTAL_TARGET_FILE" | tail -n 1)"
    pass "portal target file present: ${target_name:-unknown}/${target_port:-unknown}"
  else
    target_port="7681"
    warn "portal target file missing; responder should default to terminal port 7681"
  fi

  case "$target_port" in 7681|8080) pass "portal target port is valid: $target_port" ;; *) fail "portal target port invalid: ${target_port:-unset}" ;; esac

  if have_cmd curl; then
    status="$(curl_status "http://127.0.0.1/" || true)"
    case "$status" in 301|302|303|307|308) pass "localhost portal returns redirect status $status" ;; *) fail "localhost portal expected redirect, got HTTP ${status:-none}" ;; esac
    location="$(curl_header_location "http://127.0.0.1/" || true)"
    if printf '%s' "$location" | grep -Eq ":(7681|8080)/"; then pass "localhost portal Location header points to target port: $location"; else fail "localhost portal Location header missing/wrong: ${location:-none}"; fi

    status="$(curl_status "http://${gateway}/" || true)"
    case "$status" in 301|302|303|307|308) pass "hotspot IP portal returns redirect status $status" ;; *) fail "hotspot IP portal expected redirect, got HTTP ${status:-none}" ;; esac

    status="$(curl_status "http://${gateway}/connecttest.txt" -H "Host: www.msftconnecttest.com" || true)"
    case "$status" in 301|302|303|307|308) pass "Windows NCSI HTTP probe is redirected by portal status $status" ;; *) fail "Windows NCSI HTTP probe expected redirect, got HTTP ${status:-none}" ;; esac

    location="$(curl_header_location "http://${gateway}/connecttest.txt" -H "Host: www.msftconnecttest.com" || true)"
    if printf '%s' "$location" | grep -Eq "http://www.msftconnecttest.com:(7681|8080)/"; then
      pass "Windows NCSI Location header preserves host and points to InitBox target: $location"
    else
      warn "Windows NCSI Location header unusual: ${location:-none}"
    fi
  else
    warn "curl missing; HTTP portal checks skipped"
  fi
}

check_web_terminal() {
  local status=""

  section "Web Terminal"
  check_executable /usr/local/bin/ttyd "ttyd binary"
  check_file /etc/systemd/system/ttyd.service "ttyd unit"
  check_required_unit_active ttyd.service
  if port_listening 7681; then pass "TCP port 7681 is listening for Web Terminal"; else fail "TCP port 7681 is not listening"; fi

  if have_cmd curl; then
    status="$(curl_status "http://127.0.0.1:7681/" || true)"
    case "$status" in 200|301|302|401|403) pass "ttyd responds over HTTP with status $status" ;; *) fail "ttyd HTTP response unexpected: ${status:-none}" ;; esac
  fi
}

check_dashboard() {
  local selected=""
  local target_port=""
  local status=""

  section "Dashboard"

  selected="$(state_get DASHBOARD_SELECTED 2>/dev/null || true)"
  target_port="$(sed -n 's/^INITBOX_PORTAL_TARGET_PORT=//p' "$PORTAL_TARGET_FILE" 2>/dev/null | tail -n 1 || true)"

  if unit_exists initbox-dashboard.service || [ "$selected" = "yes" ] || [ "$target_port" = "8080" ]; then
    check_executable /usr/local/bin/initbox-dashboard-api.py "Dashboard API"
    check_file "$RUNTIME_ROOT/dashboard/ui/index.html" "Dashboard UI index"
    check_required_unit_active initbox-dashboard.service
    if port_listening 8080; then pass "TCP port 8080 is listening for Dashboard"; else fail "Dashboard target selected/installed but TCP port 8080 is not listening"; fi

    if have_cmd curl; then
      status="$(curl_status "http://127.0.0.1:8080/api/health" || true)"
      case "$status" in 200) pass "Dashboard health endpoint returns HTTP 200" ;; *) fail "Dashboard health endpoint failed: HTTP ${status:-none}" ;; esac
    fi
  else
    pass "Dashboard not selected/installed"
  fi
}

read_roles() {
  local role_text=""
  if [ -r "$ROLE_FILE" ]; then
    # shellcheck disable=SC1090
    . "$ROLE_FILE" 2>/dev/null || true
    role_text="${ROLES:-${roles:-}}"
  fi
  role_text="${role_text,,}"
  role_text="${role_text//$'\r'/}"
  printf '%s\n' "$role_text"
}

role_has() {
  local wanted="$1"
  local role=""
  for role in $(read_roles); do
    case "$wanted:$role" in
      isi:isi|fms:fms|sniff:sniff|sniff:wireshark|sniff:sniffer|sniff:sniffer-bridge) return 0 ;;
    esac
  done
  return 1
}

mod_flag_is_one() {
  local key="$1"
  [ -r "$MODS_FILE" ] && grep -Eq "^${key}=1$" "$MODS_FILE"
}

check_unit_inactive_when_role_off() {
  local unit="$1"
  local label="$2"

  if unit_exists "$unit"; then
    pass "$label unit installed: $unit"
    if unit_active "$unit"; then
      fail "$unit active while role is not active"
    else
      pass "$unit inactive while role is not active"
    fi
    if unit_enabled "$unit"; then
      warn "$unit enabled while role is not active"
    else
      pass "$unit disabled while role is not active"
    fi
  else
    fail "$label unit missing after module installation: $unit"
  fi
}

check_pi_full_runtime() {
  local roles=""
  local eth=""
  local ipaddr=""

  section "Pi-full runtime control and bridge safety"

  check_file "$ROLE_FILE" "role file"
  roles="$(read_roles)"
  info "Current roles: ${roles:-none}"

  check_file "$MODS_FILE" "module availability flags"
  if mod_flag_is_one ISI; then pass "ISI module flag enabled for Dashboard toggle"; else fail "ISI module flag missing/disabled for Dashboard toggle"; fi
  if mod_flag_is_one WSBR0; then pass "Sniffer module flag enabled for Dashboard toggle"; else fail "Sniffer module flag missing/disabled for Dashboard toggle"; fi
  if mod_flag_is_one FMS; then pass "FMS module flag enabled for Dashboard toggle"; else fail "FMS module flag missing/disabled for Dashboard toggle"; fi

  check_executable /usr/local/bin/pi-servsync.sh "runtime service sync"
  check_executable /usr/local/bin/pi-rolectl.sh "role control"
  check_required_unit_active pi-servsync.service

  if role_has isi || role_has sniff; then
    warn "ISI/sniff role is active; bridge mode may intentionally own wired Ethernet"
    check_required_unit_active bridge-check.service
  else
    pass "ISI/sniff roles are not active"
    if unit_exists bridge-check.service; then
      pass "bridge-check.service installed for Dashboard-controlled bridge role"
      if unit_active bridge-check.service; then
        fail "bridge-check.service active while no ISI/sniff role is active"
      else
        pass "bridge-check.service inactive by design while no ISI/sniff role is active"
      fi
      if unit_enabled bridge-check.service; then
        warn "bridge-check.service enabled while no ISI/sniff role is active"
      else
        pass "bridge-check.service disabled by design while no ISI/sniff role is active"
      fi
    else
      fail "bridge-check.service missing after sniffer-bridge module installation"
    fi

    if ip link show br0 >/dev/null 2>&1; then
      if ip -br link show br0 2>/dev/null | grep -q '\<UP\>'; then
        fail "br0 is UP while no ISI/sniff role is active"
      else
        warn "br0 exists but is not UP while no bridge role is active"
      fi
    else
      pass "br0 absent while no ISI/sniff role is active"
    fi

    check_unit_inactive_when_role_off isirunall.service "ISI"
    check_unit_inactive_when_role_off wireshark-autostart.service "Sniffer"
  fi

  if role_has fms; then
    check_required_unit_active fms.service
  else
    check_unit_inactive_when_role_off fms.service "FMS"
  fi

  for eth in eth0 eth1; do
    if ip link show "$eth" >/dev/null 2>&1; then
      ipaddr="$(ip -4 addr show dev "$eth" 2>/dev/null | awk '/inet /{print $2}' | head -n 1 || true)"
      info "$eth IPv4: ${ipaddr:-none}"
    fi
  done
}

check_zero_shape() {
  local iface=""
  local ipaddr=""

  section "Pi Zero network shape"

  for iface in eth0 eth1 br0 can0; do
    if ip link show "$iface" >/dev/null 2>&1; then
      ipaddr="$(ip -4 addr show dev "$iface" 2>/dev/null | awk '/inet /{print $2}' | head -n 1 || true)"
      if [ -n "$ipaddr" ]; then fail "$iface should not have IPv4 on Zero profile, got $ipaddr"; else pass "$iface has no IPv4 as expected"; fi
    fi
  done

  while IFS= read -r iface; do
    [ -z "$iface" ] && continue
    ipaddr="$(ip -4 addr show dev "$iface" 2>/dev/null | awk '/inet /{print $2}' | head -n 1 || true)"
    if [ -n "$ipaddr" ]; then fail "$iface should not have IPv4 on Zero profile, got $ipaddr"; else pass "$iface has no IPv4 as expected"; fi
  done < <(find /sys/class/net -maxdepth 1 -mindepth 1 -name 'veth*_host' -printf '%f\n' 2>/dev/null | sort || true)

  if unit_exists initbox-dashboard.service; then fail "Dashboard service must not be installed on Zero profile"; else pass "Dashboard service absent on Zero profile"; fi
}

check_package_cache() {
  section "Package cache"
  check_file /opt/initbox/packages "package cache root"
  if [ -d /opt/initbox/packages/apt ]; then pass "APT package cache directory exists"; else warn "APT package cache directory missing; offline module installs may fail"; fi
}

print_service_snapshot() {
  section "Service snapshot"
  for unit in \
    hostapd.service \
    dnsmasq.service \
    ttyd.service \
    initbox-captive-http.socket \
    initbox-dashboard.service \
    pi-servsync.service \
    bridge-check.service \
    isirunall.service \
    wireshark-autostart.service \
    fms.service; do
    service_status_line "$unit"
  done
}

print_network_snapshot() {
  section "Network snapshot"
  if have_cmd ip; then
    ip -br addr || true
    echo
    ip route || true
  else
    warn "ip command missing"
  fi
}

finish() {
  section "Summary"
  echo "PASS: $PASS_COUNT"
  echo "WARN: $WARN_COUNT"
  echo "FAIL: $FAIL_COUNT"
  echo "INFO: $INFO_COUNT"
  echo "Report: $REPORT_FILE"

  if [ "$FAIL_COUNT" -gt 0 ]; then
    echo
    echo "Validation result: FAIL"
    exit 1
  fi

  if [ "$WARN_COUNT" -gt 0 ]; then
    echo
    echo "Validation result: PASS with warnings"
    exit 0
  fi

  echo
  echo "Validation result: PASS"
}

main() {
  local profile=""
  local gateway=""

  parse_args "$@"
  setup_report

  echo "InitBox validator"
  echo "================="
  date

  profile="$(detect_profile)"
  gateway="$(detect_hotspot_ip)"

  check_baseline "$profile" "$gateway"
  check_systemd_failed
  check_hotspot "$gateway"
  check_captive_dns_rules "$gateway"
  check_portal_http "$gateway"
  check_web_terminal
  check_dashboard

  case "$profile" in
    pi-full) check_pi_full_runtime ;;
    pi-zero2w) check_zero_shape ;;
    *) warn "unknown profile; profile-specific checks skipped" ;;
  esac

  check_package_cache
  print_service_snapshot
  print_network_snapshot
  finish
}

main "$@"
