#!/bin/bash
# Physical-device visuals through Apple's CoreDevice capture service. Never starts a simulator.
set -euo pipefail

usage() {
  cat <<'HELP'
Usage: native-control.sh screenshot OUTPUT.png
       native-control.sh record OUTPUT.mp4 SECONDS

Captures the physical device's whole display, including the foreground app,
keyboard and safe areas. Does not launch, install or activate an app.
LEGATO_DEVICE selects the device (same default as ctl.sh).
Requires an Xcode devicectl with `device capture` support.
HELP
}

[ "$#" -gt 0 ] || { usage >&2; exit 2; }
command="$1"; shift
case "$command" in
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
