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

select_xcode
xcodebuild -version

scheme=LegatoKit-Package

# Generate the iOS app project and build it (app + widget extension) for the simulator, unsigned.
build_ios_app() {
  has_ios_app || return 0
  ensure_xcodegen
  (cd Apps/iOS && "$XCODEGEN" generate)
  xcodebuild build -quiet -project Apps/iOS/Legato.xcodeproj -scheme Legato \
    -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO
}

# Generate the macOS app project and build it unsigned.
build_mac_app() {
  has_mac_app || return 0
  ensure_xcodegen
  (cd Apps/macOS && "$XCODEGEN" generate)
  xcodebuild build -quiet -project Apps/macOS/LegatoMac.xcodeproj -scheme Legato \
    -destination 'generic/platform=macOS' CODE_SIGNING_ALLOWED=NO
}

if [ "$mode" = quick ]; then
  swift build
  swift build --build-tests   # PRs compile the test targets too, on the pinned Xcode, without running them
  xcodebuild build -quiet -scheme "$scheme" -destination 'generic/platform=iOS Simulator'
  build_ios_app
  build_mac_app
  exit 0
fi

udid="$(pick_iphone_udid)"
if [ -z "$udid" ]; then
  echo "::error::No available iPhone simulator with an iOS 26+ runtime."
  exit 1
fi
echo "Simulator: $udid"

swift test
xcodebuild test -quiet -scheme "$scheme" -destination "platform=iOS Simulator,id=$udid"
build_ios_app
build_mac_app

# Release build + scan: no fake engine, e2e hook or debug switch may reach the shipping binary. It builds
# only (no simulator needed), so it runs here rather than in the simulator run.
if has_ios_app; then
  scripts/e2e/ios-sim.sh release-check
fi
