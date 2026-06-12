#!/usr/bin/env bash

# InitBox package-cache helper
#
# Purpose:
#   - Lab phase with Internet:
#       download Debian packages once and keep them on the Pi.
#
#   - Field / offline rerun:
#       install from the local cache only.
#
# This helper is intentionally apt-get based.
#
# Expected companion file:
#   scripts/packages.txt
#
# Default cache location:
#   /opt/initbox-package-cache/apt
#
# Notes:
#   - This file does not install Node-RED npm packages by itself.
#   - Dashboard-specific cached assets such as ttyd source/binary,
#     Node-RED installer script, and npm packages are handled by
#     dashboard module logic later.
#   - This helper handles Debian packages only.

set -euo pipefail

: "${INITBOX_PACKAGE_CACHE_DIR:=/opt/initbox-package-cache}"
: "${INITBOX_APT_CACHE_DIR:=${INITBOX_PACKAGE_CACHE_DIR}/apt}"
: "${INITBOX_PACKAGE_LIST:=}"

initbox_packages_log() {
  echo "[packages] $*"
}

initbox_packages_warn() {
  echo "[packages] [WARN] $*" >&2
}

initbox_packages_err() {
  echo "[packages] [ERR] $*" >&2
}

initbox_packages_have_internet() {
  ping -c 1 -W 1 8.8.8.8 >/dev/null 2>&1
}

initbox_packages_require_root() {
  if [ "$(id -u)" -ne 0 ]; then
    initbox_packages_err "This package helper must be run as root."
    return 1
  fi
}

initbox_packages_repo_root_from_script() {
  local source_path=""
  local source_dir=""

  source_path="${BASH_SOURCE[0]}"
  source_dir="$(cd "$(dirname "$source_path")" && pwd)"
  cd "$source_dir/../.." && pwd
}

initbox_packages_default_list() {
  local repo_root=""

  repo_root="$(initbox_packages_repo_root_from_script)"

  if [ -n "${INITBOX_PACKAGE_LIST:-}" ]; then
    printf '%s\n' "$INITBOX_PACKAGE_LIST"
  else
    printf '%s/scripts/packages.txt\n' "$repo_root"
  fi
}

initbox_packages_read_list() {
  local list_file="$1"

  if [ ! -f "$list_file" ]; then
    initbox_packages_err "Package list not found: $list_file"
    return 1
  fi

  grep -vE '^[[:space:]]*($|#)' "$list_file" | awk '{$1=$1; print}' | sort -u
}

initbox_packages_prepare_dirs() {
  install -d -m 0755 "$INITBOX_PACKAGE_CACHE_DIR"
  install -d -m 0755 "$INITBOX_APT_CACHE_DIR"
}

initbox_packages_clean_cache() {
  initbox_packages_require_root
  initbox_packages_prepare_dirs

  initbox_packages_log "Cleaning package cache directory: $INITBOX_APT_CACHE_DIR"
  find "$INITBOX_APT_CACHE_DIR" -type f -name '*.deb' -delete
}

initbox_packages_download_apt() {
  local list_file="${1:-}"
  local pkg
  local packages=()

  initbox_packages_require_root
  initbox_packages_prepare_dirs

  if [ -z "$list_file" ]; then
    list_file="$(initbox_packages_default_list)"
  fi

  if ! initbox_packages_have_internet; then
    initbox_packages_err "Internet is required to download package cache."
    return 1
  fi

  mapfile -t packages < <(initbox_packages_read_list "$list_file")

  if [ "${#packages[@]}" -eq 0 ]; then
    initbox_packages_err "No packages found in: $list_file"
    return 1
  fi

  initbox_packages_log "Updating apt metadata."
  DEBIAN_FRONTEND=noninteractive apt-get -o Dpkg::Use-Pty=0 -o Acquire::Retries=5 update

  initbox_packages_log "Downloading ${#packages[@]} package(s) into: $INITBOX_APT_CACHE_DIR"

  for pkg in "${packages[@]}"; do
    [ -z "$pkg" ] && continue

    initbox_packages_log "Downloading package and dependencies for: $pkg"

    if ! (
      cd "$INITBOX_APT_CACHE_DIR"
      DEBIAN_FRONTEND=noninteractive apt-get \
        -o Dpkg::Use-Pty=0 \
        -o Acquire::Retries=5 \
        -o Dir::Cache::archives="$INITBOX_APT_CACHE_DIR" \
        --download-only \
        install -y "$pkg"
    ); then
      initbox_packages_warn "Download failed for package: $pkg"
      return 1
    fi
  done

  initbox_packages_log "Package cache ready: $INITBOX_APT_CACHE_DIR"
}

initbox_packages_install_from_cache() {
  local missing=0
  local pkg

  initbox_packages_require_root
  initbox_packages_prepare_dirs

  if ! find "$INITBOX_APT_CACHE_DIR" -maxdepth 1 -type f -name '*.deb' | grep -q .; then
    initbox_packages_err "No cached .deb files found in: $INITBOX_APT_CACHE_DIR"
    initbox_packages_err "Run lab cache download first while Internet is available."
    return 1
  fi

  if [ "$#" -eq 0 ]; then
    initbox_packages_err "No package names supplied for install."
    return 1
  fi

  for pkg in "$@"; do
    if dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q 'install ok installed'; then
      initbox_packages_log "Already installed: $pkg"
      continue
    fi

    missing=1
  done

  if [ "$missing" -eq 0 ]; then
    initbox_packages_log "All requested packages are already installed."
    return 0
  fi

  initbox_packages_log "Installing requested packages from local cache only: $*"

  if ! DEBIAN_FRONTEND=noninteractive apt-get \
    -o Dpkg::Use-Pty=0 \
    -o Acquire::Retries=0 \
    -o Dir::Cache::archives="$INITBOX_APT_CACHE_DIR" \
    --no-download \
    install -y "$@"; then
    initbox_packages_err "Offline package install failed."
    initbox_packages_err "The cache may be incomplete. Rebuild it in the lab with Internet."
    return 1
  fi
}

initbox_packages_install_online_or_cache() {
  local packages=("$@")

  initbox_packages_require_root
  initbox_packages_prepare_dirs

  if [ "${#packages[@]}" -eq 0 ]; then
    initbox_packages_err "No package names supplied."
    return 1
  fi

  if initbox_packages_have_internet; then
    initbox_packages_log "Internet available; installing with apt-get and keeping packages cached."

    DEBIAN_FRONTEND=noninteractive apt-get -o Dpkg::Use-Pty=0 -o Acquire::Retries=5 update

    DEBIAN_FRONTEND=noninteractive apt-get \
      -o Dpkg::Use-Pty=0 \
      -o Acquire::Retries=5 \
      -o Dir::Cache::archives="$INITBOX_APT_CACHE_DIR" \
      install -y "${packages[@]}"
  else
    initbox_packages_warn "No Internet detected; installing from local cache only."
    initbox_packages_install_from_cache "${packages[@]}"
  fi
}

initbox_packages_status() {
  local deb_count=0
  local total_size="0"

  initbox_packages_prepare_dirs

  deb_count="$(find "$INITBOX_APT_CACHE_DIR" -maxdepth 1 -type f -name '*.deb' | wc -l | awk '{print $1}')"

  if command -v du >/dev/null 2>&1; then
    total_size="$(du -sh "$INITBOX_APT_CACHE_DIR" 2>/dev/null | awk '{print $1}')"
  fi

  echo "InitBox package cache"
  echo "====================="
  echo "Cache root:      $INITBOX_PACKAGE_CACHE_DIR"
  echo "APT cache:       $INITBOX_APT_CACHE_DIR"
  echo "Cached .deb:     $deb_count"
  echo "Cache size:      $total_size"
}

initbox_packages_usage() {
  cat <<EOF
Usage:
  source scripts/lib/packages.sh

Functions:
  initbox_packages_download_apt [package-list]
      Download all packages from scripts/packages.txt into the local cache.
      Requires Internet.

  initbox_packages_install_from_cache PACKAGE...
      Install requested packages using local cache only.
      Does not download.

  initbox_packages_install_online_or_cache PACKAGE...
      If Internet is available, install with apt-get and keep packages cached.
      If Internet is unavailable, install from local cache only.

  initbox_packages_status
      Show cache location and number of cached .deb files.

  initbox_packages_clean_cache
      Delete cached .deb files.

Environment:
  INITBOX_PACKAGE_CACHE_DIR
      Default: /opt/initbox-package-cache

  INITBOX_APT_CACHE_DIR
      Default: /opt/initbox-package-cache/apt

  INITBOX_PACKAGE_LIST
      Default: scripts/packages.txt
EOF
}

case "${1:-}" in
  download)
    shift
    initbox_packages_download_apt "${1:-}"
    ;;
  install-cache)
    shift
    initbox_packages_install_from_cache "$@"
    ;;
  install)
    shift
    initbox_packages_install_online_or_cache "$@"
    ;;
  status)
    initbox_packages_status
    ;;
  clean)
    initbox_packages_clean_cache
    ;;
  -h|--help|help)
    initbox_packages_usage
    ;;
  "")
    true
    ;;
  *)
    initbox_packages_err "Unknown packages.sh action: $1"
    initbox_packages_usage
    exit 1
    ;;
esac
