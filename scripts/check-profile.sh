#!/usr/bin/env bash
# Validate and print an InitBox Raspberry Pi hardware profile.
#
# Usage:
#   ./scripts/check-profile.sh pi-zero2w
#   ./scripts/check-profile.sh pi-3-4-5

set -euo pipefail

PROFILE_ID_INPUT="${1:-}"

if [ -z "$PROFILE_ID_INPUT" ]; then
  echo "ERROR: profile id is required."
  echo
  echo "Usage:"
  echo "  ./scripts/check-profile.sh pi-zero2w"
  echo "  ./scripts/check-profile.sh pi-3-4-5"
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=lib/profile.sh
. "$REPO_ROOT/scripts/lib/profile.sh"

initbox_load_profile "$PROFILE_ID_INPUT"
initbox_print_profile_summary

echo
echo "Module support"
echo "--------------"

for module_id in \
  isi \
  fms \
  hotspot \
  web-terminal \
  dashboard \
  rtc \
  sniffer-bridge
do
  if initbox_profile_supports_module "$module_id"; then
    printf '%-16s yes\n' "$module_id"
  else
    printf '%-16s no\n' "$module_id"
  fi
done

echo
echo "Profile validation passed."
