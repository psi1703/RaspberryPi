#!/usr/bin/env bash
# InitBox GitHub-to-Pi synchronization tool.
#
# Lab-only sync from GitHub raw content into the installed InitBox runtime.
# No git checkout, no rollback, no GitHub Actions runner, no apt-get upgrade.
# Files are compared by SHA-256 and replaced atomically when content differs.

set -euo pipefail

ACTION="check"
REPOSITORY="${INITBOX_SYNC_REPOSITORY:-psi1703/RaspberryPi}"
BRANCH="${INITBOX_SYNC_BRANCH:-main}"
MANIFEST_PATH="${INITBOX_SYNC_MANIFEST_PATH:-scripts/manifest.json}"
PROFILE_OVERRIDE="${INITBOX_PROFILE_ID:-}"
STATE_DIR="${INITBOX_SYNC_STATE_DIR:-/var/lib/initbox}"
STATE_FILE="${INITBOX_SYNC_STATE_FILE:-${STATE_DIR}/sync-state.json}"
LOG_DIR="${INITBOX_SYNC_LOG_DIR:-/var/log/initbox}"
LOG_FILE="${INITBOX_SYNC_LOG_FILE:-${LOG_DIR}/sync.log}"
RUNTIME_ROOT_DEFAULT="/usr/local/share/initbox"
ASSUME_YES="0"
NO_RESTART="0"
REFRESH_CACHE="0"
DRY_RUN="0"
TMP_ROOT=""
MANIFEST_LOCAL=""
PROFILE_ID=""
HARDWARE_NAME=""
PLAN_FILE=""
UPDATE_FILE=""
RESTART_FILE=""
TOTAL_FILES=0
CHANGED_FILES=0
FIELD_SEP="|"

usage() {
  cat <<'EOF_USAGE'
Usage:
  initbox-sync.sh [check|update|refresh-cache|status] [options]

Actions:
  check           Show which runtime files would be updated.
  update          Download and atomically install changed runtime files.
  refresh-cache   Refresh the offline APT package cache for this Pi profile.
  status          Show local sync state summary.

Options:
  --profile ID        Override detected profile: pi-zero2w or pi-full.
  --repo OWNER/REPO   GitHub repository. Default: psi1703/RaspberryPi.
  --branch REF        GitHub branch/ref. Default: main.
  --manifest PATH     Manifest path in repository. Default: scripts/manifest.json.
  --yes, -y           Do not prompt before applying updates.
  --no-restart        Do not restart affected services after update.
  --refresh-cache     After update, refresh offline APT package cache.
  --dry-run           For update, show plan but do not install files.
  --help, -h          Show this help.
EOF_USAGE
}

log() { printf '[sync] %s\n' "$*"; }
warn() { printf '[sync] [WARN] %s\n' "$*" >&2; }
fail() { printf '[sync] [ERR] %s\n' "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || fail "required command not found: $1"; }

append_log() {
  printf '%s %s\n' "$(date -Is 2>/dev/null || date)" "$*" >>"$LOG_FILE" 2>/dev/null || true
}

parse_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      check|update|refresh-cache|status) ACTION="$1"; shift ;;
      --profile) [ "$#" -ge 2 ] || fail "--profile requires a value"; PROFILE_OVERRIDE="$2"; shift 2 ;;
      --repo) [ "$#" -ge 2 ] || fail "--repo requires a value"; REPOSITORY="$2"; shift 2 ;;
      --branch) [ "$#" -ge 2 ] || fail "--branch requires a value"; BRANCH="$2"; shift 2 ;;
      --manifest) [ "$#" -ge 2 ] || fail "--manifest requires a value"; MANIFEST_PATH="$2"; shift 2 ;;
      --yes|-y) ASSUME_YES="1"; shift ;;
      --no-restart) NO_RESTART="1"; shift ;;
      --refresh-cache) REFRESH_CACHE="1"; shift ;;
      --dry-run) DRY_RUN="1"; shift ;;
      --help|-h|help) usage; exit 0 ;;
      *) usage >&2; fail "unknown argument: $1" ;;
    esac
  done
}

validate_input() {
  case "$REPOSITORY" in */*) ;; *) fail "invalid repository '$REPOSITORY'; expected OWNER/REPO" ;; esac
  case "$BRANCH" in ""|*".."*|*" "*|*"~"*|*"^"*|*":"*|*"?"*|*"["*|*"\\"*) fail "unsafe branch/ref: $BRANCH" ;; esac
  case "$MANIFEST_PATH" in ""|*".."*|*" "*|*"~"*|*"^"*|*":"*|*"?"*|*"["*|*"\\"*) fail "unsafe manifest path: $MANIFEST_PATH" ;; esac
  case "$ACTION" in update|refresh-cache) [ "$(id -u)" -eq 0 ] || fail "action '$ACTION' must be run as root" ;; esac
}

prepare_dirs() {
  install -d -m 0755 "$STATE_DIR" "$LOG_DIR"
  touch "$LOG_FILE"
}

read_pi_model() {
  local model=""
  if [ -r /proc/device-tree/model ]; then
    model="$(tr -d '\000' </proc/device-tree/model 2>/dev/null || true)"
  fi
  printf '%s\n' "$model"
}

detect_profile() {
  local model=""
  if [ -n "$PROFILE_OVERRIDE" ]; then
    case "$PROFILE_OVERRIDE" in pi-zero2w|pi-full) PROFILE_ID="$PROFILE_OVERRIDE"; HARDWARE_NAME="manual profile override"; return 0 ;; esac
    fail "unsupported profile override: $PROFILE_OVERRIDE"
  fi

  model="$(read_pi_model)"
  HARDWARE_NAME="${model:-unknown hardware}"
  case "$model" in
    *"Raspberry Pi Zero 2 W"*|*"Raspberry Pi Zero W"*) PROFILE_ID="pi-zero2w" ;;
    *"Raspberry Pi 3"*|*"Raspberry Pi 4"*|*"Raspberry Pi 5"*|*"Compute Module 4"*|*"Compute Module 5"*) PROFILE_ID="pi-full" ;;
    *) fail "could not detect supported Raspberry Pi model; use --profile pi-zero2w or --profile pi-full for lab testing" ;;
  esac
}

raw_url() {
  printf 'https://raw.githubusercontent.com/%s/%s/%s\n' "$REPOSITORY" "$BRANCH" "$1"
}

download_raw() {
  local source_path="$1"
  local dest_file="$2"
  curl -fL --retry 3 --retry-delay 2 --connect-timeout 10 --max-time 240 "$(raw_url "$source_path")" -o "$dest_file"
}

fetch_manifest() {
  MANIFEST_LOCAL="${TMP_ROOT}/manifest.json"
  log "Checking Internet/GitHub raw access."
  if ! download_raw "$MANIFEST_PATH" "$MANIFEST_LOCAL" >/dev/null; then
    fail "GitHub raw content is not reachable. InitBox sync is lab-only and requires Internet access."
  fi
  python3 -m json.tool "$MANIFEST_LOCAL" >/dev/null || fail "manifest is not valid JSON: $MANIFEST_PATH"
}

manifest_value() {
  local key="$1"
  local default_value="${2:-}"
  python3 - "$MANIFEST_LOCAL" "$key" "$default_value" <<'PY'
import json, sys
with open(sys.argv[1], 'r', encoding='utf-8') as f:
    data = json.load(f)
print(data.get(sys.argv[2]) or sys.argv[3])
PY
}

manifest_entries() {
  python3 - "$MANIFEST_LOCAL" "$PROFILE_ID" "$FIELD_SEP" <<'PY'
import json, sys
manifest_path, profile, sep = sys.argv[1:4]
with open(manifest_path, 'r', encoding='utf-8') as f:
    data = json.load(f)
for item in data.get('files', []):
    profiles = item.get('profiles', ['all'])
    if 'all' not in profiles and profile not in profiles:
        continue
    fields = [
        item['source'],
        item['target'],
        item.get('mode', '0644'),
        item.get('owner', 'root'),
        item.get('group', 'root'),
        item.get('component', ''),
        ','.join(item.get('restart', [])),
    ]
    if any(sep in value for value in fields):
        raise SystemExit(f'manifest field contains reserved separator {sep!r}: {fields!r}')
    print(sep.join(fields))
PY
}

sha256_file() { sha256sum "$1" | awk '{print $1}'; }
cache_path() { printf '%s/source-%05d' "$TMP_ROOT" "$1"; }

state_lookup() {
  local source_path="$1"
  local target_path="$2"
  local field_name="$3"
  python3 - "$STATE_FILE" "$source_path" "$target_path" "$field_name" <<'PY'
import json, os, sys
state_file, source, target, field = sys.argv[1:5]
key = f'{source} -> {target}'
legacy_key = source
if not os.path.exists(state_file):
    print('')
    raise SystemExit(0)
try:
    with open(state_file, 'r', encoding='utf-8') as f:
        data = json.load(f)
except Exception:
    print('')
    raise SystemExit(0)
entry = data.get('files', {}).get(key) or data.get('files', {}).get(legacy_key, {})
print(entry.get(field) or '')
PY
}

state_update() {
  local source_path="$1"
  local target_path="$2"
  local source_hash="$3"
  local sha256_value="$4"
  python3 - "$STATE_FILE" "$source_path" "$target_path" "$source_hash" "$sha256_value" "$REPOSITORY" "$BRANCH" <<'PY'
import datetime, json, os, sys
state_file, source, target, source_hash, sha256_value, repository, branch = sys.argv[1:8]
key = f'{source} -> {target}'
try:
    with open(state_file, 'r', encoding='utf-8') as f:
        data = json.load(f)
except Exception:
    data = {}
data['repository'] = repository
data['branch'] = branch
data.setdefault('files', {})
data['files'][key] = {
    'source': source,
    'target': target,
    'source_sha': source_hash,
    'sha256': sha256_value,
    'updated_at': datetime.datetime.now(datetime.timezone.utc).isoformat(),
}
os.makedirs(os.path.dirname(state_file), exist_ok=True)
tmp = f'{state_file}.tmp'
with open(tmp, 'w', encoding='utf-8') as f:
    json.dump(data, f, indent=2, sort_keys=True)
    f.write('\n')
os.replace(tmp, state_file)
PY
}

install_file_atomic() {
  local downloaded_file="$1"
  local target_path="$2"
  local mode="$3"
  local owner="$4"
  local group="$5"
  local target_dir=""
  local target_base=""
  local tmp_target=""

  target_dir="$(dirname "$target_path")"
  target_base="$(basename "$target_path")"
  install -d -m 0755 "$target_dir"
  tmp_target="$(mktemp "${target_dir}/.${target_base}.tmp.XXXXXX")"
  install -m "$mode" "$downloaded_file" "$tmp_target"
  chown "$owner:$group" "$tmp_target" 2>/dev/null || chown root:root "$tmp_target" 2>/dev/null || true
  mv -f "$tmp_target" "$target_path"
}

entry_reason() {
  local source_path="$1"
  local target_path="$2"
  local source_hash="$3"
  local local_hash=""
  local state_hash=""

  if [ ! -f "$target_path" ]; then
    printf 'target-missing\n'
    return 0
  fi

  local_hash="$(sha256_file "$target_path")"
  if [ "$local_hash" != "$source_hash" ]; then
    state_hash="$(state_lookup "$source_path" "$target_path" sha256 || true)"
    if [ -z "$state_hash" ]; then
      printf 'content-diff\n'
    else
      printf 'source-changed\n'
    fi
    return 0
  fi

  return 1
}

collect_plan() {
  local source_path=""
  local target_path=""
  local mode=""
  local owner=""
  local group=""
  local component=""
  local restart_csv=""
  local source_hash=""
  local reason=""
  local cached_file=""
  local total=0
  local changed=0

  PLAN_FILE="${TMP_ROOT}/plan.sync"
  UPDATE_FILE="${TMP_ROOT}/updates.sync"
  RESTART_FILE="${TMP_ROOT}/restart.txt"
  : >"$PLAN_FILE"
  : >"$UPDATE_FILE"
  : >"$RESTART_FILE"

  while IFS="$FIELD_SEP" read -r source_path target_path mode owner group component restart_csv; do
    [ -n "$source_path" ] || continue
    total=$((total + 1))
    cached_file="$(cache_path "$total")"

    log "Checking: $source_path"
    if ! download_raw "$source_path" "$cached_file" >/dev/null; then
      fail "could not download repository file: $source_path"
    fi

    source_hash="$(sha256_file "$cached_file")"
    if reason="$(entry_reason "$source_path" "$target_path" "$source_hash")"; then
      changed=$((changed + 1))
      printf '%s%s%s%s%s%s%s%s%s%s%s%s%s%s%s%s%s%s%s\n' \
        "$source_path" "$FIELD_SEP" "$target_path" "$FIELD_SEP" "$mode" "$FIELD_SEP" "$owner" "$FIELD_SEP" \
        "$group" "$FIELD_SEP" "$component" "$FIELD_SEP" "$restart_csv" "$FIELD_SEP" "$source_hash" "$FIELD_SEP" \
        "$reason" "$FIELD_SEP" "$cached_file" >>"$UPDATE_FILE"
      if [ -n "$restart_csv" ]; then
        printf '%s\n' "$restart_csv" | tr ',' '\n' >>"$RESTART_FILE"
      fi
    fi

    printf '%s%s%s%s%s\n' "$source_path" "$FIELD_SEP" "$target_path" "$FIELD_SEP" "$source_hash" >>"$PLAN_FILE"
  done < <(manifest_entries)

  TOTAL_FILES="$total"
  CHANGED_FILES="$changed"
  sort -u "$RESTART_FILE" -o "$RESTART_FILE"
}

print_header() {
  cat <<EOF_HEADER
InitBox Synchronization
=======================
Repository:      $REPOSITORY
Branch:          $BRANCH
Manifest:        $MANIFEST_PATH
Hardware:        $HARDWARE_NAME
Profile:         $PROFILE_ID
Runtime root:    $(manifest_value runtime_root "$RUNTIME_ROOT_DEFAULT")
State file:      $STATE_FILE
EOF_HEADER
}

print_plan() {
  local source_path=""
  local target_path=""
  local mode=""
  local owner=""
  local group=""
  local component=""
  local restart_csv=""
  local source_hash=""
  local reason=""
  local cached_file=""
  local service=""

  echo
  echo "Sync plan"
  echo "---------"
  echo "Tracked files: $TOTAL_FILES"
  echo "Files needing update: $CHANGED_FILES"

  if [ "$CHANGED_FILES" -eq 0 ]; then
    echo
    echo "Everything is already up to date."
    return 0
  fi

  echo
  echo "Files to update:"
  while IFS="$FIELD_SEP" read -r source_path target_path mode owner group component restart_csv source_hash reason cached_file; do
    [ -n "$source_path" ] || continue
    printf '  - %s -> %s (%s)\n' "$source_path" "$target_path" "$reason"
  done <"$UPDATE_FILE"

  if [ -s "$RESTART_FILE" ] && [ "$NO_RESTART" != "1" ]; then
    echo
    echo "Services to restart if installed:"
    while IFS= read -r service; do
      [ -n "$service" ] || continue
      printf '  - %s\n' "$service"
    done <"$RESTART_FILE"
  fi
}

confirm_update() {
  local answer=""
  [ "$ASSUME_YES" = "1" ] && return 0
  echo
  printf 'Proceed with update? [Y/n]: '
  read -r answer || answer=""
  case "$answer" in ""|y|Y|yes|YES) return 0 ;; *) echo "Update cancelled."; exit 0 ;; esac
}

apply_updates() {
  local source_path=""
  local target_path=""
  local mode=""
  local owner=""
  local group=""
  local component=""
  local restart_csv=""
  local source_hash=""
  local reason=""
  local cached_file=""
  local installed_hash=""

  [ "$CHANGED_FILES" -eq 0 ] && return 0
  if [ "$DRY_RUN" = "1" ]; then
    echo
    echo "Dry run selected; no files installed."
    return 0
  fi

  while IFS="$FIELD_SEP" read -r source_path target_path mode owner group component restart_csv source_hash reason cached_file; do
    [ -n "$source_path" ] || continue
    [ -n "$cached_file" ] || fail "internal plan error: missing cached file path for: $source_path"
    [ -f "$cached_file" ] || fail "cached download disappeared for: $source_path"
    [ "$(sha256_file "$cached_file")" = "$source_hash" ] || fail "cached download SHA256 changed unexpectedly: $source_path"

    log "Installing: $target_path"
    install_file_atomic "$cached_file" "$target_path" "$mode" "$owner" "$group"
    installed_hash="$(sha256_file "$target_path")"
    [ "$installed_hash" = "$source_hash" ] || fail "post-install SHA256 verification failed: $target_path"
    state_update "$source_path" "$target_path" "$source_hash" "$installed_hash"
    append_log "updated source=$source_path target=$target_path sha256=$installed_hash"
  done <"$UPDATE_FILE"
}

restart_services() {
  local service=""
  [ "$NO_RESTART" = "1" ] && { log "Service restart skipped by --no-restart."; return 0; }
  [ -s "$RESTART_FILE" ] || return 0
  command -v systemctl >/dev/null 2>&1 || { warn "systemctl unavailable; skipping service restarts"; return 0; }

  echo
  echo "Restarting affected services"
  echo "----------------------------"
  while IFS= read -r service; do
    [ -n "$service" ] || continue
    if systemctl cat "$service" >/dev/null 2>&1; then
      log "Restarting $service"
      if systemctl restart "$service"; then
        append_log "restarted service=$service"
      else
        warn "failed to restart $service"
      fi
    else
      log "Service not installed; skipping $service"
    fi
  done <"$RESTART_FILE"
}

refresh_package_cache() {
  local helper="/usr/local/share/initbox/scripts/lib/packages.sh"
  [ -f "$helper" ] || helper="$(pwd)/scripts/lib/packages.sh"
  [ -f "$helper" ] || fail "package helper not found; run update first or provide repository working tree"
  echo
  echo "Refreshing offline package cache"
  echo "--------------------------------"
  echo "Profile: $PROFILE_ID"
  echo "Helper:  $helper"
  bash "$helper" preseed "$PROFILE_ID"
  append_log "refreshed package cache profile=$PROFILE_ID"
}

show_status() {
  echo "InitBox sync status"
  echo "==================="
  echo "State file: $STATE_FILE"
  echo
  [ -f "$STATE_FILE" ] || { echo "No sync state recorded yet."; return 0; }
  python3 - "$STATE_FILE" <<'PY'
import json, sys
with open(sys.argv[1], 'r', encoding='utf-8') as f:
    data = json.load(f)
print(f"Repository: {data.get('repository', '')}")
print(f"Branch:     {data.get('branch', '')}")
print()
files = data.get('files', {})
print(f"Tracked installed files: {len(files)}")
for key in sorted(files):
    entry = files[key]
    print(f"- {entry.get('source', key)}")
    print(f"  target: {entry.get('target', '')}")
    print(f"  sha256: {entry.get('sha256', '')}")
    print(f"  updated_at: {entry.get('updated_at', '')}")
PY
}

main() {
  local manifest_repo=""
  local manifest_branch=""

  parse_args "$@"
  validate_input
  need curl
  need python3
  need sha256sum
  TMP_ROOT="$(mktemp -d)"
  trap 'rm -rf "$TMP_ROOT"' EXIT

  if [ "$ACTION" = "status" ]; then
    show_status
    exit 0
  fi

  detect_profile
  prepare_dirs

  if [ "$ACTION" = "refresh-cache" ]; then
    refresh_package_cache
    exit 0
  fi

  fetch_manifest
  manifest_repo="$(manifest_value repository)"
  manifest_branch="$(manifest_value branch)"
  [ -z "$manifest_repo" ] || [ "$manifest_repo" = "$REPOSITORY" ] || warn "manifest repository is '$manifest_repo' but sync is using '$REPOSITORY'"
  [ -z "$manifest_branch" ] || [ "$manifest_branch" = "$BRANCH" ] || warn "manifest branch is '$manifest_branch' but sync is using '$BRANCH'"

  print_header
  collect_plan
  print_plan

  if [ "$ACTION" = "check" ]; then
    exit 0
  fi
  [ "$ACTION" = "update" ] || fail "unsupported action: $ACTION"

  confirm_update
  apply_updates
  restart_services
  [ "$REFRESH_CACHE" = "1" ] && refresh_package_cache
  echo
  echo "Synchronization complete."
}

main "$@"
