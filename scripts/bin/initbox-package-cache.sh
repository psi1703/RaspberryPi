#!/usr/bin/env bash
set -euo pipefail

HELPER="/usr/local/share/initbox/scripts/lib/packages.sh"

if [ ! -f "$HELPER" ]; then
  echo "ERROR: InitBox package helper is not installed: $HELPER" >&2
  echo "Run initbox-sync.sh update in the lab first." >&2
  exit 1
fi

exec bash "$HELPER" "$@"
