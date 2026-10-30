#!/bin/bash
# Physical-device visuals through Apple's CoreDevice capture service. Never starts a simulator.
set -euo pipefail

usage() {
  cat <<'HELP'
Usage: native-control.sh screenshot OUTPUT.png
       native-control.sh record OUTPUT.mp4 SECONDS
       native-control.sh keyboard  # Select Legato on the current iPhone 17
       native-control.sh tree
       native-control.sh mode Message|Email|Prompt|Note|Auto
       native-control.sh tap X Y
       native-control.sh hold X Y SECONDS
       native-control.sh swipe X1 Y1 X2 Y2 [HOLD_SECONDS]
       native-control.sh quote X1 Y1 X2 Y2  # Press then slide across words
       native-control.sh scroll  # Native fast text scroll
       native-control.sh label "ACCESSIBILITY LABEL"

Captures the physical device's whole display, including the foreground app,
keyboard and safe areas. Does not launch, install or activate an app.
LEGATO_DEVICE selects the device (same default as ctl.sh).
Capture requires an Xcode devicectl with `device capture` support.
Touch commands use a standalone signed XCTest runner; coordinates are points.
They activate the already running LEGATO_BUNDLE app (default de.gruenwald.legato)
and preserve its installation. Artifacts/logs go to LEGATO_NATIVE_OUTPUT or
.claude/tmp/native-control. Coordinate exclusive device ownership first.
HELP
}

[ "$#" -gt 0 ] || { usage >&2; exit 2; }
command="$1"; shift
case "$command" in
  tree|keyboard|mode|tap|hold|swipe|quote|scroll|label)
    case "$command:$#" in tree:0|keyboard:0|mode:1|tap:2|hold:3|swipe:4|swipe:5|quote:4|scroll:0|label:1) ;; *) usage >&2; exit 2 ;; esac
    root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
    build="${LEGATO_NATIVE_BUILD:-/tmp/legato-native-control-build}"
    output_root="${LEGATO_NATIVE_OUTPUT:-$root/.claude/tmp/native-control}"
    mkdir -p "$output_root"
    output="$(mktemp -d "$output_root/run.XXXXXX")"
    xcodegen generate --spec "$root/Apps/iOS/project.yml" > "$output/build.log" 2>&1
    if ! xcodebuild -quiet build-for-testing -project "$root/Apps/iOS/Legato.xcodeproj" \
      -scheme LegatoNativeControl -destination "id=${LEGATO_DEVICE:-00008150-000E60360245401C}" \
      -derivedDataPath "$build" -allowProvisioningUpdates >> "$output/build.log" 2>&1; then
      tail -50 "$output/build.log" >&2; exit 1
    fi
    # Install only the standalone runner explicitly; this also avoids stale XCTest runner installs.
    if ! xcrun devicectl device install app --device "${LEGATO_DEVICE:-00008150-000E60360245401C}" \
      "$build/Build/Products/Debug-iphoneos/LegatoNativeControl-Runner.app" --timeout 30 >> "$output/build.log" 2>&1; then
      tail -50 "$output/build.log" >&2; exit 1
    fi
    original="$(find "$build/Build/Products" -maxdepth 1 -name 'LegatoNativeControl_*.xctestrun' -print -quit)"
    [ -n "$original" ] || { echo 'Native control runner configuration missing' >&2; exit 1; }
    run_file="$build/Build/Products/native-control-$$.xctestrun"
    cp "$original" "$run_file"
    trap 'rm -f "$run_file"' EXIT
    /usr/libexec/PlistBuddy -c "Add :LegatoNativeControl:EnvironmentVariables:LEGATO_NATIVE_COMMAND string $command $*" "$run_file"
    /usr/libexec/PlistBuddy -c "Add :LegatoNativeControl:EnvironmentVariables:LEGATO_NATIVE_BUNDLE string ${LEGATO_BUNDLE:-de.gruenwald.legato}" "$run_file"
    if ! xcodebuild -quiet test-without-building -xctestrun "$run_file" \
      -destination "id=${LEGATO_DEVICE:-00008150-000E60360245401C}" -parallel-testing-enabled NO \
      -test-timeouts-enabled YES -maximum-test-execution-time-allowance 60 \
      -resultBundlePath "$output/result.xcresult" > "$output/control.log" 2>&1; then
      tail -60 "$output/control.log" >&2; echo "Artifacts: $output" >&2; exit 1
    fi
    xcrun xcresulttool export attachments --path "$output/result.xcresult" --output-path "$output/attachments" > /dev/null
    echo "Artifacts: $output"
    exit 0 ;;
  screenshot)
    [ "$#" -eq 1 ] || { usage >&2; exit 2; }
    [[ "$1" == *.png ]] || { echo 'Screenshot destination must end in .png' >&2; exit 2; }
    capture=screenshot ;;
  record)
    [ "$#" -eq 2 ] || { usage >&2; exit 2; }
    [[ "$1" == *.mp4 ]] || { echo 'Recording destination must end in .mp4' >&2; exit 2; }
    [[ "$2" =~ ^[1-9][0-9]*$ ]] || { echo 'Recording duration must be a positive number of seconds' >&2; exit 2; }
    capture=screen-record ;;
  -h|--help|help) usage; exit 0 ;;
  *) usage >&2; exit 2 ;;
esac

help="$(xcrun devicectl device capture "$capture" --help 2>&1)"
case "$help" in
  *"USAGE: devicectl device capture $capture "*) ;;
  *) echo 'Selected Xcode does not provide native physical-device capture. Select an Xcode with devicectl device capture support (verified with Xcode 27.2).' >&2; exit 1 ;;
esac

device="${LEGATO_DEVICE:-00008150-000E60360245401C}"
output="$1"
mkdir -p "$(dirname "$output")"
args=(device capture "$capture" --device "$device" --destination "$output")
if [ "$capture" = screen-record ]; then
  args+=(--duration "$2" --timeout "$(( $2 + 30 ))")
else
  args+=(--timeout "${LEGATO_DEVICE_TIMEOUT:-20}")
fi
xcrun devicectl "${args[@]}"
[ -s "$output" ] || { echo "Capture returned without an artifact: $output" >&2; exit 1; }
echo "$output"
