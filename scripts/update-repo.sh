#!/usr/bin/env bash

# InitBox repository update script
# Safely hard-syncs the local Raspberry Pi repository to origin/main.
# Intended to be run manually on the Pi after changes are committed on GitHub.
# Usage:
#   ./scripts/update-repo.sh
#   ./scripts/update-repo.sh --dry-run
#   ./scripts/update-repo.sh --branch pi-zero-W-2W

set -euo pipefail

REPO_DIR="/home/initbox/RaspberryPi"
BRANCH="pi-zero-W-2W"
REMOTE="origin"
DRY_RUN="no"
LOG_DIR="/var/log/initbox"
LOG_FILE="$LOG_DIR/repo-update.log"
LOCK_DIR="/tmp/initbox-repo-update.lock"

usage() {
  cat <<EOF
Usage:
  ./scripts/update-repo.sh [options]

Options:
  --branch BRANCH   Git branch to sync from. Default: main
  --dry-run         Show what would be updated without changing files
  -h, --help        Show this help

This script performs a safer hard sync:
  git fetch origin <branch>
  git reset --hard origin/<branch>
  git clean -fd

It refuses to continue if the repository path is invalid.
EOF
}

log_line() {
  local message="$1"
  local timestamp

  timestamp="$(date '+%Y-%m-%d %H:%M:%S %Z')"
  printf '[%s] %s\n' "$timestamp" "$message"

  if [ -d "$LOG_DIR" ] && [ -w "$LOG_DIR" ]; then
    printf '[%s] %s\n' "$timestamp" "$message" >>"$LOG_FILE"
  fi
}

fail() {
  log_line "ERROR: $1"
  exit 1
}

cleanup_lock() {
  rmdir "$LOCK_DIR" 2>/dev/null || true
}

acquire_lock() {
  if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    fail "another repo update appears to be running"
  fi

  trap cleanup_lock EXIT INT TERM
}

parse_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --branch)
        if [ "$#" -lt 2 ] || [ -z "${2:-}" ]; then
          fail "--branch requires a value"
        fi
        BRANCH="$2"
        shift 2
        ;;
      --dry-run)
        DRY_RUN="yes"
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        fail "unknown option: $1"
        ;;
    esac
  done
}

prepare_log() {
  if [ "$(id -u)" -eq 0 ]; then
    mkdir -p "$LOG_DIR"
    touch "$LOG_FILE"

    if id initbox >/dev/null 2>&1; then
      chown -R initbox:initbox "$LOG_DIR" || true
    fi
  fi
}

require_command() {
  local command_name="$1"

  if ! command -v "$command_name" >/dev/null 2>&1; then
    fail "required command not found: $command_name"
  fi
}

validate_repo() {
  if [ ! -d "$REPO_DIR" ]; then
    fail "repo directory does not exist: $REPO_DIR"
  fi

  if [ ! -d "$REPO_DIR/.git" ]; then
    fail "not a Git repository: $REPO_DIR"
  fi

  cd "$REPO_DIR"

  if ! git remote get-url "$REMOTE" >/dev/null 2>&1; then
    fail "Git remote '$REMOTE' is not configured"
  fi
}

print_repo_state() {
  local current_head
  local remote_head

  current_head="$(git rev-parse --short HEAD 2>/dev/null || printf 'unknown')"
  remote_head="$(git rev-parse --short "$REMOTE/$BRANCH" 2>/dev/null || printf 'unknown')"

  log_line "repo: $REPO_DIR"
  log_line "branch: $BRANCH"
  log_line "current HEAD: $current_head"
  log_line "remote HEAD: $remote_head"
}

show_local_changes() {
  if ! git diff --quiet || ! git diff --cached --quiet || [ -n "$(git ls-files --others --exclude-standard)" ]; then
    log_line "local changes or untracked files detected"
    git status --short
  else
    log_line "working tree is clean"
  fi
}

fetch_remote() {
  log_line "fetching $REMOTE $BRANCH"
  git fetch --prune "$REMOTE" "$BRANCH"

  if ! git rev-parse --verify "$REMOTE/$BRANCH" >/dev/null 2>&1; then
    fail "remote branch not found after fetch: $REMOTE/$BRANCH"
  fi
}

dry_run_update() {
  log_line "dry run enabled; no files will be changed"
  print_repo_state
  show_local_changes

  echo
  echo "Commands that would run:"
  echo "  git reset --hard $REMOTE/$BRANCH"
  echo "  git clean -fd"
}

hard_sync_repo() {
  log_line "hard-syncing repository to $REMOTE/$BRANCH"

  show_local_changes

  git reset --hard "$REMOTE/$BRANCH"
  git clean -fd

  log_line "repository hard sync complete"
}

repair_permissions() {
  log_line "repairing script permissions"

  if [ -f scripts/initbox-installer.sh ]; then
    chmod 755 scripts/initbox-installer.sh
  fi

  if [ -f scripts/initbox-status.sh ]; then
    chmod 755 scripts/initbox-status.sh
  fi

  if [ -d scripts/lib ]; then
    find scripts/lib -type f -name "*.sh" -exec chmod 644 {} \;
  fi

  if [ -d scripts/pi-zero2w ]; then
    find scripts/pi-zero2w -type f -name "*.sh" -exec chmod 755 {} \;
  fi

  if [ -d scripts/pi-3-4-5 ]; then
    find scripts/pi-3-4-5 -type f -name "*.sh" -exec chmod 755 {} \;
  fi

  if [ -d profiles ]; then
    find profiles -type f -name "*.conf" -exec chmod 644 {} \;
  fi
}

run_basic_validation() {
  log_line "running basic validation"

  if [ -f scripts/initbox-installer.sh ]; then
    bash -n scripts/initbox-installer.sh
  fi

  if [ -f scripts/initbox-status.sh ]; then
    bash -n scripts/initbox-status.sh
  fi

  if [ -f scripts/lib/profile.sh ]; then
    bash -n scripts/lib/profile.sh
  fi

  if [ -f scripts/lib/modules.sh ]; then
    bash -n scripts/lib/modules.sh
  fi

  if [ -f scripts/lib/state.sh ]; then
    bash -n scripts/lib/state.sh
  fi

  if command -v shellcheck >/dev/null 2>&1; then
    shellcheck scripts/initbox-installer.sh scripts/initbox-status.sh scripts/lib/*.sh
  else
    log_line "ShellCheck not installed locally; skipping ShellCheck validation"
  fi
}

main() {
  parse_args "$@"
  prepare_log
  acquire_lock

  require_command git
  require_command bash
  require_command find
  require_command chmod

  validate_repo
  fetch_remote

  if [ "$DRY_RUN" = "yes" ]; then
    dry_run_update
    exit 0
  fi

  print_repo_state
  hard_sync_repo
  repair_permissions
  run_basic_validation
  print_repo_state

  log_line "InitBox repo update finished successfully"
}

main "$@"
