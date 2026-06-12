#!/usr/bin/env bash

# InitBox offline package helper
# Reads scripts/packages.txt, downloads all required .deb packages during lab
# setup, verifies the local package cache, and installs packages from the local
# cache during field setup.
# Expected functions:
#   initbox_packages_preseed <packages_file> <cache_dir>
#   initbox_packages_verify  <packages_file> <cache_dir>
#   initbox_packages_install <packages_file> <cache_dir> [package ...]

set -euo pipefail

initbox_packages_log() {
  local message="$1"

  printf '%s\n' "$message"
}

initbox_packages_require_root() {
  if [ "$(id -u)" -eq 0 ]; then
    return 0
  fi

  initbox_packages_log "ERROR: package operation must run as root."
  return 1
}

initbox_packages_require_file() {
  local packages_file="$1"

  if [ -f "$packages_file" ]; then
    return 0
  fi

  initbox_packages_log "ERROR: packages file does not exist: $packages_file"
  return 1
}

initbox_packages_require_cache_dir() {
  local cache_dir="$1"

  if [ -d "$cache_dir" ]; then
    return 0
  fi

  initbox_packages_log "ERROR: package cache directory does not exist: $cache_dir"
  return 1
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

initbox_packages_validate_names() {
  local packages_file="$1"
  local package_name
  local failures

  failures=0

  while IFS= read -r package_name; do
    [ -z "$package_name" ] && continue

    case "$package_name" in
      *[!a-zA-Z0-9.+_-]*)
        initbox_packages_log "ERROR: invalid package name in $packages_file: $package_name"
        failures=$((failures + 1))
        ;;
    esac
  done < <(initbox_packages_read_list "$packages_file")

  if [ "$failures" -eq 0 ]; then
    return 0
  fi

  return 1
}

initbox_packages_preseed() {
  local packages_file="$1"
  local cache_dir="$2"
  local package_count
  local package_name
  local download_dir

  initbox_packages_require_root
  initbox_packages_require_file "$packages_file"
  initbox_packages_validate_names "$packages_file"

  package_count="$(initbox_packages_count_list "$packages_file")"

  if [ "$package_count" -eq 0 ]; then
    initbox_packages_log "ERROR: package list is empty after comments/blanks are ignored: $packages_file"
    return 1
  fi

  install -d -m 0755 "$cache_dir"

  download_dir="$cache_dir/incoming"
  rm -rf "$download_dir"
  install -d -m 0755 "$download_dir"

  initbox_packages_log "Package preseed starting"
  initbox_packages_log "Packages file: $packages_file"
  initbox_packages_log "Cache dir:     $cache_dir"
  initbox_packages_log "Package count: $package_count"
  initbox_packages_log ""

  initbox_packages_log "Running apt-get update..."
  apt-get -o Dpkg::Use-Pty=0 -o Acquire::Retries=5 update

  initbox_packages_log ""
  initbox_packages_log "Downloading packages and dependencies..."

  while IFS= read -r package_name; do
    [ -z "$package_name" ] && continue

    initbox_packages_log ""
    initbox_packages_log "Downloading package set for: $package_name"

    apt-get \
      -o Dpkg::Use-Pty=0 \
      -o Acquire::Retries=5 \
      -o Dir::Cache::Archives="$download_dir" \
      --download-only \
      install -y "$package_name"
  done < <(initbox_packages_read_list "$packages_file")

  initbox_packages_log ""
  initbox_packages_log "Moving downloaded .deb files into cache..."

  find "$download_dir" -maxdepth 1 -type f -name '*.deb' -exec mv -f {} "$cache_dir/" \;

  rm -rf "$download_dir"

  initbox_packages_log ""
  initbox_packages_log "Package cache contents:"
  find "$cache_dir" -maxdepth 1 -type f -name '*.deb' -printf '  %f\n' | sort

  initbox_packages_log ""
  initbox_packages_log "Preseed complete."
}

initbox_packages_verify() {
  local packages_file="$1"
  local cache_dir="$2"
  local package_count
  local deb_count
  local package_name
  local deb_file
  local failures

  initbox_packages_require_file "$packages_file"
  initbox_packages_require_cache_dir "$cache_dir"
  initbox_packages_validate_names "$packages_file"

  package_count="$(initbox_packages_count_list "$packages_file")"

  if [ "$package_count" -eq 0 ]; then
    initbox_packages_log "ERROR: package list is empty after comments/blanks are ignored: $packages_file"
    return 1
  fi

  deb_count="$(find "$cache_dir" -maxdepth 1 -type f -name '*.deb' | wc -l | tr -d '[:space:]')"

  initbox_packages_log "Offline package verification"
  initbox_packages_log "Packages file: $packages_file"
  initbox_packages_log "Cache dir:     $cache_dir"
  initbox_packages_log "Package count: $package_count"
  initbox_packages_log "Cached .deb:   $deb_count"
  initbox_packages_log ""

  if [ "$deb_count" -eq 0 ]; then
    initbox_packages_log "ERROR: package cache has no .deb files."
    return 1
  fi

  failures=0

  while IFS= read -r package_name; do
    [ -z "$package_name" ] && continue

    if find "$cache_dir" -maxdepth 1 -type f -name "${package_name}_*.deb" | grep -q .; then
      initbox_packages_log "[PASS] cached package found: $package_name"
    else
      initbox_packages_log "[INFO] exact cached .deb not found for requested package: $package_name"
      initbox_packages_log "       It may already be installed, virtual, renamed by architecture, or included through dependencies."
    fi
  done < <(initbox_packages_read_list "$packages_file")

  initbox_packages_log ""
  initbox_packages_log "Testing local .deb metadata readability..."

  while IFS= read -r deb_file; do
    [ -z "$deb_file" ] && continue

    if dpkg-deb --info "$deb_file" >/dev/null 2>&1; then
      initbox_packages_log "[PASS] readable .deb: $(basename "$deb_file")"
    else
      initbox_packages_log "[FAIL] unreadable .deb: $deb_file"
      failures=$((failures + 1))
    fi
  done < <(find "$cache_dir" -maxdepth 1 -type f -name '*.deb' | sort)

  if [ "$failures" -eq 0 ]; then
    initbox_packages_log ""
    initbox_packages_log "Offline package verification passed."
    return 0
  fi

  initbox_packages_log ""
  initbox_packages_log "Offline package verification failed."
  initbox_packages_log "Unreadable .deb files: $failures"
  return 1
}

initbox_packages_install_from_cache() {
  local cache_dir="$1"
  local deb_count

  initbox_packages_require_root
  initbox_packages_require_cache_dir "$cache_dir"

  deb_count="$(find "$cache_dir" -maxdepth 1 -type f -name '*.deb' | wc -l | tr -d '[:space:]')"

  if [ "$deb_count" -eq 0 ]; then
    initbox_packages_log "ERROR: package cache has no .deb files: $cache_dir"
    return 1
  fi

  initbox_packages_log "Installing cached packages from:"
  initbox_packages_log "  $cache_dir"
  initbox_packages_log ""

  apt-get \
    -o Dpkg::Use-Pty=0 \
    -o Dir::Cache::Archives="$cache_dir" \
    install -y "$cache_dir"/*.deb
}

initbox_packages_install() {
  local packages_file="$1"
  local cache_dir="$2"
  local apt_args=()

  shift 2

  initbox_packages_require_root
  initbox_packages_require_file "$packages_file"
  initbox_packages_require_cache_dir "$cache_dir"
  initbox_packages_validate_names "$packages_file"

  if [ "$#" -eq 0 ]; then
    initbox_packages_log "ERROR: no package names were requested for install."
    return 1
  fi

  initbox_packages_log "Requested module packages:"
  printf '  %s\n' "$@"
  initbox_packages_log ""

  initbox_packages_verify "$packages_file" "$cache_dir"

  initbox_packages_log ""
  initbox_packages_log "Installing requested packages from local cache only:"
  printf '  %s\n' "$@"
  initbox_packages_log ""

  apt_args+=("-o" "Dpkg::Use-Pty=0")
  apt_args+=("-o" "Dir::Cache::Archives=$cache_dir")
  apt_args+=("--no-download")
  apt_args+=("install")
  apt_args+=("-y")

  apt-get "${apt_args[@]}" "$@"
}
