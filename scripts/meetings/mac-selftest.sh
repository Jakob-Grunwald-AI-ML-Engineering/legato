#!/bin/bash
# Headless check of Mac meeting capture: records N seconds (default 15) of one mixed meeting (the mic and the
# system audio into one engine), plays German and English `say` clips through the speakers meanwhile, and
# prints the report JSON.
# Exit 0 when the mixed transcript holds words, 1 when it is empty, 2 when the meeting could not start.
#
# The report holds counts (characters, words, segments of the mixed transcript), never what was said, unless WITH_TEXT=1.
# The self-test exists only in Debug builds of the app; the temporary meeting store is deleted afterwards.
#
# The app is launched through `open -W -n` so Legato.app is its own TCC "responsible process" (run from a
# terminal, the permissions would be attributed to the terminal). First run: macOS asks for Microphone,
# Speech Recognition and System Audio Recording; grant them to Legato and run again.
#
# Usage: scripts/meetings/mac-selftest.sh [seconds]
#   LEGATO_APP=/path/Legato.app   a Debug build (a Release build has no self-test and would just open)
#   OUT_DIR=/path                 where selftest.json and selftest.log go (default /private/tmp/legato-meeting-selftest)
#   WITH_TEXT=1                   also put the transcript text in the report (--meeting-selftest-text)
set -euo pipefail
cd "$(dirname "$0")/../.."
root="$(pwd)"
seconds="${1:-15}"
out_dir="${OUT_DIR:-/private/tmp/legato-meeting-selftest}"
json="$out_dir/selftest.json"
log="$out_dir/selftest.log"
mkdir -p "$out_dir"
chmod 700 "$out_dir"
rm -f "$json" "$log"
extra=()
[ "${WITH_TEXT:-0}" = 1 ] && extra=(--meeting-selftest-text)

app="${LEGATO_APP:-}"
if [ -z "$app" ]; then
  (cd Apps/macOS && xcodegen generate >/dev/null)
  xcodebuild build -quiet -project Apps/macOS/LegatoMac.xcodeproj -scheme Legato \
    -destination 'generic/platform=macOS' -derivedDataPath "$root/build/mac" >"$out_dir/build.log" 2>&1 \
    || { echo "build failed, see $out_dir/build.log" >&2; exit 2; }
  app="$root/build/mac/Build/Products/Debug/Legato.app"
fi

# Speech starts once the models are warm (about 4 s) and repeats until the capture is nearly over.
(
  sleep 4
  end=$((SECONDS + seconds - 6))
  while [ "$SECONDS" -lt "$end" ]; do
    say -v Anna "Das ist ein Test des Systemaudios. Wir besprechen heute den Zeitplan für das Projekt."
    say -v Samantha "This is a test of the system audio. We are discussing the schedule for the project today."
  done
) &
speaker=$!
trap 'kill "$speaker" 2>/dev/null || true' EXIT

open -W -n --stdout "$log" --stderr "$log" "$app" \
  --args --meeting-selftest "$seconds" "--meeting-selftest-out=$json" "${extra[@]+"${extra[@]}"}"

echo "report: $json"
if [ ! -f "$json" ]; then
  echo "no report written, see $log" >&2
  exit 2
fi
cat "$json"
python3 -I - "$json" <<'PY'
import json, sys
r = json.load(open(sys.argv[1]))
if r.get("note") and r.get("segments", 0) == 0 and not r.get("engine"):
    sys.exit(2)
sys.exit(0 if r.get("words", 0) > 0 else 1)
PY
