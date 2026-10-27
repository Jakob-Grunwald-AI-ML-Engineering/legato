#!/usr/bin/env bash
# Usage: release.sh check|mac-build|real-deps|ship
#   check      iOS: Release build (arm64 simulator) + scan that no e2e/fake code is in the binary.
#   mac-build  macOS: Debug build, arm64, unsigned (a Release build of MLX takes over 12 min cold; the signed
#              Release build belongs to the ship pipeline, #4).
#   real-deps  `swift test` against the real MLX, FluidAudio, swift-huggingface and swift-transformers (the gate
#              tests against stubs; tests that need the real libraries run only here).
#   ship       the release pipeline (not implemented yet, #4).
set -euo pipefail
# shellcheck source-path=SCRIPTDIR source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

mode="${1:?usage: release.sh check|mac-build|real-deps|ship}"

case "$mode" in
  check)
    has_ios_app || { echo "::notice::No iOS app yet — nothing to check."; exit 0; }
    scripts/e2e/ios-sim.sh release-check   # selects Xcode and generates the project itself
    ;;
  mac-build)
    has_mac_app || { echo "::notice::No macOS app yet — nothing to build."; exit 0; }
    select_xcode
    ensure_xcodegen
    (cd Apps/macOS && "$XCODEGEN" generate)
    xcodebuild build -quiet -project Apps/macOS/LegatoMac.xcodeproj -scheme Legato -configuration Debug \
      -destination 'generic/platform=macOS' ARCHS=arm64 ONLY_ACTIVE_ARCH=YES CODE_SIGNING_ALLOWED=NO
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
    echo "::error::release pipeline not implemented yet (#4) — nothing shipped."
    exit 1
    ;;
  *)
    echo "::error::unknown mode '$mode'"
    exit 1
    ;;
esac
