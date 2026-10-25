#!/usr/bin/env bash
# Usage: test.sh quick|full — quick builds (PR feedback), full builds and tests (merge queue).
set -euo pipefail
# shellcheck source-path=SCRIPTDIR source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

mode="${1:?usage: test.sh quick|full}"
case "$mode" in quick|full) ;; *) echo "::error::unknown mode '$mode'"; exit 1 ;; esac

if ! has_swift_targets; then
  echo "::notice::No Swift targets yet — nothing to build ($mode)."
  exit 0
fi

if [ "$(uname -s)" != "Darwin" ]; then
  echo "::error::Swift targets exist; switch build-test to a macOS runner in .github/workflows/test.yml."
  exit 1
fi

echo "::error::$mode not wired yet: add the xcodebuild/swift build (quick) and test (full) commands here."
exit 1
