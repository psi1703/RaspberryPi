#!/usr/bin/env bash
set -euo pipefail

ACTION="${1:-install}"
RUNNER="/usr/local/bin/initbox-module-runner.sh"

if [ ! -x "$RUNNER" ]; then
  echo "ERROR: InitBox module runner is not installed or executable: $RUNNER" >&2
  echo "Run initbox-sync.sh update in the lab first." >&2
  exit 1
fi

exec "$RUNNER" "$ACTION" "dashboard"
