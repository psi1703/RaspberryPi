#!/usr/bin/env bash
set -euo pipefail

RUNNER="/usr/local/share/initbox/scripts/lib/module-runner.sh"

if [ ! -f "$RUNNER" ]; then
  echo "ERROR: InitBox module runner is not installed: $RUNNER" >&2
  echo "Run initbox-sync.sh update in the lab first." >&2
  exit 1
fi

exec bash "$RUNNER" "$@"
