#!/usr/bin/env bash
# The merge-queue gate: package tests and both app builds, cold, within the 10-minute budget. MLX, FluidAudio,
# swift-huggingface and swift-transformers are swapped for the CI-only stubs in Stubs/ (LEGATO_STUB_DEPS=1), so
# only our own code compiles. The real libraries are compiled and tested on the release path (release.sh real-deps).
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

export LEGATO_STUB_DEPS=1
select_xcode
xcodebuild -version

scripts/e2e/tests/cleanup-test.sh
scripts/e2e/tests/build-cache-test.sh
swift test

# Both apps, unsigned, against the stubs. arm64 only: the simulator slice is what local and e2e runs use.
ensure_xcodegen
trap finish_build_cache EXIT
prepare_build_cache gate
work="$BUILD_WORK"
build_app() { # build_app <project dir> <project> <destination> <extra args...>
  local dir="$1" project="$2" dest="$3"; shift 3
  (cd "$dir" && "$XCODEGEN" generate)
  run_build_command xcodebuild build -quiet -project "$dir/$project" -scheme Legato -destination "$dest" \
    -derivedDataPath "$work/derived" -clonedSourcePackagesDirPath "$BUILD_PACKAGES" CODE_SIGNING_ALLOWED=NO "$@"
}
if has_ios_app; then build_app Apps/iOS Legato.xcodeproj 'generic/platform=iOS Simulator' ARCHS=arm64 ONLY_ACTIVE_ARCH=YES; fi
if has_mac_app; then build_app Apps/macOS LegatoMac.xcodeproj 'generic/platform=macOS'; fi
# With no remote dependencies SwiftPM deletes the tracked Package.resolved; put it back.
git checkout -- Package.resolved 2> /dev/null || true
