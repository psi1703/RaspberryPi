#!/usr/bin/env bash
# InitBox GitHub-to-Pi synchronization tool.
#
# Lab-only tool. It synchronizes runtime files from GitHub main into the
# installed InitBox layout:
#   executables:       /usr/local/bin
#   shared runtime:    /usr/local/share/initbox
#   config:            /etc/initbox
#   state:             /var/lib/initbox
#   logs:              /var/log/initbox
#
# It does not use git. It does not provide rollback. It only replaces files
# whose GitHub source or local installed content differs.

set -euo pipefail

ACTION="check"
REPOSITORY="${INITBOX_SYNC_REPOSITORY:-psi1703/RaspberryPi}"
BRANCH="${INITBOX_SYNC_BRANCH:-main}"
MANIFEST_PATH="${INITBOX_SYNC_MANIFEST_PATH:-scripts/manifest.json}"
PROFILE_OVERRIDE="${INITBOX_PROFILE_ID:-}"
ASSUME_YES="0"
NO_RESTART="0"
REFRESH_CACHE="0"
DRY_RUN="0"
MANIFEST_LOCAL=""
RUNTIME_ROOT_DEFAULT="/usr/local/share/initbox"
STATE_DIR="${INITBOX_SYNC_STATE_DIR:-/var/lib/initbox}"
STATE_FILE="${INITBOX_SYNC_STATE_FILE:-${STATE_DIR}/sync-state.json}"
LOG_DIR="${INITBOX_SYNC_LOG_DIR:-/var/log/initbox}"
LOG_FILE="${INITBOX_SYNC_LOG_FILE:-${LOG_DIR}/sync.log}"
TMP_ROOT=""
PROFILE_ID=""
HARDWARE_NAME=""

usage() {
  cat <<'EOF_USAGE'
Usage:
  initbox-sync.sh [check|update|refresh-cache|status] [options]

Actions:
  check           Show which files would be updated. This is the default.
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

Notes:
  - This is a lab-only tool. It requires Internet access.
  - It does not run git.
  - It does not run apt-get upgrade.
  - It only refreshes the package cache when requested.
EOF_USAGE
}

log_line() {
  printf '[sync] %s\n' "$*"
}

warn_line() {
  printf '[sync] [WARN] %s\n' "$*" >&2
}

err_line() {
  printf '[sync] [ERR] %s\n' "$*" >&2
}

fail() {
  err_line "$*"
  exit 1
}

need_command() {
  command -v "$1" >/dev/null 2>&1 || fail "required command not found: $1"
}

require_root_for_write() {
  case "$ACTION" in
    update|refresh-cache)
      if [ "$(id -u)" -ne 0 ]; then
        fail "action '$ACTION' must be run as root"
      fi
      ;;
  esac
}

prepare_runtime_dirs() {
  install -d -m 0755 "$STATE_DIR"
  install -d -m 0755 "$LOG_DIR"
  touch "$LOG_FILE"
}

append_log_file() {
  printf '%s %s\n' "$(date -Is 2>/dev/null || date)" "$*" >>"$LOG_FILE" 2>/dev/null || true
}

parse_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      check|update|refresh-cache|status)
        ACTION="$1"
        shift
        ;;
      --profile)
        [ "$#" -ge 2 ] || fail "--profile requires a value"
        PROFILE_OVERRIDE="$2"
        shift 2
        ;;
      --repo)
        [ "$#" -ge 2 ] || fail "--repo requires a value"
        REPOSITORY="$2"
        shift 2
        ;;
      --branch)
        [ "$#" -ge 2 ] || fail "--branch requires a value"
        BRANCH="$2"
        shift 2
        ;;
      --manifest)
        [ "$#" -ge 2 ] || fail "--manifest requires a value"
        MANIFEST_PATH="$2"
        shift 2
        ;;
      --yes|-y)
        ASSUME_YES="1"
        shift
        ;;
      --no-restart)
        NO_RESTART="1"
        shift
        ;;
      --refresh-cache)
        REFRESH_CACHE="1"
        shift
        ;;
      --dry-run)
        DRY_RUN="1"
        shift
        ;;
      --help|-h|help)
        usage
        exit 0
        ;;
      *)
        usage >&2
        fail "unknown argument: $1"
        ;;
    esac
  done
}

validate_repository() {
  case "$REPOSITORY" in
    */*)
      ;;
    *)
      fail "invalid repository '$REPOSITORY'; expected OWNER/REPO"
      ;;
  esac
}

validate_profile_id() {
  case "$1" in
    pi-zero2w|pi-full)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

read_pi_model() {
  local model_file="/proc/device-tree/model"
  local model=""

  if [ -r "$model_file" ]; then
    model="$(tr -d '\000' <"$model_file" 2>/dev/null || true)"
  fi

  printf '%s\n' "$model"
}

detect_profile() {
  local model=""

  if [ -n "$PROFILE_OVERRIDE" ]; then
    validate_profile_id "$PROFILE_OVERRIDE" || fail "unsupported profile override: $PROFILE_OVERRIDE"
    PROFILE_ID="$PROFILE_OVERRIDE"
    HARDWARE_NAME="manual profile override"
    return 0
  fi

  model="$(read_pi_model)"
  HARDWARE_NAME="${model:-unknown hardware}"

  case "$model" in
    *"Raspberry Pi Zero 2 W"*|*"Raspberry Pi Zero W"*)
      PROFILE_ID="pi-zero2w"
      ;;
    *"Raspberry Pi 3"*|*"Raspberry Pi 4"*|*"Raspberry Pi 5"*|*"Compute Module 4"*|*"Compute Module 5"*)
      PROFILE_ID="pi-full"
      ;;
    *)
      fail "could not detect supported Raspberry Pi model; use --profile pi-zero2w or --profile pi-full for lab testing"
      ;;
  esac
}

internet_check() {
  log_line "Checking Internet/GitHub access."
  if ! curl -fsSL --connect-timeout 8 --max-time 20 "https://api.github.com/repos/${REPOSITORY}" >/dev/null; then
    fail "GitHub is not reachable. InitBox sync is lab-only and requires Internet access."
  fi
}

api_contents_url() {
  local path="$1"
  printf 'https://api.github.com/repos/%s/contents/%s?ref=%s\n' "$REPOSITORY" "$path" "$BRANCH"
}

fetch_metadata() {
  local path="$1"
  local out_file="$2"
  local url=""

  url="$(api_contents_url "$path")"
  if ! curl -fsSL --connect-timeout 8 --max-time 60 \
    -H 'Accept: application/vnd.github+json' \
    "$url" -o "$out_file"; then
    return 1
  fi
}

metadata_field() {
  local metadata_file="$1"
  local field_name="$2"

  python3 - "$metadata_file" "$field_name" <<'PY'
import json
import sys

with open(sys.argv[1], 'r', encoding='utf-8') as handle:
    data = json.load(handle)

if isinstance(data, list):
    raise SystemExit(2)

value = data.get(sys.argv[2], '')
if value is None:
    value = ''
print(value)
PY
}

download_repo_file() {
  local source_path="$1"
  local dest_file="$2"
  local metadata_file=""
  local download_url=""

  metadata_file="${TMP_ROOT}/metadata-$(printf '%s' "$source_path" | tr '/ ' '__').json"
  if ! fetch_metadata "$source_path" "$metadata_file"; then
    fail "could not read GitHub metadata for: $source_path"
  fi

  download_url="$(metadata_field "$metadata_file" download_url)"
  [ -n "$download_url" ] || fail "GitHub metadata did not contain a download URL for: $source_path"

  if ! curl -fL --connect-timeout 8 --max-time 180 "$download_url" -o "$dest_file"; then
    fail "could not download repository file: $source_path"
  fi
}

fetch_manifest() {
  local tmp_manifest=""

  tmp_manifest="${TMP_ROOT}/manifest.json"
  log_line "Fetching manifest: ${REPOSITORY}@${BRANCH}:${MANIFEST_PATH}"
  download_repo_file "$MANIFEST_PATH" "$tmp_manifest"

  python3 -m json.tool "$tmp_manifest" >/dev/null || fail "manifest is not valid JSON: $MANIFEST_PATH"
  MANIFEST_LOCAL="$tmp_manifest"
}

manifest_repository() {
  python3 - "$MANIFEST_LOCAL" <<'PY'
import json, sys
with open(sys.argv[1], 'r', encoding='utf-8') as handle:
    data = json.load(handle)
print(data.get('repository', ''))
PY
}

manifest_branch() {
  python3 - "$MANIFEST_LOCAL" <<'PY'
import json, sys
with open(sys.argv[1], 'r', encoding='utf-8') as handle:
    data = json.load(handle)
print(data.get('branch', ''))
PY
}

manifest_runtime_root() {
  python3 - "$MANIFEST_LOCAL" "$RUNTIME_ROOT_DEFAULT" <<'PY'
import json, sys
with open(sys.argv[1], 'r', encoding='utf-8') as handle:
    data = json.load(handle)
print(data.get('runtime_root') or sys.argv[2])
PY
}

manifest_entries() {
  local profile_id="$1"

  python3 - "$MANIFEST_LOCAL" "$profile_id" <<'PY'
import json
import sys

manifest_path = sys.argv[1]
profile = sys.argv[2]

with open(manifest_path, 'r', encoding='utf-8') as handle:
    data = json.load(handle)

for item in data.get('files', []):
    profiles = item.get('profiles', ['all'])
    if 'all' not in profiles and profile not in profiles:
        continue

    source = item['source']
    target = item['target']
    mode = item.get('mode', '0644')
    owner = item.get('owner', 'root')
    group = item.get('group', 'root')
    component = item.get('component', '')
    restart = ','.join(item.get('restart', []))
    print('\t'.join([source, target, mode, owner, group, component, restart]))
PY
}

sha256_file() {
  local path="$1"
  sha256sum "$path" | awk '{print $1}'
}

state_lookup() {
  local source_path="$1"
  local field_name="$2"

  python3 - "$STATE_FILE" "$source_path" "$field_name" <<'PY'
import json
import os
import sys

state_file, source, field = sys.argv[1:4]
if not os.path.exists(state_file):
    print('')
    raise SystemExit(0)

try:
    with open(state_file, 'r', encoding='utf-8') as handle:
        data = json.load(handle)
except Exception:
    print('')
    raise SystemExit(0)

entry = data.get('files', {}).get(source, {})
value = entry.get(field, '')
if value is None:
    value = ''
print(value)
PY
}

state_update() {
  local source_path="$1"
  local target_path="$2"
  local remote_sha="$3"
  local sha256_value="$4"

  install -d -m 0755 "$STATE_DIR"
  python3 - "$STATE_FILE" "$source_path" "$target_path" "$remote_sha" "$sha256_value" "$REPOSITORY" "$BRANCH" <<'PY'
import datetime
import json
import os
import sys

state_file, source, target, remote_sha, sha256_value, repository, branch = sys.argv[1:8]

try:
    with open(state_file, 'r', encoding='utf-8') as handle:
        data = json.load(handle)
except Exception:
    data = {}

data.setdefault('repository', repository)
data['repository'] = repository
data['branch'] = branch
data.setdefault('files', {})
data['files'][source] = {
    'target': target,
    'source_sha': remote_sha,
    'sha256': sha256_value,
    'updated_at': datetime.datetime.now(datetime.timezone.utc).isoformat(),
}

tmp_file = f'{state_file}.tmp'
os.makedirs(os.path.dirname(state_file), exist_ok=True)
with open(tmp_file, 'w', encoding='utf-8') as handle:
    json.dump(data, handle, indent=2, sort_keys=True)
    handle.write('\n')
os.replace(tmp_file, state_file)
PY
}

metadata_sha_for_source() {
  local source_path="$1"
  local metadata_file=""

  metadata_file="${TMP_ROOT}/meta-$(printf '%s' "$source_path" | tr '/ ' '__').json"
  if ! fetch_metadata "$source_path" "$metadata_file"; then
    fail "could not fetch GitHub metadata for: $source_path"
  fi
  metadata_field "$metadata_file" sha
}

metadata_download_url_for_source() {
  local source_path="$1"
  local metadata_file=""

  metadata_file="${TMP_ROOT}/meta-$(printf '%s' "$source_path" | tr '/ ' '__').json"
  if [ ! -f "$metadata_file" ]; then
    if ! fetch_metadata "$source_path" "$metadata_file"; then
      fail "could not fetch GitHub metadata for: $source_path"
    fi
  fi
  metadata_field "$metadata_file" download_url
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

entry_needs_update() {
  local source_path="$1"
  local target_path="$2"
  local remote_sha="$3"
  local state_source_sha=""
  local state_sha256=""
  local local_sha256=""

  if [ ! -f "$target_path" ]; then
    printf 'target-missing\n'
    return 0
  fi

  state_source_sha="$(state_lookup "$source_path" source_sha)"
  state_sha256="$(state_lookup "$source_path" sha256)"
  local_sha256="$(sha256_file "$target_path")"

  if [ -z "$state_source_sha" ] || [ -z "$state_sha256" ]; then
    printf 'untracked\n'
    return 0
  fi

  if [ "$local_sha256" != "$state_sha256" ]; then
    printf 'local-drift\n'
    return 0
  fi

  if [ "$remote_sha" != "$state_source_sha" ]; then
    printf 'source-changed\n'
    return 0
  fi

  return 1
}

write_plan_files() {
  PLAN_FILE="${TMP_ROOT}/plan.tsv"
  UPDATE_FILE="${TMP_ROOT}/updates.tsv"
  RESTART_FILE="${TMP_ROOT}/restart.txt"
  : >"$PLAN_FILE"
  : >"$UPDATE_FILE"
  : >"$RESTART_FILE"
}

collect_plan() {
  local source_path=""
  local target_path=""
  local mode=""
  local owner=""
  local group=""
  local component=""
  local restart_csv=""
  local remote_sha=""
  local reason=""
  local total=0
  local changed=0

  write_plan_files

  while IFS=$'\t' read -r source_path target_path mode owner group component restart_csv; do
    [ -n "$source_path" ] || continue
    total=$((total + 1))

    remote_sha="$(metadata_sha_for_source "$source_path")"
    reason=""
    if reason="$(entry_needs_update "$source_path" "$target_path" "$remote_sha")"; then
      changed=$((changed + 1))
      printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$source_path" "$target_path" "$mode" "$owner" "$group" "$component" "$restart_csv" "$remote_sha" "$reason" >>"$UPDATE_FILE"
      if [ -n "$restart_csv" ]; then
        printf '%s\n' "$restart_csv" | tr ',' '\n' >>"$RESTART_FILE"
      fi
    fi

    printf '%s\t%s\t%s\n' "$source_path" "$target_path" "$remote_sha" >>"$PLAN_FILE"
  done < <(manifest_entries "$PROFILE_ID")

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
Runtime root:    $(manifest_runtime_root)
State file:      $STATE_FILE
EOF_HEADER
}

print_plan_summary() {
  local source_path=""
  local target_path=""
  local mode=""
  local owner=""
  local group=""
  local component=""
  local restart_csv=""
  local remote_sha=""
  local reason=""
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
  while IFS=$'\t' read -r source_path target_path mode owner group component restart_csv remote_sha reason; do
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

  if [ "$ASSUME_YES" = "1" ]; then
    return 0
  fi

  echo
  printf 'Proceed with update? [Y/n]: '
  read -r answer || answer=""
  case "$answer" in
    ""|y|Y|yes|YES)
      return 0
      ;;
    *)
      echo "Update cancelled."
      exit 0
      ;;
  esac
}

apply_updates() {
  local source_path=""
  local target_path=""
  local mode=""
  local owner=""
  local group=""
  local component=""
  local restart_csv=""
  local remote_sha=""
  local reason=""
  local download_url=""
  local downloaded_file=""
  local sha256_value=""
  local count=0

  if [ "$CHANGED_FILES" -eq 0 ]; then
    return 0
  fi

  if [ "$DRY_RUN" = "1" ]; then
    echo
    echo "Dry run selected; no files installed."
    return 0
  fi

  while IFS=$'\t' read -r source_path target_path mode owner group component restart_csv remote_sha reason; do
    [ -n "$source_path" ] || continue
    count=$((count + 1))
    downloaded_file="${TMP_ROOT}/download-${count}"

    log_line "Downloading: $source_path"
    download_url="$(metadata_download_url_for_source "$source_path")"
    [ -n "$download_url" ] || fail "missing download URL for: $source_path"

    if ! curl -fL --connect-timeout 8 --max-time 240 "$download_url" -o "$downloaded_file"; then
      fail "download failed: $source_path"
    fi

    sha256_value="$(sha256_file "$downloaded_file")"
    log_line "Installing: $target_path"
    install_file_atomic "$downloaded_file" "$target_path" "$mode" "$owner" "$group"

    if [ "$(sha256_file "$target_path")" != "$sha256_value" ]; then
      fail "post-install SHA256 verification failed: $target_path"
    fi

    state_update "$source_path" "$target_path" "$remote_sha" "$sha256_value"
    append_log_file "updated source=$source_path target=$target_path sha256=$sha256_value"
  done <"$UPDATE_FILE"
}

restart_services() {
  local service=""

  if [ "$NO_RESTART" = "1" ]; then
    log_line "Service restart skipped by --no-restart."
    return 0
  fi

  if [ ! -s "$RESTART_FILE" ]; then
    return 0
  fi

  if ! command -v systemctl >/dev/null 2>&1; then
    warn_line "systemctl is unavailable; skipping service restarts"
    return 0
  fi

  echo
  echo "Restarting affected services"
  echo "----------------------------"

  while IFS= read -r service; do
    [ -n "$service" ] || continue

    if systemctl cat "$service" >/dev/null 2>&1; then
      log_line "Restarting $service"
      if systemctl restart "$service"; then
        log_line "Restarted $service"
        append_log_file "restarted service=$service"
      else
        warn_line "failed to restart $service"
      fi
    else
      log_line "Service not installed; skipping $service"
    fi
  done <"$RESTART_FILE"
}

refresh_package_cache() {
  local helper=""

  internet_check

  helper="/usr/local/share/initbox/scripts/lib/packages.sh"
  if [ ! -f "$helper" ]; then
    helper="$(pwd)/scripts/lib/packages.sh"
  fi

  if [ ! -f "$helper" ]; then
    fail "package helper not found; run update first or provide repository working tree"
  fi

  echo
  echo "Refreshing offline package cache"
  echo "--------------------------------"
  echo "Profile: $PROFILE_ID"
  echo "Helper:  $helper"

  bash "$helper" preseed "$PROFILE_ID"
  append_log_file "refreshed package cache profile=$PROFILE_ID"
}

show_status() {
  echo "InitBox sync status"
  echo "==================="
  echo "State file: $STATE_FILE"
  echo

  if [ ! -f "$STATE_FILE" ]; then
    echo "No sync state recorded yet."
    return 0
  fi

  python3 - "$STATE_FILE" <<'PY'
import json
import sys

with open(sys.argv[1], 'r', encoding='utf-8') as handle:
    data = json.load(handle)

print(f"Repository: {data.get('repository', '')}")
print(f"Branch:     {data.get('branch', '')}")
print()
files = data.get('files', {})
print(f"Tracked installed files: {len(files)}")
for source in sorted(files):
    entry = files[source]
    print(f"- {source}")
    print(f"  target: {entry.get('target', '')}")
    print(f"  sha256: {entry.get('sha256', '')}")
    print(f"  updated_at: {entry.get('updated_at', '')}")
PY
}

main() {
  parse_args "$@"
  validate_repository
  need_command curl
  need_command python3
  need_command sha256sum
  require_root_for_write

  TMP_ROOT="$(mktemp -d)"
  trap 'rm -rf "$TMP_ROOT"' EXIT

  if [ "$ACTION" = "status" ]; then
    show_status
    exit 0
  fi

  detect_profile
  prepare_runtime_dirs
  internet_check
  fetch_manifest

  local_manifest_repo="$(manifest_repository)"
  local_manifest_branch="$(manifest_branch)"

  if [ -n "$local_manifest_repo" ] && [ "$local_manifest_repo" != "$REPOSITORY" ]; then
    warn_line "manifest repository is '$local_manifest_repo' but sync is using '$REPOSITORY'"
  fi

  if [ -n "$local_manifest_branch" ] && [ "$local_manifest_branch" != "$BRANCH" ]; then
    warn_line "manifest branch is '$local_manifest_branch' but sync is using '$BRANCH'"
  fi

  if [ "$ACTION" = "refresh-cache" ]; then
    print_header
    refresh_package_cache
    exit 0
  fi

  print_header
  collect_plan
  print_plan_summary

  if [ "$ACTION" = "check" ]; then
    exit 0
  fi

  if [ "$ACTION" != "update" ]; then
    fail "unsupported action: $ACTION"
  fi

  confirm_update
  apply_updates
  restart_services

  if [ "$REFRESH_CACHE" = "1" ]; then
    refresh_package_cache
  fi

  echo
  echo "Synchronization complete."
}

main "$@"
