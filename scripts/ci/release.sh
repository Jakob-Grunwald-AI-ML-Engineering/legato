#!/usr/bin/env bash
# Usage: release.sh check|mac-build|mac-release|real-deps|ship
#   check      iOS: Release build (arm64 simulator) + scan that no e2e/fake code is in the binary.
#   mac-build  macOS: Debug build, arm64, unsigned (the signed Release build belongs to the ship pipeline, #78).
#   mac-release macOS: ordinary Release build, arm64, unsigned + internal harness exclusion scan.
#   real-deps  plain `swift test` (no stubbed dependencies remain, so this repeats the gate's package tests).
#   ship       the release pipeline (not implemented yet, #78).
set -euo pipefail
# shellcheck source-path=SCRIPTDIR source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

mode="${1:?usage: release.sh check|mac-build|mac-release|real-deps|ship}"

case "$mode" in
  check)
    has_ios_app || { echo "::notice::No iOS app yet — nothing to check."; exit 0; }
    scripts/e2e/ios-sim.sh release-check   # selects Xcode and generates the project itself
    ;;
  mac-build|mac-release)
    has_mac_app || { echo "::notice::No macOS app yet — nothing to build."; exit 0; }
    select_xcode
    ensure_xcodegen
    trap finish_build_cache EXIT
    prepare_build_cache mac   # Debug and Release share it: Xcode separates configurations inside
    (cd Apps/macOS && "$XCODEGEN" generate)
    configuration=Debug
    [ "$mode" != mac-release ] || configuration=Release
    run_build_command xcodebuild build -quiet -project Apps/macOS/LegatoMac.xcodeproj -scheme Legato -configuration "$configuration" \
      -derivedDataPath "$BUILD_WORK" -clonedSourcePackagesDirPath "$BUILD_PACKAGES" \
      -destination 'generic/platform=macOS' ARCHS=arm64 ONLY_ACTIVE_ARCH=YES CODE_SIGNING_ALLOWED=NO
    if [ "$mode" = mac-release ]; then
      bash scripts/ci/check-internal-exclusion.sh mac "$BUILD_WORK/Build/Products/Release/Legato.app"
    fi
    ;;
  real-deps)
    select_xcode
    swift test
    ;;
  ship)
    if ! has_app_targets; then
      echo "::warning::live moved, but there are no app targets yet — nothing shipped."
      exit 0
    fi
    echo "::error::release pipeline not implemented yet (#78) — nothing shipped."
    exit 1
    ;;
  *)
    echo "::error::unknown mode '$mode'"
    exit 1
    ;;
esac
