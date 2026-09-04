#!/usr/bin/env bash
# InitBox no-clone bootstrap.
#
# Normal use on a fresh Raspberry Pi:
#   curl -fsSL https://raw.githubusercontent.com/psi1703/RaspberryPi/main/scripts/bootstrap-initbox.sh | sudo bash
#
# This script does not run git clone. It downloads a temporary GitHub source
# archive, launches the menu installer from that archive, and removes the
# temporary source tree when the installer exits.

set -euo pipefail

REPOSITORY="${INITBOX_BOOTSTRAP_REPOSITORY:-psi1703/RaspberryPi}"
BRANCH="${INITBOX_BOOTSTRAP_BRANCH:-main}"
INSTALLER_ACTION="${INITBOX_BOOTSTRAP_ACTION:-menu}"
KEEP_WORKDIR="0"
WORK_DIR=""
ARCHIVE_FILE=""
SOURCE_ROOT=""

usage() {
  cat <<'EOF_USAGE'
Usage:
  curl -fsSL https://raw.githubusercontent.com/psi1703/RaspberryPi/main/scripts/bootstrap-initbox.sh | sudo bash

Advanced:
  curl -fsSL https://raw.githubusercontent.com/psi1703/RaspberryPi/main/scripts/bootstrap-initbox.sh | sudo bash -s -- --branch main

Options:
  --repo OWNER/REPO       Repository to download. Default: psi1703/RaspberryPi
  --branch BRANCH         Branch to download. Default: main
  --action ACTION         Installer action: menu, plan, install, status. Default: menu
  --keep-workdir          Keep the temporary downloaded source archive/tree.
  --help, -h              Show this help.

This bootstrap downloads a temporary GitHub archive, not a git clone. Installed
InitBox runtime files are copied into /usr/local/bin and /usr/local/share/initbox.
EOF_USAGE
}

log() {
  printf '[bootstrap] %s\n' "$*"
}

warn() {
  printf '[bootstrap] [WARN] %s\n' "$*" >&2
}

fail() {
  printf '[bootstrap] [ERR] %s\n' "$*" >&2
  exit 1
}

require_root() {
  if [ "$(id -u)" -ne 0 ]; then
    fail "bootstrap must run as root. Use: curl ... | sudo bash"
  fi
}

parse_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --repo)
        [ "$#" -ge 2 ] || fail "--repo requires OWNER/REPO"
        REPOSITORY="$2"
        shift 2
        ;;
      --branch)
        [ "$#" -ge 2 ] || fail "--branch requires a branch name"
        BRANCH="$2"
        shift 2
        ;;
      --action)
        [ "$#" -ge 2 ] || fail "--action requires menu, plan, install, or status"
        INSTALLER_ACTION="$2"
        shift 2
        ;;
      --keep-workdir)
        KEEP_WORKDIR="1"
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

  case "$REPOSITORY" in
    */*)
      ;;
    *)
      fail "repository must be OWNER/REPO, got: $REPOSITORY"
      ;;
  esac

  case "$BRANCH" in
    ""|*".."*|*" "*|*"~"*|*"^"*|*":"*|*"?"*|*"["*|*"\\"*)
      fail "unsafe branch name: $BRANCH"
      ;;
  esac

  case "$INSTALLER_ACTION" in
    menu|plan|install|status)
      ;;
    *)
      fail "unsupported installer action: $INSTALLER_ACTION"
      ;;
  esac
}

cleanup() {
  if [ "$KEEP_WORKDIR" = "1" ]; then
    [ -n "$WORK_DIR" ] && warn "Keeping bootstrap workdir: $WORK_DIR"
    return 0
  fi

  if [ -n "$WORK_DIR" ] && [ -d "$WORK_DIR" ]; then
    rm -rf "$WORK_DIR"
  fi
}

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

ensure_bootstrap_tools() {
  local missing=""
  local package=""

  for package in ca-certificates curl tar gzip; do
    case "$package" in
      ca-certificates)
        [ -d /etc/ssl/certs ] || missing="$missing ca-certificates"
        ;;
      *)
        command_exists "$package" || missing="$missing $package"
        ;;
    esac
  done

  if [ -z "$missing" ]; then
    return 0
  fi

  log "Installing bootstrap prerequisites with apt-get:$missing"
  apt-get update
  # shellcheck disable=SC2086
  DEBIAN_FRONTEND=noninteractive apt-get install -y $missing
}

download_source_archive() {
  local archive_url=""

  WORK_DIR="$(mktemp -d /tmp/initbox-bootstrap.XXXXXX)"
  ARCHIVE_FILE="$WORK_DIR/source.tar.gz"
  archive_url="https://github.com/${REPOSITORY}/archive/refs/heads/${BRANCH}.tar.gz"

  log "Downloading InitBox source archive"
  log "Repository: $REPOSITORY"
  log "Branch:     $BRANCH"
  curl -fL --retry 3 --retry-delay 2 --connect-timeout 15 --max-time 300 \
    -o "$ARCHIVE_FILE" \
    "$archive_url"

  log "Extracting source archive"
  tar -xzf "$ARCHIVE_FILE" -C "$WORK_DIR"

  SOURCE_ROOT="$(find "$WORK_DIR" -mindepth 1 -maxdepth 1 -type d | head -n 1)"
  if [ -z "$SOURCE_ROOT" ] || [ ! -f "$SOURCE_ROOT/scripts/install-initbox.sh" ]; then
    fail "downloaded archive does not contain scripts/install-initbox.sh"
  fi
}

post_install_runtime_sources() {
  local runtime_root="${INITBOX_RUNTIME_ROOT:-/usr/local/share/initbox}"
  local bin_dir="${INITBOX_BIN_DIR:-/usr/local/bin}"

  install -d -m 0755 "$runtime_root/scripts" "$bin_dir"
  install -m 0644 -o root -g root "$SOURCE_ROOT/scripts/install-initbox.sh" "$runtime_root/scripts/install-initbox.sh"
  install -m 0644 -o root -g root "$SOURCE_ROOT/scripts/bootstrap-initbox.sh" "$runtime_root/scripts/bootstrap-initbox.sh"
  install -m 0755 -o root -g root "$SOURCE_ROOT/scripts/bootstrap-initbox.sh" "$bin_dir/initbox-bootstrap.sh"
}

run_installer() {
  local rc=0

  log "Launching InitBox installer menu"
  log "Temporary source: $SOURCE_ROOT"
  bash "$SOURCE_ROOT/scripts/install-initbox.sh" "$INSTALLER_ACTION" --repo-root "$SOURCE_ROOT" || rc="$?"

  if [ "$rc" -eq 0 ]; then
    post_install_runtime_sources
  fi

  return "$rc"
}

main() {
  parse_args "$@"
  require_root
  trap cleanup EXIT
  ensure_bootstrap_tools
  download_source_archive
  run_installer
}

main "$@"
