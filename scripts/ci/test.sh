#!/usr/bin/env bash
# Composer shell gate: retained contracts, package tests and unsigned app builds.
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

# Exercise macOS system Bash, including its EXIT-trap scoping on timeouts.
phase_started=$SECONDS
/bin/bash scripts/device/tests/ctl-test.sh
/bin/bash scripts/ci/tests/check-internal-exclusion-test.sh
scripts/e2e/tests/build-cache-test.sh
scripts/e2e/tests/cache-lock-race-test.sh
scripts/e2e/tests/dispatch-test.sh
scripts/dev/tests/prune-sims-test.sh
echo "::notice::Shell checks completed in $((SECONDS - phase_started)) s."
phase_started=$SECONDS
# This gate consumes binaries and test results, not IDE indexing data.
# Keep structured issues too: a busy runner can lose individual console diagnostics.
swift_test_help="$(swift test --help-hidden)"
case "$swift_test_help" in
  *--event-stream-output-path*) event_stream_flag=--event-stream-output-path ;;
  *--experimental-event-stream-output-path*) event_stream_flag=--experimental-event-stream-output-path ;;
  *) echo "::error::Swift test has no supported event-stream reporting option."; exit 1 ;;
esac
swift_test_events="$(mktemp "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/legato-test-events.XXXXXX")"
swift_test_status=0
swift test --disable-index-store "$event_stream_flag" "$swift_test_events" || swift_test_status=$?
if [ "$swift_test_status" -ne 0 ]; then
  echo "::group::Swift Testing issues ($swift_test_events)"
  if ! grep -E '"kind"[[:space:]]*:[[:space:]]*"issueRecorded"' "$swift_test_events"; then
    echo 'No issueRecorded events found; last events follow.'
    tail -n 20 "$swift_test_events"
  fi
  echo "::endgroup::"
  exit "$swift_test_status"
fi
echo "::notice::Swift build and tests completed in $((SECONDS - phase_started)) s."

# Both apps, unsigned, against the shell package. Device compilation does not start a simulator.
ensure_xcodegen
trap finish_build_cache EXIT
prepare_build_cache gate
build_app() { # build_app <project dir> <project> <destination> <extra args...>
  local dir="$1" project="$2" dest="$3" started=$SECONDS; shift 3
  (cd "$dir" && "$XCODEGEN" generate)
  run_build_command xcodebuild build -quiet -project "$dir/$project" -scheme Legato -destination "$dest" \
    -derivedDataPath "$BUILD_WORK" -clonedSourcePackagesDirPath "$BUILD_PACKAGES" \
    CODE_SIGNING_ALLOWED=NO COMPILER_INDEX_STORE_ENABLE=NO "$@"
  echo "::notice::$dir build completed in $((SECONDS - started)) s."
}
if has_ios_app; then build_app Apps/iOS Legato.xcodeproj 'generic/platform=iOS' ARCHS=arm64 ONLY_ACTIVE_ARCH=YES; fi
if has_mac_app; then build_app Apps/macOS LegatoMac.xcodeproj 'generic/platform=macOS'; fi
