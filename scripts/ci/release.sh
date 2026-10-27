#!/usr/bin/env bash
# Usage: release.sh [check|ship]   (default ship)
#   check  the Release scan, on its own macOS runner: no fake engine, e2e hook or debug switch may reach the
#          shipping binary. Moved here from the per-queue-run path: it builds the iOS app twice (Release, plus a
#          Debug positive control), about 20 min cold, and only a release needs it.
#   ship   the deploy (not implemented yet, #4); the release workflow runs it after `check` passed.
set -euo pipefail
# shellcheck source-path=SCRIPTDIR source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

mode="${1:-ship}"
case "$mode" in check|ship) ;; *) echo "::error::unknown mode '$mode'"; exit 1 ;; esac

if ! has_app_targets; then
  echo "::warning::live moved, but there are no app targets yet — nothing shipped."
  exit 0
fi

if [ "$mode" = check ]; then
  has_ios_app || exit 0
  # LEGATO_E2E_DERIVED should be the DerivedData that scripts/ci/test.sh built the Debug app in (CI restores it
  # from the cache): the Debug control build is then an up-to-date no-op instead of a second full build.
  # Only the Release build is compiled from scratch.
  exec scripts/e2e/ios-sim.sh release-check
fi

echo "::error::release pipeline not implemented yet (#4) — nothing shipped."
exit 1
