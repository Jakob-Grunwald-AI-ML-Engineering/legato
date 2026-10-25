#!/usr/bin/env bash
set -euo pipefail
# shellcheck source-path=SCRIPTDIR source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

if ! has_app_targets; then
  echo "::warning::live moved, but there are no app targets yet — nothing shipped."
  exit 0
fi

echo "::error::release pipeline not implemented yet (#4) — nothing shipped."
exit 1
