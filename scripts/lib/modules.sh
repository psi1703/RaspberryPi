#!/usr/bin/env bash
# InitBox unified module registry helper.
#
# Source this file; do not execute it directly.
# It maps logical module IDs to the hardware-profile-specific module scripts.
# Profile capability/allowance is validated separately by scripts/lib/profile.sh.

set -euo pipefail

initbox_module_script_path() {
  local profile_id="$1"
  local module_id="$2"
  local repo_root="$3"

  case "$profile_id:$module_id" in
    pi-zero2w:hotspot)
      printf '%s/scripts/pi-zero2w/module-hotspot.sh\n' "$repo_root"
      ;;
    pi-zero2w:web-terminal)
      printf '%s/scripts/pi-zero2w/module-ttyd-portal.sh\n' "$repo_root"
      ;;
    pi-zero2w:isi)
      printf '%s/scripts/pi-zero2w/module-isi.sh\n' "$repo_root"
      ;;
    pi-zero2w:sniffer-bridge)
      printf '%s/scripts/pi-zero2w/module-ws-br0.sh\n' "$repo_root"
      ;;
    pi-zero2w:fms)
      printf '%s/scripts/pi-zero2w/module-fms.sh\n' "$repo_root"
      ;;

    pi-full:hotspot)
      printf '%s/scripts/pi-full/module-hotspot.sh\n' "$repo_root"
      ;;
    pi-full:web-terminal)
      printf '%s/scripts/pi-full/module-ttyd-portal.sh\n' "$repo_root"
      ;;
    pi-full:dashboard)
      printf '%s/scripts/pi-full/module-dashboard.sh\n' "$repo_root"
      ;;
    pi-full:sniffer-bridge)
      printf '%s/scripts/pi-full/module-ws-br0.sh\n' "$repo_root"
      ;;
    pi-full:isi)
      printf '%s/scripts/pi-full/module-isi.sh\n' "$repo_root"
      ;;
    pi-full:fms)
      printf '%s/scripts/pi-full/module-fms.sh\n' "$repo_root"
      ;;
    pi-full:rtc)
      printf '%s/scripts/pi-full/module-rtc.sh\n' "$repo_root"
      ;;

    *)
      return 1
      ;;
  esac
}

initbox_module_display_name() {
  local module_id="$1"

  case "$module_id" in
    hotspot)
      printf 'Hotspot\n'
      ;;
    web-terminal)
      printf 'Web Terminal\n'
      ;;
    dashboard)
      printf 'React Dashboard\n'
      ;;
    sniffer-bridge)
      printf 'Sniffer / Bridge\n'
      ;;
    isi)
      printf 'ISI\n'
      ;;
    fms)
      printf 'FMS\n'
      ;;
    rtc)
      printf 'RTC\n'
      ;;
    *)
      printf '%s\n' "$module_id"
      ;;
  esac
}

initbox_all_known_modules() {
  cat <<'EOF_MODULES'
hotspot
web-terminal
dashboard
sniffer-bridge
isi
fms
rtc
EOF_MODULES
}

initbox_module_known() {
  local requested_module_id="$1"
  local module_id=""

  while IFS= read -r module_id; do
    if [ "$module_id" = "$requested_module_id" ]; then
      return 0
    fi
  done < <(initbox_all_known_modules)

  return 1
}

initbox_module_script_exists() {
  local profile_id="$1"
  local module_id="$2"
  local repo_root="$3"
  local module_script=""

  if ! module_script="$(initbox_module_script_path "$profile_id" "$module_id" "$repo_root")"; then
    return 1
  fi

  [ -f "$module_script" ]
}

initbox_print_module_registry() {
  local profile_id="$1"
  local repo_root="$2"
  local module_id=""
  local module_name=""
  local module_script=""

  echo "Module registry"
  echo "---------------"
  echo "Profile: $profile_id"
  echo

  while IFS= read -r module_id; do
    [ -z "$module_id" ] && continue

    module_name="$(initbox_module_display_name "$module_id")"
    if module_script="$(initbox_module_script_path "$profile_id" "$module_id" "$repo_root")"; then
      if [ -f "$module_script" ]; then
        printf '  [found]   %-16s %s\n' "$module_id" "$module_name"
        printf '            %s\n' "$module_script"
      else
        printf '  [missing] %-16s %s\n' "$module_id" "$module_name"
        printf '            %s\n' "$module_script"
      fi
    else
      printf '  [n/a]     %-16s %s\n' "$module_id" "$module_name"
    fi
  done < <(initbox_all_known_modules)
}
