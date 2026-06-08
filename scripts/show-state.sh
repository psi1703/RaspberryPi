#!/usr/bin/env bash
# Show InitBox install state.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=lib/state.sh
. "$REPO_ROOT/scripts/lib/state.sh"

initbox_state_print
