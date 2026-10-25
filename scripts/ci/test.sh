#!/usr/bin/env bash
set -euo pipefail
# shellcheck source-path=SCRIPTDIR source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

if ! has_swift_targets; then
  echo "::notice::No Swift targets yet — nothing to build."
  exit 0
fi

if [ "$(uname -s)" != "Darwin" ]; then
  echo "::error::Swift targets exist; switch build-test to a macOS runner in .github/workflows/test.yml."
  exit 1
fi

echo "::error::build/test not wired yet: add the xcodebuild/swift test commands here."
exit 1
