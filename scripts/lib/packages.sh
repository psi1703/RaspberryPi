#!/usr/bin/env bash
# InitBox unified package-cache helper.
#
# This file may be sourced by module/installer scripts or executed directly.
#
# Policy:
#   - apt-get only for Debian package operations.
#   - Never run apt-get upgrade, dist-upgrade, or full-upgrade.
#   - Package requests are validated against a hardware-profile allow-list.
#   - Already installed packages are reused.
#   - Existing local cache is tried before network access.
#   - If cache is incomplete, apt-get update/download is attempted and the
#     downloaded packages are retained for later field use.
#   - Offline installs use apt-get --no-download and fail cleanly if the cache
#     cannot satisfy the requested package set.
#
# Profile package lists:
#   scripts/packages/pi-zero2w.txt
#   scripts/packages/pi-full.txt

set -euo pipefail

: "${INITBOX_PACKAGE_CACHE_ROOT:=/opt/initbox/packages}"
: "${INITBOX_APT_CACHE_DIR:=${INITBOX_PACKAGE_CACHE_ROOT}/apt}"

initbox_packages_log() {
  printf '[packages] %s\n' "$*"
}

initbox_packages_warn() {
  printf '[packages] [WARN] %s\n' "$*" >&2
}

initbox_packages_error() {
  printf '[packages] [ERR] %s\n' "$*" >&2
}

initbox_packages_require_root() {
  if [ "$(id -u)" -ne 0 ]; then
    initbox_packages_error "package operation must run as root"
    return 1
  fi
}

initbox_packages_repo_root() {
  local source_dir=""

  source_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  cd "$source_dir/../.." && pwd
}

initbox_packages_list_for_profile() {
  local profile_id="$1"
  local repo_root="${2:-}"

  if [ -z "$repo_root" ]; then
    repo_root="$(initbox_packages_repo_root)"
  fi

  case "$profile_id" in
    pi-zero2w|pi-full)
      printf '%s/scripts/packages/%s.txt\n' "$repo_root" "$profile_id"
      ;;
    *)
      initbox_packages_error "unsupported package profile: $profile_id"
      return 1
      ;;
  esac
}

initbox_packages_require_file() {
  local packages_file="$1"

  if [ ! -f "$packages_file" ]; then
    initbox_packages_error "package allow-list does not exist: $packages_file"
    return 1
  fi
}

initbox_packages_read_list() {
  local packages_file="$1"

  initbox_packages_require_file "$packages_file"

  grep -Ev '^[[:space:]]*($|#)' "$packages_file" \
    | sed 's/[[:space:]]*#.*$//' \
    | awk '{$1=$1; print}' \
    | grep -Ev '^[[:space:]]*$' \
    | sort -u
}

initbox_packages_count_list() {
  local packages_file="$1"

  initbox_packages_read_list "$packages_file" | wc -l | tr -d '[:space:]'
}

initbox_packages_name_valid() {
  local package_name="$1"

  case "$package_name" in
    ""|*[!a-zA-Z0-9.+_-]*)
      return 1
      ;;
    *)
      return 0
      ;;
  esac
}

initbox_packages_validate_list() {
  local packages_file="$1"
  local package_name=""
  local failures=0

  initbox_packages_require_file "$packages_file"

  while IFS= read -r package_name; do
    [ -z "$package_name" ] && continue

    if ! initbox_packages_name_valid "$package_name"; then
      initbox_packages_error "invalid package name in $packages_file: $package_name"
      failures=$((failures + 1))
    fi
  done < <(initbox_packages_read_list "$packages_file")

  [ "$failures" -eq 0 ]
}

initbox_packages_name_allowed() {
  local packages_file="$1"
  local wanted_package="$2"
  local package_name=""

  while IFS= read -r package_name; do
    if [ "$package_name" = "$wanted_package" ]; then
      return 0
    fi
  done < <(initbox_packages_read_list "$packages_file")

  return 1
}

initbox_packages_validate_requested() {
  local packages_file="$1"
  shift

  local package_name=""
  local failures=0

  if [ "$#" -eq 0 ]; then
    initbox_packages_error "no package names were requested"
    return 1
  fi

  initbox_packages_validate_list "$packages_file"

  for package_name in "$@"; do
    if ! initbox_packages_name_valid "$package_name"; then
      initbox_packages_error "invalid requested package name: $package_name"
      failures=$((failures + 1))
      continue
    fi

    if ! initbox_packages_name_allowed "$packages_file" "$package_name"; then
      initbox_packages_error "package is not allowed by $packages_file: $package_name"
      failures=$((failures + 1))
    fi
  done

  [ "$failures" -eq 0 ]
}

initbox_packages_is_installed() {
  local package_name="$1"

  dpkg-query -W -f='${db:Status-Abbrev}' "$package_name" 2>/dev/null | grep -q '^ii '
}

initbox_packages_prepare_cache_dir() {
  local cache_dir="$1"

  install -d -m 0755 "$cache_dir"
  install -d -m 0755 "$cache_dir/partial"
}

initbox_packages_cache_deb_count() {
  local cache_dir="$1"

  if [ ! -d "$cache_dir" ]; then
    printf '0\n'
    return 0
  fi

  find "$cache_dir" -maxdepth 1 -type f -name '*.deb' | wc -l | tr -d '[:space:]'
}

initbox_packages_cached_direct_deb_exists() {
  local cache_dir="$1"
  local package_name="$2"

  find "$cache_dir" -maxdepth 1 -type f -name "${package_name}_*.deb" -print -quit 2>/dev/null | grep -q .
}

initbox_packages_collect_missing() {
  local package_name=""

  for package_name in "$@"; do
    if initbox_packages_is_installed "$package_name"; then
      initbox_packages_log "[SKIP] already installed: $package_name" >&2
    else
      printf '%s\n' "$package_name"
    fi
  done
}

initbox_packages_apt_update() {
  initbox_packages_log "Running apt-get update."
  DEBIAN_FRONTEND=noninteractive \
    apt-get \
      -o Dpkg::Use-Pty=0 \
      -o Acquire::Retries=5 \
      update
}

initbox_packages_download_to_cache() {
  local cache_dir="$1"
  shift

  if [ "$#" -eq 0 ]; then
    return 0
  fi

  initbox_packages_require_root
  initbox_packages_prepare_cache_dir "$cache_dir"
  initbox_packages_apt_update

  initbox_packages_log "Downloading requested packages and dependencies into: $cache_dir"
  printf '  %s\n' "$@"

  DEBIAN_FRONTEND=noninteractive \
    apt-get \
      -o Dpkg::Use-Pty=0 \
      -o Acquire::Retries=5 \
      -o "Dir::Cache::Archives=$cache_dir" \
      --download-only \
      install -y "$@"
}

initbox_packages_install_from_cache_only() {
  local cache_dir="$1"
  shift

  local deb_count=""

  if [ "$#" -eq 0 ]; then
    return 0
  fi

  initbox_packages_require_root
  initbox_packages_prepare_cache_dir "$cache_dir"

  deb_count="$(initbox_packages_cache_deb_count "$cache_dir")"
  if [ "$deb_count" -eq 0 ]; then
    initbox_packages_error "offline package cache is missing or empty: $cache_dir"
    return 1
  fi

  initbox_packages_log "Trying local-cache-only package installation."
  initbox_packages_log "Cache: $cache_dir"
  initbox_packages_log "Cached .deb files: $deb_count"
  printf '  %s\n' "$@"

  DEBIAN_FRONTEND=noninteractive \
    apt-get \
      -o Dpkg::Use-Pty=0 \
      -o Acquire::Retries=0 \
      -o "Dir::Cache::Archives=$cache_dir" \
      --no-download \
      install -y "$@"
}

initbox_packages_install() {
  local packages_file="$1"
  local cache_dir="$2"
  shift 2

  local requested_packages=()
  local missing_packages=()

  initbox_packages_require_root
  initbox_packages_require_file "$packages_file"

  if [ "$#" -eq 0 ]; then
    initbox_packages_error "no package names were requested"
    return 1
  fi

  requested_packages=("$@")
  initbox_packages_validate_requested "$packages_file" "${requested_packages[@]}"

  initbox_packages_log "Checking requested packages."
  mapfile -t missing_packages < <(initbox_packages_collect_missing "${requested_packages[@]}")

  if [ "${#missing_packages[@]}" -eq 0 ]; then
    initbox_packages_log "All requested packages are already installed."
    return 0
  fi

  initbox_packages_log "Missing packages: ${missing_packages[*]}"

  if [ "$(initbox_packages_cache_deb_count "$cache_dir")" -gt 0 ]; then
    if initbox_packages_install_from_cache_only "$cache_dir" "${missing_packages[@]}"; then
      initbox_packages_log "Missing packages installed from local cache."
      return 0
    fi

    initbox_packages_warn "Local cache could not satisfy the complete request; trying online refresh."
  else
    initbox_packages_log "Package cache is missing or empty; trying online download."
  fi

  if ! initbox_packages_download_to_cache "$cache_dir" "${missing_packages[@]}"; then
    initbox_packages_error "could not download/cache the missing packages"
    initbox_packages_error "If this Pi is offline, prepare and verify its profile cache in the lab first."
    return 1
  fi

  if ! initbox_packages_install_from_cache_only "$cache_dir" "${missing_packages[@]}"; then
    initbox_packages_error "download completed but cached installation still failed"
    return 1
  fi

  initbox_packages_log "Missing packages installed after online cache refresh."
}

initbox_packages_install_for_profile() {
  local profile_id="$1"
  shift

  local packages_file=""

  packages_file="$(initbox_packages_list_for_profile "$profile_id")"
  initbox_packages_install "$packages_file" "$INITBOX_APT_CACHE_DIR" "$@"
}

initbox_packages_preseed() {
  local packages_file="$1"
  local cache_dir="$2"

  local package_count=""
  local packages=()

  initbox_packages_require_root
  initbox_packages_require_file "$packages_file"
  initbox_packages_validate_list "$packages_file"

  package_count="$(initbox_packages_count_list "$packages_file")"
  if [ "$package_count" -eq 0 ]; then
    initbox_packages_error "package allow-list is empty: $packages_file"
    return 1
  fi

  mapfile -t packages < <(initbox_packages_read_list "$packages_file")

  initbox_packages_log "Preparing package cache."
  initbox_packages_log "Allow-list: $packages_file"
  initbox_packages_log "Cache:      $cache_dir"
  initbox_packages_log "Packages:   $package_count"

  initbox_packages_download_to_cache "$cache_dir" "${packages[@]}"

  initbox_packages_log "Package cache preparation complete."
}

initbox_packages_preseed_for_profile() {
  local profile_id="$1"
  local packages_file=""

  packages_file="$(initbox_packages_list_for_profile "$profile_id")"
  initbox_packages_preseed "$packages_file" "$INITBOX_APT_CACHE_DIR"
}

initbox_packages_verify() {
  local packages_file="$1"
  local cache_dir="$2"

  local package_name=""
  local deb_file=""
  local direct_ready=0
  local installed_ready=0
  local missing_direct=0
  local unreadable=0
  local deb_count=""

  initbox_packages_require_file "$packages_file"
  initbox_packages_validate_list "$packages_file"

  deb_count="$(initbox_packages_cache_deb_count "$cache_dir")"

  initbox_packages_log "Package cache verification"
  initbox_packages_log "Allow-list: $packages_file"
  initbox_packages_log "Cache:      $cache_dir"
  initbox_packages_log "Cached .deb files: $deb_count"
  printf '\n'

  if [ "$deb_count" -eq 0 ]; then
    initbox_packages_error "package cache contains no .deb files"
    return 1
  fi

  while IFS= read -r package_name; do
    [ -z "$package_name" ] && continue

    if initbox_packages_is_installed "$package_name"; then
      printf '[INSTALLED] %s\n' "$package_name"
      installed_ready=$((installed_ready + 1))
    elif initbox_packages_cached_direct_deb_exists "$cache_dir" "$package_name"; then
      printf '[CACHED]    %s\n' "$package_name"
      direct_ready=$((direct_ready + 1))
    else
      printf '[INFO]      %s - no direct .deb found and not installed\n' "$package_name"
      missing_direct=$((missing_direct + 1))
    fi
  done < <(initbox_packages_read_list "$packages_file")

  printf '\nChecking cached .deb metadata...\n'
  while IFS= read -r deb_file; do
    [ -z "$deb_file" ] && continue

    if dpkg-deb --info "$deb_file" >/dev/null 2>&1; then
      printf '[PASS] %s\n' "$(basename "$deb_file")"
    else
      printf '[FAIL] %s\n' "$deb_file"
      unreadable=$((unreadable + 1))
    fi
  done < <(find "$cache_dir" -maxdepth 1 -type f -name '*.deb' | sort)

  printf '\nVerification summary\n'
  printf '  Installed allow-list packages: %s\n' "$installed_ready"
  printf '  Directly cached allow-list packages: %s\n' "$direct_ready"
  printf '  No direct package match: %s\n' "$missing_direct"
  printf '  Unreadable cached .deb files: %s\n' "$unreadable"

  if [ "$unreadable" -ne 0 ]; then
    initbox_packages_error "package cache verification failed because unreadable .deb files were found"
    return 1
  fi

  initbox_packages_log "Cached .deb metadata verification passed."
  if [ "$missing_direct" -ne 0 ]; then
    initbox_packages_warn "Some allow-list packages are neither installed nor directly cached."
    initbox_packages_warn "They may be virtual/renamed packages or the cache may be incomplete; field validation should confirm the image before deployment."
  fi
}

initbox_packages_verify_for_profile() {
  local profile_id="$1"
  local packages_file=""

  packages_file="$(initbox_packages_list_for_profile "$profile_id")"
  initbox_packages_verify "$packages_file" "$INITBOX_APT_CACHE_DIR"
}

initbox_packages_status() {
  local packages_file="$1"
  local cache_dir="$2"

  local package_name=""
  local deb_count=""
  local total_size="0"

  initbox_packages_require_file "$packages_file"
  initbox_packages_prepare_cache_dir "$cache_dir"

  deb_count="$(initbox_packages_cache_deb_count "$cache_dir")"
  if command -v du >/dev/null 2>&1; then
    total_size="$(du -sh "$cache_dir" 2>/dev/null | awk '{print $1}')"
  fi

  echo "InitBox package cache"
  echo "====================="
  echo "Allow-list: $packages_file"
  echo "APT cache:  $cache_dir"
  echo "Cached .deb: $deb_count"
  echo "Cache size:  $total_size"
  echo

  while IFS= read -r package_name; do
    [ -z "$package_name" ] && continue

    if initbox_packages_is_installed "$package_name"; then
      printf '[INSTALLED] %s\n' "$package_name"
    elif initbox_packages_cached_direct_deb_exists "$cache_dir" "$package_name"; then
      printf '[CACHED]    %s\n' "$package_name"
    else
      printf '[MISSING]   %s\n' "$package_name"
    fi
  done < <(initbox_packages_read_list "$packages_file")
}

initbox_packages_status_for_profile() {
  local profile_id="$1"
  local packages_file=""

  packages_file="$(initbox_packages_list_for_profile "$profile_id")"
  initbox_packages_status "$packages_file" "$INITBOX_APT_CACHE_DIR"
}

initbox_packages_usage() {
  cat <<'EOF_USAGE'
Usage:
  source scripts/lib/packages.sh

Unified CLI:
  sudo scripts/lib/packages.sh preseed PROFILE
  scripts/lib/packages.sh verify PROFILE
  scripts/lib/packages.sh status PROFILE
  sudo scripts/lib/packages.sh install PROFILE PACKAGE...
  sudo scripts/lib/packages.sh install-cache PROFILE PACKAGE...
  scripts/lib/packages.sh list PROFILE

Compatibility CLI for profile modules launched through module-runner.sh:
  sudo scripts/lib/packages.sh install PACKAGE...
  sudo scripts/lib/packages.sh install-cache PACKAGE...

The compatibility form requires INITBOX_PROFILE_ID to be exported by the
unified module runner.

Profiles:
  pi-zero2w
  pi-full

Policy:
  - apt-get only
  - this helper never runs apt-get upgrade/dist-upgrade/full-upgrade
  - the top-level installer may separately offer an explicit apt-get upgrade
  - package names must be present in the selected profile allow-list
  - local cache is tried first
  - online download is attempted only when required
EOF_USAGE
}

initbox_packages_resolve_cli_profile() {
  local candidate="${1:-}"

  case "$candidate" in
    pi-zero2w|pi-full)
      printf '%s\n' "$candidate"
      return 0
      ;;
  esac

  case "${INITBOX_PROFILE_ID:-}" in
    pi-zero2w|pi-full)
      printf '%s\n' "$INITBOX_PROFILE_ID"
      return 0
      ;;
    *)
      initbox_packages_error "profile was not supplied and INITBOX_PROFILE_ID is not set to a supported profile"
      return 1
      ;;
  esac
}

initbox_packages_main() {
  local action="${1:-}"
  local candidate="${2:-}"
  local profile_id=""
  local packages_file=""
  local explicit_profile="no"

  case "$action" in
    preseed|verify|status|list)
      case "$candidate" in
        pi-zero2w|pi-full)
          profile_id="$candidate"
          ;;
        *)
          initbox_packages_usage
          return 1
          ;;
      esac
      ;;
    install|install-cache)
      case "$candidate" in
        pi-zero2w|pi-full)
          profile_id="$candidate"
          explicit_profile="yes"
          ;;
        *)
          profile_id="$(initbox_packages_resolve_cli_profile "$candidate")" || {
            initbox_packages_usage
            return 1
          }
          ;;
      esac
      ;;
    -h|--help|help|"")
      initbox_packages_usage
      return 0
      ;;
    *)
      initbox_packages_error "unknown action: $action"
      initbox_packages_usage
      return 1
      ;;
  esac

  case "$action" in
    preseed)
      initbox_packages_preseed_for_profile "$profile_id"
      ;;
    verify)
      initbox_packages_verify_for_profile "$profile_id"
      ;;
    status)
      initbox_packages_status_for_profile "$profile_id"
      ;;
    list)
      packages_file="$(initbox_packages_list_for_profile "$profile_id")"
      initbox_packages_read_list "$packages_file"
      ;;
    install)
      if [ "$explicit_profile" = "yes" ]; then
        shift 2
      else
        shift 1
      fi
      if [ "$#" -eq 0 ]; then
        initbox_packages_error "no package names were requested"
        return 1
      fi
      initbox_packages_install_for_profile "$profile_id" "$@"
      ;;
    install-cache)
      packages_file="$(initbox_packages_list_for_profile "$profile_id")"
      if [ "$explicit_profile" = "yes" ]; then
        shift 2
      else
        shift 1
      fi
      if [ "$#" -eq 0 ]; then
        initbox_packages_error "no package names were requested"
        return 1
      fi
      initbox_packages_validate_requested "$packages_file" "$@"
      initbox_packages_install_from_cache_only "$INITBOX_APT_CACHE_DIR" "$@"
      ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  initbox_packages_main "$@"
fi
