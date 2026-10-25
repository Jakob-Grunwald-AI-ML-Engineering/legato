#!/usr/bin/env bash
# Headless end-to-end check of the iOS app on a simulator. See Apps/iOS/App/Debug/E2E.swift for the hooks.
#
# Usage: ios-sim.sh [run|release-check]
#   run             (default) build the Debug app, run the scenarios, print a PASS/FAIL table.
#   release-check   build the Release app and verify none of the fake/e2e code is in the binary.
#
# SpeechTranscriber and the microphone don't work on the Simulator and there is no Action Button, so the
# app runs with a scripted engine and a fake mic (-LegatoFakeEngine) and is driven by Darwin notifications
# (`notifyutil -p de.gruenwald.legato.e2e.<toggle|interrupt|copy-last>`). Everything else is the real
# app: ActivityKit (Live Activities), UIPasteboard, the history file in the App Group container, the
# AVAudioSession interruption observer. Assertions read the app's `e2e` os_log lines
# (subsystem de.gruenwald.legato), `simctl pbpaste` and the history file.
#
# Environment:
#   LEGATO_E2E_UDID      use this (already created) simulator; it is shut down afterwards only if the script booted it
#   LEGATO_E2E_DERIVED   DerivedData directory to reuse between runs (default: a temp dir, removed on exit)
#   LEGATO_E2E_KEEP=1    keep the work directory (logs) and print its path
# Without LEGATO_E2E_UDID a simulator named "legato-e2e" is created once (iPhone, newest iOS 26+ runtime),
# reused by later runs, and shut down at the end.
set -uo pipefail
# shellcheck source-path=SCRIPTDIR source=../ci/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/../ci/lib.sh"   # also cd's to the repo root

mode="${1:-run}"
BID=de.gruenwald.legato
SIM_NAME=legato-e2e
NOTIFY=de.gruenwald.legato.e2e
WORK="$(mktemp -d "${TMPDIR:-/tmp}/legato-e2e.XXXXXX")"
DERIVED="${LEGATO_E2E_DERIVED:-$WORK/derived}"
UDID=""
BOOTED_BY_US=0
LOGPID=""

cleanup() {
  if declare -F stop_log > /dev/null; then stop_log; fi
  if [ "$BOOTED_BY_US" = 1 ] && [ -n "$UDID" ]; then xcrun simctl shutdown "$UDID" > /dev/null 2>&1; fi
  if [ "${LEGATO_E2E_KEEP:-0}" = 1 ]; then echo "Work directory kept: $WORK"; else rm -rf "$WORK"; fi
}
trap cleanup EXIT

select_xcode
ensure_xcodegen || exit 2
(cd Apps/iOS && "$XCODEGEN" generate > "$WORK/xcodegen.log" 2>&1) || { cat "$WORK/xcodegen.log"; exit 2; }

# ---------------------------------------------------------------------------------------------- simulator

# "<runtime id> <device type id>" of the newest iOS >= 26 runtime that has an iPhone.
pick_runtime_and_type() {
  xcrun simctl list devices available -j | python3 -I -c '
import json, re, sys
best = None
for rt, devs in json.load(sys.stdin)["devices"].items():
    m = re.search(r"iOS-(\d+)-(\d+)", rt)
    if not m or int(m[1]) < 26:
        continue
    for d in devs:
        if d["name"].startswith("iPhone") and (best is None or (int(m[1]), int(m[2])) > best[0]):
            best = ((int(m[1]), int(m[2])), rt, d["deviceTypeIdentifier"])
if best:
    print(best[1], best[2])
'
}

prepare_simulator() {
  if [ -n "${LEGATO_E2E_UDID:-}" ]; then
    UDID="$LEGATO_E2E_UDID"
  else
    UDID="$(xcrun simctl list devices available -j | python3 -I -c '
import json, sys
for devs in json.load(sys.stdin)["devices"].values():
    for d in devs:
        if d["name"] == "legato-e2e":
            print(d["udid"])
            raise SystemExit
')"
    if [ -z "$UDID" ]; then
      local rt type
      read -r rt type < <(pick_runtime_and_type)
      [ -n "${rt:-}" ] || { echo "No iPhone simulator with an iOS 26+ runtime."; exit 2; }
      UDID="$(xcrun simctl create "$SIM_NAME" "$type" "$rt")" || exit 2
    fi
  fi
  if [ "$(xcrun simctl list devices -j | python3 -I -c '
import json, sys
u = sys.argv[1]
for devs in json.load(sys.stdin)["devices"].values():
    for d in devs:
        if d["udid"] == u:
            print(d["state"])' "$UDID")" != Booted ]; then
    xcrun simctl boot "$UDID" || exit 2   # no Simulator.app: headless
    BOOTED_BY_US=1
  fi
  xcrun simctl bootstatus "$UDID" -b > /dev/null 2>&1 || exit 2
}

# ---------------------------------------------------------------------------------------------- build

build_app() { # build_app <configuration> <extra xcodebuild args...>
  local config="$1"; shift
  xcodebuild build -project Apps/iOS/Legato.xcodeproj -scheme Legato -configuration "$config" \
    -destination "${DEST:-generic/platform=iOS Simulator}" -derivedDataPath "$DERIVED" "$@" \
    > "$WORK/build-$config.log" 2>&1 || { tail -30 "$WORK/build-$config.log"; echo "Build failed ($WORK/build-$config.log)"; LEGATO_E2E_KEEP=1; exit 2; }
}

# ---------------------------------------------------------------------------------------------- release check

if [ "$mode" = release-check ]; then
  build_app Release CODE_SIGNING_ALLOWED=NO
  build_app Debug CODE_SIGNING_ALLOWED=NO   # positive control for the scan below
  app="$DERIVED/Build/Products/Release-iphonesimulator/Legato.app"
  debug_app="$DERIVED/Build/Products/Debug-iphonesimulator/Legato.app"
  # Identifiers that exist only in the e2e hooks. The Debug build is the positive control.
  needles=(E2EScriptedEngine E2EFakeAudioSource E2ENoopSessionControl LegatoFakeEngine LegatoFakeReadiness
    LegatoFakeWordDelayMs LegatoForceTapToCopy e2e-scripted de.gruenwald.legato.e2e system-stop handleE2E
    AudioDiagnostics AppSessionControl audio-diag.jsonl keepSessionActiveBetweenRuns LegatoFakeOtherAudio
    LegatoFakeBackground LegatoFakeBackgroundRefusal start.route toggle-after-hop)
  scan() { # every Mach-O file in the bundle
    find "$1" -type f \( -name Legato -o -name '*.dylib' \) -print0 | xargs -0 strings -a
  }
  scan "$app" > "$WORK/release.strings"
  fail=0
  for n in "${needles[@]}"; do
    if grep -q -F -- "$n" "$WORK/release.strings"; then echo "FAIL  Release contains: $n"; fail=1; fi
  done
  if [ "$fail" = 0 ]; then echo "PASS  Release build contains none of: ${needles[*]}"; fi
  if [ -d "$debug_app" ]; then
    scan "$debug_app" > "$WORK/debug.strings"
    missing=0
    for n in LegatoFakeEngine e2e-scripted; do grep -q -F -- "$n" "$WORK/debug.strings" || missing=1; done
    if [ "$missing" = 1 ]; then echo "WARN  control failed: Debug build lacks the identifiers, so the scan proves nothing"; fail=1
    else echo "PASS  control: the Debug build contains them"; fi
  fi
  exit "$fail"
fi

[ "$mode" = run ] || { echo "usage: ios-sim.sh [run|release-check]"; exit 2; }

prepare_simulator
echo "Simulator: $UDID"
t_start=$SECONDS
# Ad-hoc signing (not CODE_SIGNING_ALLOWED=NO): the simulator only grants the App Group container to a
# signed app, and without it the app falls back to an app-local history file.
DEST="platform=iOS Simulator,id=$UDID" build_app Debug \
  CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=YES CODE_SIGNING_REQUIRED=YES CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM=
APP="$DERIVED/Build/Products/Debug-iphonesimulator/Legato.app"
[ -d "$APP" ] || { echo "No app at $APP"; exit 2; }
echo "Built in $((SECONDS - t_start))s"

# ---------------------------------------------------------------------------------------------- harness

ROWS=()          # "scenario|check|PASS/FAIL"
DETAILS=()       # failure details
FAILED=0
SCENARIO=""
LOG=""
SCEN_START=0

record() { # record <PASS|FAIL> <description> [detail]
  ROWS+=("$SCENARIO|$2|$1")
  if [ "$1" = FAIL ]; then FAILED=$((FAILED + 1)); DETAILS+=("[$SCENARIO] $2: ${3:-}"); fi
}
assert_eq() { # assert_eq <description> <expected> <actual>
  if [ "$2" = "$3" ]; then record PASS "$1"; else record FAIL "$1" "expected <$2> got <$3>"; fi
}
assert_log() { # assert_log <description> <fixed string>: appears in the scenario log
  if grep -q -F -- "$2" "$LOG"; then record PASS "$1"; else record FAIL "$1" "no log line containing <$2>"; fi
}
assert_no_log() {
  if grep -q -F -- "$2" "$LOG"; then record FAIL "$1" "unexpected: $(grep -F -- "$2" "$LOG" | head -1 | cut -c1-200)"; else record PASS "$1"; fi
}
assert_count() { # assert_count <description> <fixed string> <n>
  local n; n="$(grep -c -F -- "$2" "$LOG")"
  if [ "$n" = "$3" ]; then record PASS "$1"; else record FAIL "$1" "<$2> logged $n times, expected $3"; fi
}
assert_order() { # assert_order <description> <first> <second>: first appears before second
  local a b
  a="$(grep -n -F -- "$2" "$LOG" | head -1 | cut -d: -f1)"
  b="$(grep -n -F -- "$3" "$LOG" | tail -1 | cut -d: -f1)"
  if [ -n "$a" ] && [ -n "$b" ] && [ "$a" -lt "$b" ]; then record PASS "$1"
  else record FAIL "$1" "<$2> at line ${a:-none}, <$3> at line ${b:-none}"; fi
}

# The value of key="..." on the first line matching a fixed string, or empty.
log_field() { # log_field <line marker> <key>
  grep -F -- "$1" "$LOG" | head -1 | sed -n "s/.*[ ]$2=\"\\([^\"]*\\)\".*/\\1/p"
}

stop_log() {
  if [ -n "$LOGPID" ]; then kill "$LOGPID" > /dev/null 2>&1; wait "$LOGPID" 2> /dev/null; LOGPID=""; fi
}

# wait_log <fixed string> [timeout seconds]: 0 once a matching line is in the log.
wait_log() {
  local deadline=$((SECONDS + ${2:-10}))
  while [ "$SECONDS" -lt "$deadline" ]; do
    grep -q -F -- "$1" "$LOG" && return 0
    sleep 0.2
  done
  return 1
}
# Same, but counts: wait until at least <n> lines match.
wait_log_n() {
  local deadline=$((SECONDS + ${3:-10}))
  while [ "$SECONDS" -lt "$deadline" ]; do
    [ "$(grep -c -F -- "$1" "$LOG")" -ge "$2" ] && return 0
    sleep 0.2
  done
  return 1
}

trigger() { xcrun simctl spawn "$UDID" notifyutil -p "$NOTIFY.$1" > /dev/null 2>&1; }

# begin <scenario name> [launch args...]: clean install, log capture, launch.
begin() {
  SCENARIO="$1"; shift
  SCEN_START=$SECONDS
  stop_log
  xcrun simctl terminate "$UDID" "$BID" > /dev/null 2>&1
  xcrun simctl uninstall "$UDID" "$BID" > /dev/null 2>&1
  xcrun simctl install "$UDID" "$APP" || { record FAIL "install" "simctl install failed"; return 1; }
  xcrun simctl privacy "$UDID" grant microphone "$BID" > /dev/null 2>&1
  relaunch "$@"
}

# relaunch [launch args...]: new process on the current install, log capture restarted.
relaunch() {
  stop_log
  xcrun simctl terminate "$UDID" "$BID" > /dev/null 2>&1
  LOG="$WORK/${SCENARIO%%.*}-$((++LOGSEQ)).log"
  : > "$LOG"
  xcrun simctl spawn "$UDID" log stream --level debug --style compact \
    --predicate 'subsystem == "de.gruenwald.legato" AND category == "e2e"' > "$LOG" 2>&1 &
  LOGPID=$!
  sleep 1.5
  xcrun simctl launch "$UDID" "$BID" "$@" > "$WORK/launch.out" 2>&1
  wait_log "e2e launch " 10 && return 0
  record FAIL "app launches and logs" "no 'e2e launch' line ($(cat "$WORK/launch.out"))"
  return 1
}
LOGSEQ=0

pasteboard() { xcrun simctl pbpaste "$UDID" 2> /dev/null; }

# The history entries ("text" per line) in the app's App Group container.
history_texts() {
  local group file
  group="$(xcrun simctl get_app_container "$UDID" "$BID" groups | awk -F'\t' '$1 == "group.de.gruenwald.legato" {print $2}')"
  file="$group/history.jsonl"
  [ -n "$group" ] && [ -f "$file" ] || return 0
  python3 -I -c '
import json, sys
for line in open(sys.argv[1]):
    if line.strip():
        print(json.loads(line)["text"])' "$file"
}

# ---------------------------------------------------------------------------------------------- scenarios

TEXT="hello world from the simulator"
# 21 words: about 3.2 s of scripted speech, long enough for an interruption mid-way
LONG="hello world from the simulator this is a longer dictation that keeps going for a few seconds so the activity updates"

scenario_a() {
  begin "a. happy path" -LegatoFakeEngine "$LONG" -LegatoForceTapToCopy NO || return
  xcrun simctl pbcopy "$UDID" <<< "sentinel"
  trigger toggle
  wait_log "e2e outcome kind=started" 10
  wait_log 'phase=listening tail="hello world' 10
  sleep 3   # the rest of the script
  trigger toggle
  wait_log "e2e outcome kind=stopped" 10
  sleep 0.5
  assert_log "activity requested (starting)" "activity.request phase=starting"
  assert_count "exactly one activity requested" "activity.request phase=" 1
  assert_log "real ActivityKit tracks the activity" "activity.request phase=starting tail=\"\" live=1"
  assert_log "activity updated (listening, tail has the first words)" 'activity.update phase=listening tail="hello world'
  assert_order "request before audio starts" "activity.request phase=starting" "audio.start"
  assert_order "starting before listening" "activity.request phase=starting" "activity.update phase=listening"
  assert_log "finishing update on stop" "activity.update phase=finishing"
  assert_order "clipboard written before activity ends" "clipboard.write source=coordinator" "activity.end phase=copied"
  assert_eq "activity ended (copied) with the full text" "$LONG" "$(log_field "activity.end phase=copied" tail)"
  assert_eq "outcome text" "$LONG" "$(log_field "outcome kind=stopped" text)"
  assert_eq "pbpaste == text" "$LONG" "$(pasteboard)"
  assert_eq "history has the entry once" "1" "$(history_texts | grep -c -x -F -- "$LONG")"
  assert_log "audio and session released" "session.deactivate"
}

scenario_b() {
  local issue
  begin "b. readiness" -LegatoFakeEngine "$TEXT" -LegatoFakeReadiness liveActivitiesDisabled || return
  for issue in liveActivitiesDisabled micPermission assetsMissing; do
    SCENARIO="b. readiness $issue"
    if [ "$issue" != liveActivitiesDisabled ]; then relaunch -LegatoFakeEngine "$TEXT" -LegatoFakeReadiness "$issue" || continue; fi
    xcrun simctl pbcopy "$UDID" <<< "sentinel"
    trigger toggle
    wait_log "e2e outcome" 10
    sleep 1
    assert_log "outcome needsOnboarding($issue)" "outcome kind=needsOnboarding issue=$issue"
    assert_no_log "no activity requested" "activity.request"
    assert_no_log "no session built, no audio" "session.make"
    assert_no_log "mic never started" "audio.start"
    assert_eq "clipboard untouched" "sentinel" "$(pasteboard)"
    assert_eq "history empty" "0" "$(history_texts | grep -c .)"
  done
}

scenario_c() {
  begin "c. interruption mid-dictation" -LegatoFakeEngine "$LONG" -LegatoForceTapToCopy NO || return
  xcrun simctl pbcopy "$UDID" <<< "sentinel"
  trigger toggle
  wait_log 'phase=listening tail="hello world' 10
  trigger interrupt
  wait_log "e2e outcome kind=stopped" 10
  sleep 0.5
  local partial; partial="$(log_field "outcome kind=stopped" text)"
  assert_log "AVAudioSession observer path ran" 'system-stop reason="interruption began"'
  if [ -n "$partial" ] && [ "$partial" != "$LONG" ] && [[ "$LONG" == "$partial"* ]]; then
    record PASS "outcome is a non-empty partial of the script"
  else record FAIL "outcome is a non-empty partial of the script" "got <$partial>"; fi
  assert_eq "pbpaste == partial text" "$partial" "$(pasteboard)"
  assert_eq "history has the partial once" "1" "$(history_texts | grep -c -x -F -- "$partial")"
  assert_eq "activity ended (copied) with the partial" "$partial" "$(log_field "activity.end phase=copied" tail)"
  assert_log "audio stopped" "audio.stop"
}

scenario_d() {
  begin "d. two dictations in a row" -LegatoFakeEngine "$TEXT" -LegatoForceTapToCopy NO || return
  local i
  for i in 1 2; do
    xcrun simctl pbcopy "$UDID" <<< "sentinel$i"
    trigger toggle
    wait_log_n "e2e outcome kind=started" "$i" 10
    sleep 1.5   # the script is ~0.8 s long
    trigger toggle
    wait_log_n "e2e outcome kind=stopped" "$i" 10
    sleep 0.5
    assert_eq "run $i: pbpaste == text" "$TEXT" "$(pasteboard)"
  done
  assert_count "two activities requested" "activity.request phase=starting" 2
  assert_count "two activities ended (copied)" "activity.end phase=copied" 2
  assert_count "two fresh sessions" "session.make" 2
  assert_eq "history has both entries" "2" "$(history_texts | grep -c -x -F -- "$TEXT")"
  local pids; pids="$(sed -n 's/.*Legato\[\([0-9]*\):.*/\1/p' "$LOG" | sort -u | wc -l | tr -d ' ')"
  assert_eq "same process throughout (the app never quits itself)" "1" "$pids"
}

scenario_e() {
  begin "e. tapToCopy" -LegatoFakeEngine "$TEXT" -LegatoForceTapToCopy YES || return
  xcrun simctl pbcopy "$UDID" <<< "sentinel"
  trigger toggle
  wait_log "e2e outcome kind=started" 10
  sleep 1.5
  trigger toggle
  wait_log "e2e outcome kind=stopped" 10
  sleep 0.5
  assert_log "clipboard write reported as not changed" "clipboard.write source=coordinator changed=false forced=tapToCopy"
  assert_eq "activity ended (tapToCopy) with the text" "$TEXT" "$(log_field "activity.end phase=tapToCopy" tail)"
  assert_eq "clipboard untouched by the stop" "sentinel" "$(pasteboard)"
  assert_eq "history has the entry" "1" "$(history_texts | grep -c -x -F -- "$TEXT")"
  # Stands in for tapping the activity (legato://copy-last): a simctl openurl of a custom scheme stops at
  # an "Open in Legato?" dialog that nothing headless can confirm.
  trigger copy-last
  wait_log "clipboard.write source=copy-last" 10
  assert_log "copy-last write changed the pasteboard" "clipboard.write source=copy-last changed=true"
  assert_eq "pbpaste == text after copy-last" "$TEXT" "$(pasteboard)"
}

scenario_f() {
  # A phrase spoken in under a second, then silence. The activity should show it well before the
  # 10 s heartbeat; LiveTranscript's throttle must not hold the last words back.
  begin "f. last words reach the activity" -LegatoFakeEngine "$TEXT" -LegatoForceTapToCopy NO || return
  trigger toggle
  wait_log "e2e outcome kind=started" 10
  wait_log 'phase=listening tail="hello world from the simulator"' 4
  assert_log "listening update carries the whole phrase within 4 s" 'phase=listening tail="hello world from the simulator"'
  trigger toggle
  wait_log "e2e outcome kind=stopped" 10
}

scenario_g() {
  # Music plays while the app is in the background (-LegatoFakeOtherAudio YES -LegatoFakeBackground YES):
  # iOS only allows recording next to other audio from the foreground, so the press must not try a
  # background start at all. The intent then brings the app forward and presses again.
  begin "g. music + background" -LegatoFakeEngine "$TEXT" -LegatoFakeOtherAudio YES -LegatoFakeBackground YES -LegatoForceTapToCopy NO || return
  xcrun simctl pbcopy "$UDID" <<< "sentinel"
  trigger toggle
  wait_log "e2e outcome kind=needsForeground" 10
  sleep 1
  assert_log "outcome needsForeground(otherAudioPlaying)" "outcome kind=needsForeground reason=otherAudioPlaying"
  assert_log "start.route: foregroundHop, with the reason" "start.route route=foregroundHop reason=otherAudioPlaying outcome=needsForeground"
  assert_no_log "no activity requested" "activity.request"
  assert_no_log "no session built, no audio" "session.make"
  assert_no_log "mic never started" "audio.start"
  assert_no_log "audio session never activated" "session.activate"
  assert_eq "clipboard untouched" "sentinel" "$(pasteboard)"
  assert_eq "history empty" "0" "$(history_texts | grep -c .)"
  # The app is in the foreground now: the next press is a normal start.
  trigger foreground
  wait_log "e2e command foreground" 10
  trigger toggle
  wait_log "e2e outcome kind=started" 10
  assert_log "start.route: ran in the foreground" "start.route route=foreground reason=none outcome=started"
  assert_log "activity requested first" "activity.request phase=starting"
  assert_order "request before audio starts" "activity.request phase=starting" "audio.start"
  sleep 1.5
  trigger toggle
  wait_log "e2e outcome kind=stopped" 10
  sleep 0.5
  assert_eq "activity ended (copied) with the text" "$TEXT" "$(log_field "activity.end phase=copied" tail)"
  assert_eq "pbpaste == text" "$TEXT" "$(pasteboard)"
  assert_eq "history has the entry once" "1" "$(history_texts | grep -c -x -F -- "$TEXT")"
  assert_count "exactly one activity requested" "activity.request phase=" 1
  assert_count "exactly one session built" "session.make" 1

  # The intent's second press: the system brought the app forward, whatever the app state still says.
  SCENARIO="g. music + background, after the hop"
  relaunch -LegatoFakeEngine "$TEXT" -LegatoFakeOtherAudio YES -LegatoFakeBackground YES -LegatoForceTapToCopy NO || return
  trigger toggle
  wait_log "e2e outcome kind=needsForeground" 10
  trigger toggle-after-hop
  wait_log "e2e outcome kind=started" 10
  assert_log "start.route: ran as a foreground hop" "start.route route=foregroundHop reason=otherAudioPlaying outcome=started"
  sleep 1.5
  trigger toggle
  wait_log "e2e outcome kind=stopped" 10
  sleep 0.5
  assert_eq "pbpaste == text" "$TEXT" "$(pasteboard)"
}

scenario_i() {
  # The system refuses a background start anyway (music the app did not see, a race): the same hop, with
  # a clean teardown. The activity requested first must be gone at once, not left behind as "failed".
  local step
  for step in pla what; do
    SCENARIO="i. background refused ($step)"
    begin "$SCENARIO" -LegatoFakeEngine "$TEXT" -LegatoFakeBackground YES -LegatoFakeBackgroundRefusal "$step" -LegatoForceTapToCopy NO || continue
    xcrun simctl pbcopy "$UDID" <<< "sentinel"
    trigger toggle
    wait_log "e2e outcome kind=needsForeground" 10
    sleep 1
    assert_log "outcome needsForeground(backgroundStartRefused)" "outcome kind=needsForeground reason=backgroundStartRefused"
    assert_log "start.route: foregroundHop, with the reason" "start.route route=foregroundHop reason=backgroundStartRefused outcome=needsForeground"
    assert_log "the background start was attempted" "$([ "$step" = pla ] && echo session.activate.refused || echo audio.start.refused)"
    assert_count "one activity requested" "activity.request phase=" 1
    assert_log "activity dismissed at once, none left" "activity.dismiss live=0"
    assert_no_log "no failed activity left behind" "activity.end"
    if grep -qE 'e2e audio\.start *$' "$LOG"; then record FAIL "no audio ran" "audio.start logged"; else record PASS "no audio ran"; fi
    assert_eq "clipboard untouched" "sentinel" "$(pasteboard)"
    assert_eq "history empty" "0" "$(history_texts | grep -c .)"
    trigger foreground
    wait_log "e2e command foreground" 10
    trigger toggle
    wait_log "e2e outcome kind=started" 10
    sleep 1.5
    trigger toggle
    wait_log "e2e outcome kind=stopped" 10
    sleep 0.5
    assert_count "a fresh session for the foreground start" "session.make" 2
    assert_count "second activity requested" "activity.request phase=" 2
    assert_eq "activity ended (copied) with the text" "$TEXT" "$(log_field "activity.end phase=copied" tail)"
    assert_eq "pbpaste == text" "$TEXT" "$(pasteboard)"
    assert_eq "history has the entry once" "1" "$(history_texts | grep -c -x -F -- "$TEXT")"
  done
}

scenario_h() {
  # Regression: the system event raised by our own session deactivation (route change, interruption)
  # arrives after the stop finished. It must never start a new dictation.
  begin "h. late system event after a stop" -LegatoFakeEngine "$TEXT" -LegatoForceTapToCopy NO || return
  trigger toggle
  wait_log "e2e outcome kind=started" 10
  sleep 1.5
  trigger toggle
  wait_log "e2e outcome kind=stopped" 10
  sleep 0.5
  trigger interrupt
  wait_log 'system-event reason="interruption began"' 10
  sleep 1.5
  assert_log "the late event reached the system-event path" 'system-event reason="interruption began"'
  assert_no_log "no system-stop (nothing was running)" "system-stop"
  assert_count "still exactly one outcome=started" "e2e outcome kind=started" 1
  assert_count "still exactly one activity requested" "activity.request phase=starting" 1
  assert_count "still exactly one session built" "session.make" 1
  # Idle is idle: the next press is a normal start.
  trigger toggle
  wait_log_n "e2e outcome kind=started" 2 10
  assert_count "the next press starts" "e2e outcome kind=started" 2
  trigger toggle
  wait_log_n "e2e outcome kind=stopped" 2 10
}

t_run=$SECONDS
for s in a b c d e f g h i; do "scenario_$s"; done
stop_log

# ---------------------------------------------------------------------------------------------- report

echo
printf '%-34s %-58s %s\n' SCENARIO CHECK RESULT
printf '%-34s %-58s %s\n' ---------------------------------- ---------------------------------------------------------- ------
for row in "${ROWS[@]}"; do
  IFS='|' read -r s c r <<< "$row"
  printf '%-34s %-58s %s\n' "$s" "$c" "$r"
done
echo
if [ "${#DETAILS[@]}" -gt 0 ]; then
  echo "Failures:"
  printf '  %s\n' "${DETAILS[@]}"
  echo
fi
echo "Scenarios ran in $((SECONDS - t_run))s (build $((t_run - t_start))s, total $((SECONDS - t_start))s)."
if [ "$FAILED" -gt 0 ]; then echo "FAIL: $FAILED check(s) failed (logs: LEGATO_E2E_KEEP=1)."; LEGATO_E2E_KEEP=1; exit 1; fi
echo "PASS: ${#ROWS[@]} checks."
