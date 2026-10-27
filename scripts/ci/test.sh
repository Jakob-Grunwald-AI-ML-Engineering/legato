#!/usr/bin/env bash
# Usage: test.sh quick|full [all|packages|ios|mac]
#   quick  builds only (PR feedback, and the cache warm-up on main).
#   full   builds and tests (merge queue).
# The legs are independent so CI runs them as parallel jobs (matrix in .github/workflows/test.yml):
#   packages  SwiftPM on macOS: build + build the test targets; full also runs the e2e cleanup test and `swift test`.
#   ios       the Package scheme for the iOS Simulator (all test targets compile, so a macOS-only API fails the
#             queue) and the iOS app; full then runs only the tests that exist or behave differently on iOS.
#   mac       the macOS app.
# `all` (default) runs every leg in turn, for local use.
set -euo pipefail
# shellcheck source-path=SCRIPTDIR source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source-path=SCRIPTDIR source=../e2e/work-dir.sh
source "$(dirname "${BASH_SOURCE[0]}")/../e2e/work-dir.sh"

mode="${1:?usage: test.sh quick|full [all|packages|ios|mac]}"
leg="${2:-all}"
case "$mode" in quick|full) ;; *) echo "::error::unknown mode '$mode'"; exit 1 ;; esac
case "$leg" in all|packages|ios|mac) ;; *) echo "::error::unknown leg '$leg'"; exit 1 ;; esac

if ! has_swift_targets; then
  echo "::notice::No Swift targets yet — nothing to build ($mode $leg)."
  exit 0
fi

if [ "$(uname -s)" != "Darwin" ]; then
  echo "::error::Swift targets exist; switch build-test to a macOS runner in .github/workflows/test.yml."
  exit 1
fi

select_xcode
xcodebuild -version

scheme=LegatoKit-Package

# Build outputs xcodebuild reuses between runs; CI caches them (.github/workflows/test.yml). LEGATO_E2E_DERIVED
# is the iOS DerivedData that scripts/e2e/ios-sim.sh release-check also builds in, so the release path reuses
# the Debug app built here.
CACHE="$(legato_cache_dir)"
PKGS="$CACHE/SourcePackages"
DERIVED_IOS="${LEGATO_E2E_DERIVED:-$CACHE/derived-ios}"
DERIVED_MAC="${LEGATO_DERIVED_MAC:-$CACHE/derived-mac}"
mkdir -p "$PKGS" "$DERIVED_IOS" "$DERIVED_MAC"

# The only tests that exist or behave differently on iOS (`#if os(iOS)`): the audio-session mapping in
# LegatoAudioTests. Everything else is platform-neutral and already runs on macOS in `packages`; the macOS-only
# tests (`#if os(macOS)`) cannot run on a simulator. Add a target here when a test gains an iOS-only branch.
IOS_ONLY_TESTS=(-only-testing:LegatoAudioTests)

# Generate the iOS app project and build it (app + widget extension) for the simulator, unsigned.
build_ios_app() {
  has_ios_app || return 0
  ensure_xcodegen
  (cd Apps/iOS && "$XCODEGEN" generate)
  xcodebuild build -quiet -project Apps/iOS/Legato.xcodeproj -scheme Legato -configuration Debug \
    -destination 'generic/platform=iOS Simulator' -derivedDataPath "$DERIVED_IOS" \
    -clonedSourcePackagesDirPath "$PKGS" CODE_SIGNING_ALLOWED=NO
}

# Generate the macOS app project and build it unsigned.
build_mac_app() {
  has_mac_app || return 0
  ensure_xcodegen
  (cd Apps/macOS && "$XCODEGEN" generate)
  xcodebuild build -quiet -project Apps/macOS/LegatoMac.xcodeproj -scheme Legato \
    -destination 'generic/platform=macOS' -derivedDataPath "$DERIVED_MAC" \
    -clonedSourcePackagesDirPath "$PKGS" CODE_SIGNING_ALLOWED=NO
}

leg_packages() {
  scripts/e2e/tests/cleanup-test.sh   # seconds; no Xcode build
  swift build
  swift build --build-tests   # compile the test targets too, on the pinned Xcode
  if [ "$mode" = full ]; then swift test; fi
}

leg_ios() {
  # Test targets too: a macOS-only API in a test otherwise surfaces only in the queue's simulator run.
  xcodebuild build-for-testing -quiet -scheme "$scheme" -destination 'generic/platform=iOS Simulator' \
    -derivedDataPath "$DERIVED_IOS" -clonedSourcePackagesDirPath "$PKGS"
  build_ios_app
  if [ "$mode" = full ]; then
    local udid
    udid="$(pick_iphone_udid)"
    if [ -z "$udid" ]; then
      echo "::error::No available iPhone simulator with an iOS 26+ runtime."
      exit 1
    fi
    echo "Simulator: $udid"
    xcodebuild test-without-building -quiet -scheme "$scheme" -destination "platform=iOS Simulator,id=$udid" \
      -derivedDataPath "$DERIVED_IOS" -clonedSourcePackagesDirPath "$PKGS" "${IOS_ONLY_TESTS[@]}"
  fi
}

leg_mac() {
  build_mac_app
}

# The release scan (scripts/e2e/ios-sim.sh release-check) is not here: it runs on the release path
# (scripts/ci/release.sh check), not on every queue run.
case "$leg" in
  all) leg_packages; leg_ios; leg_mac ;;
  packages) leg_packages ;;
  ios) leg_ios ;;
  mac) leg_mac ;;
esac
