#!/usr/bin/env bash
# The merge-queue gate's build and test, cold, in about 7 minutes. Package only: `swift test` builds what it
# needs. The apps are not built here (see .github/workflows/test.yml and scripts/ci/release.sh).
set -euo pipefail
# shellcheck source-path=SCRIPTDIR source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

if ! has_swift_targets; then
  echo "::notice::No Swift targets yet — nothing to test."
  exit 0
fi

if [ "$(uname -s)" != "Darwin" ]; then
  echo "::error::Swift targets exist; switch build-test to a macOS runner in .github/workflows/test.yml."
  exit 1
fi

select_xcode
xcodebuild -version

scripts/e2e/tests/cleanup-test.sh
swift test
