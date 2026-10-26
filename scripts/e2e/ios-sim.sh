#!/usr/bin/env bash
# Headless end-to-end check of the iOS app on a simulator. See Apps/iOS/App/Debug/E2E.swift for the hooks.
#
# Usage: ios-sim.sh [run|release-check]
#   run             (default) build the Debug app, run the scenarios, print a PASS/FAIL table.
#   release-check   build the Release app and verify none of the fake/e2e code is in the binary.
#
# SpeechTranscriber and the microphone don't work on the Simulator and there is no Action Button, so the
# app runs with a scripted engine and a fake mic (-LegatoFakeEngine) and is driven by Darwin notifications
# (`notifyutil -p de.gruenwald.legato.e2e.<toggle|interrupt|copy-last|kbd-...>`). The keyboard extension is
# stood in for by a fake keyboard inside the app (kbd-* commands) that speaks the real link protocol. Everything else is the real
# app: ActivityKit (Live Activities), UIPasteboard, the history file in the App Group container, the
# AVAudioSession interruption observer. Assertions read the app's `e2e` os_log lines
# (subsystem de.gruenwald.legato), `simctl pbpaste` and the history file.
#
# Environment:
#   LEGATO_E2E_UDID      use this (already created) simulator; it is shut down afterwards only if the script booted it
#   LEGATO_E2E_DERIVED   DerivedData directory to reuse between runs (default: a temp dir, removed on exit)
#   LEGATO_E2E_KEEP=1    keep the work directory (logs) and print its path
#   LEGATO_E2E_SHOTS     directory for the keyboard screenshots (scenario s; default: inside the work directory)
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
    LegatoFakeBackground LegatoFakeBackgroundRefusal start.route toggle-after-hop
    E2EFakeKeyboard LegatoKeepAliveSeconds LegatoFakeKeyboardApply kbd-hop-start kbd.apply "link.host phase="
    KeyboardHarness LegatoKeyboardHarness harness-mic harness-type harness-numbers LegatoHarnessAppearance
    LegatoHarnessKeyboardType LegatoHarnessReturn LegatoHarnessGlobe LegatoHarnessLandscape LegatoHarnessAutocap LegatoHarnessSuggestions
    LegatoHarnessSystemField kbd.geometry kbd.view systemfield.document)
  scan() { # every Mach-O file in the bundle: the app, the widget and keyboard extensions, frameworks
    find "$1" -type f \( -name 'Legato*' -o -name '*.dylib' \) -print0 | xargs -0 strings -a
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
# Same, on the last matching line.
log_field_last() { # log_field_last <line marker> <key>
  grep -F -- "$1" "$LOG" | tail -1 | sed -n "s/.*[ ]$2=\"\\([^\"]*\\)\".*/\\1/p"
}
last_line() { grep -F -- "$1" "$LOG" | tail -1; }

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
  # the start is attempted in the background all the same (it can work, ducked); there is no hop.
  begin "g. music + background" -LegatoFakeEngine "$TEXT" -LegatoFakeOtherAudio YES -LegatoFakeBackground YES -LegatoForceTapToCopy NO || return
  trigger toggle
  wait_log "e2e outcome kind=started" 10
  assert_log "start.route: ran in the background, music seen" "start.route route=background reason=none outcome=started otherAudio=true"
  assert_no_log "no foreground hop" "kind=needsForeground"
  assert_log "activity requested first" "activity.request phase=starting"
  assert_order "request before audio starts" "activity.request phase=starting" "audio.start"
  assert_no_log "no activity dismissed" "activity.dismiss"
  sleep 1.5
  trigger toggle
  wait_log "e2e outcome kind=stopped" 10
  sleep 0.5
  assert_eq "activity ended (copied) with the text" "$TEXT" "$(log_field "activity.end phase=copied" tail)"
  assert_eq "pbpaste == text" "$TEXT" "$(pasteboard)"
  assert_eq "history has the entry once" "1" "$(history_texts | grep -c -x -F -- "$TEXT")"
  assert_count "exactly one activity requested" "activity.request phase=" 1
  assert_count "exactly one session built" "session.make" 1

  # Music, and the system refuses the background start: the hop, then the foreground retry.
  SCENARIO="g. music + background, refused, after the hop"
  relaunch -LegatoFakeEngine "$TEXT" -LegatoFakeOtherAudio YES -LegatoFakeBackground YES -LegatoFakeBackgroundRefusal pla -LegatoForceTapToCopy NO || return
  trigger toggle
  wait_log "e2e outcome kind=needsForeground" 10
  assert_log "start.route: hop after the refusal, music seen" "start.route route=foregroundHop reason=backgroundStartRefused outcome=needsForeground otherAudio=true"
  trigger foreground
  wait_log "e2e command foreground" 10
  trigger toggle-after-hop
  wait_log "e2e outcome kind=started" 10
  assert_log "start.route: ran as a foreground hop" "start.route route=foregroundHop reason=backgroundStartRefused outcome=started"
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


# ----------------------------------------------------------------------------- keyboard link scenarios
# The fake keyboard (E2EFakeKeyboard) publishes presence, sends requests and types the streamed text
# into an in-memory field with the real ProxyEditPlanner, over the real App Group values and Darwin notes.

# run_once <n>: one Action Button dictation (start, ~1.5 s of script, stop); n counts the run in the log.
run_once() {
  trigger toggle
  wait_log_n "e2e outcome kind=started" "$1" 10
  sleep 1.5
  trigger toggle
  wait_log_n "e2e outcome kind=stopped" "$1" 10
  sleep 0.5
}

scenario_p() {
  begin "p. keyboard visible: streams" -LegatoFakeEngine "$TEXT" -LegatoForceTapToCopy NO || return
  xcrun simctl pbcopy "$UDID" <<< "sentinel"
  trigger kbd-visible
  wait_log "e2e kbd.visible value=1" 10
  run_once 1
  assert_log "press routes to the keyboard, activity still required" "route target=keyboard activity=required keepAliveSeconds=0"
  assert_order "activity requested before audio starts" "activity.request phase=starting" "audio.start"
  assert_log "host published the listening state" "link.host phase=listening final=0 target=keyboard"
  assert_eq "keyboard field == script" "$TEXT " "$(log_field "kbd.apply final=1" doc)"
  assert_eq "final link.host committed == script" "$TEXT " "$(log_field "link.host phase=idle final=1" committed)"
  assert_eq "clipboard untouched (the text landed)" "sentinel" "$(pasteboard)"
  assert_no_log "clipboard not written" "clipboard.write source=coordinator"
  assert_eq "activity ended (copied) with the text" "$TEXT" "$(log_field "activity.end phase=copied" tail)"
  assert_eq "history has the entry once" "1" "$(history_texts | grep -c -x -F -- "$TEXT")"
  assert_log "session released (no keep-alive)" "session.deactivate"
}

scenario_j() {
  begin "j. keyboard never confirms: copied" -LegatoFakeEngine "$TEXT" -LegatoForceTapToCopy NO -LegatoFakeKeyboardApply NO || return
  xcrun simctl pbcopy "$UDID" <<< "sentinel"
  trigger kbd-visible
  wait_log "e2e kbd.visible value=1" 10
  run_once 1
  assert_log "press routes to the keyboard" "route target=keyboard"
  assert_no_log "nothing was typed" "kbd.apply"
  assert_eq "final link.host committed == script" "$TEXT " "$(log_field "link.host phase=idle final=1" committed)"
  assert_eq "pbpaste == text (the keyboard did not confirm)" "$TEXT" "$(pasteboard)"
  assert_log "clipboard written by the coordinator" "clipboard.write source=coordinator changed=true"
  assert_eq "activity ended (copied) with the text" "$TEXT" "$(log_field "activity.end phase=copied" tail)"
}

scenario_o() {
  begin "o. keyboard hidden: as before" -LegatoFakeEngine "$TEXT" -LegatoForceTapToCopy NO -LegatoKeepAliveSeconds 30 || return
  xcrun simctl pbcopy "$UDID" <<< "sentinel"
  trigger kbd-visible
  wait_log "e2e kbd.visible value=1" 10
  trigger kbd-hidden
  wait_log "e2e kbd.visible value=0" 10
  run_once 1
  assert_log "press routes to the app: activity required, no keep-alive" "route target=app activity=required keepAliveSeconds=0"
  assert_log "session built without linger" "lingerSeconds=0"
  assert_eq "pbpaste == text" "$TEXT" "$(pasteboard)"
  assert_no_log "nothing typed into a keyboard" "kbd.apply"
  assert_log "session released at once" "session.deactivate"
  assert_eq "activity ended (copied) with the text" "$TEXT" "$(log_field "activity.end phase=copied" tail)"
}

scenario_k() {
  begin "k. keep-alive: one session, two runs" -LegatoFakeEngine "$TEXT" -LegatoForceTapToCopy NO -LegatoKeepAliveSeconds 30 || return
  trigger kbd-visible
  wait_log "e2e kbd.visible value=1" 10
  run_once 1
  run_once 2
  assert_count "a single session built" "session.make" 1
  assert_log "built with the 30 s linger" "lingerSeconds=30"
  assert_count "audio session activated once" "session.activate" 1
  assert_count "mic armed once" "audio.start" 1
  assert_count "second run re-routed the armed mic" "audio.route" 1
  assert_count "nothing released between the runs" "session.deactivate" 0
  assert_count "an activity per run" "activity.request phase=starting" 2
  assert_eq "history has both entries" "2" "$(history_texts | grep -c -x -F -- "$TEXT")"
  assert_eq "keyboard field == script twice" "$TEXT $TEXT " "$(log_field_last "kbd.apply final=1" doc)"
  assert_log "lease published (remote start allowed)" "lease=1 accepts=1"
  trigger kbd-request-end-keep-alive
  wait_log "session.deactivate" 10
  sleep 0.5
  assert_log "end request acked accepted" "kbd.ack result=accepted"
  assert_count "ending the keep-alive released the session" "session.deactivate" 1
  if last_line "link.host" | grep -q -F "lease=0 accepts=0"; then record PASS "host publishes the lease as gone"
  else record FAIL "host publishes the lease as gone" "last link.host: $(last_line "link.host" | cut -c1-200)"; fi
}

scenario_l() {
  begin "l. keep-alive expires" -LegatoFakeEngine "$TEXT" -LegatoForceTapToCopy NO -LegatoKeepAliveSeconds 2 || return
  trigger kbd-visible
  wait_log "e2e kbd.visible value=1" 10
  run_once 1
  assert_count "held right after the run" "session.deactivate" 0
  wait_log "session.deactivate" 8
  assert_count "released when the 2 s ran out" "session.deactivate" 1
  sleep 0.5
  if last_line "link.host" | grep -q -F "lease=0 accepts=0"; then record PASS "host publishes the lease as gone"
  else record FAIL "host publishes the lease as gone" "last link.host: $(last_line "link.host" | cut -c1-200)"; fi
  run_once 2
  assert_count "after expiry the next run builds a new session" "session.make" 2
  assert_count "and activates the audio session again" "session.activate" 2
}

scenario_m() {
  begin "m. remote start and stop (lease held)" -LegatoFakeEngine "$TEXT" -LegatoForceTapToCopy NO -LegatoKeepAliveSeconds 30 || return
  trigger kbd-visible
  wait_log "e2e kbd.visible value=1" 10
  run_once 1
  trigger kbd-request-start
  wait_log_n "e2e outcome kind=started" 2 10
  assert_log "start acked accepted" "kbd.ack result=accepted"
  assert_log "remote start: keyboard target, best-effort activity" "route target=keyboard activity=bestEffort keepAliveSeconds=30"
  sleep 1.5
  trigger kbd-request-stop
  wait_log_n "e2e outcome kind=stopped" 2 10
  sleep 0.5
  assert_count "stop acked accepted too" "kbd.ack result=accepted" 2
  assert_count "still one session" "session.make" 1
  assert_count "mic armed once" "audio.start" 1
  assert_eq "keyboard field == script twice" "$TEXT $TEXT " "$(log_field_last "kbd.apply final=1" doc)"

  SCENARIO="m. remote start without a lease"
  relaunch -LegatoFakeEngine "$TEXT" -LegatoForceTapToCopy NO || return
  trigger kbd-visible
  wait_log "e2e kbd.visible value=1" 10
  trigger kbd-request-start
  wait_log "kbd.ack" 5
  sleep 1
  assert_log "no lease: the keyboard is told to hop" "kbd.ack result=hop"
  assert_no_log "nothing started" "e2e outcome kind=started"
  assert_no_log "no session built" "session.make"
}

scenario_n() {
  begin "n. hop: one run per request id" -LegatoFakeEngine "$TEXT" -LegatoForceTapToCopy NO || return
  trigger kbd-hop-start
  wait_log "e2e outcome kind=started" 10
  sleep 2
  assert_count "one run started (request + URL deduped)" "e2e outcome kind=started" 1
  assert_count "one activity" "activity.request phase=starting" 1
  assert_log "hop screen shown" "hop shown"
  assert_log "run targets the keyboard" "link.host phase=listening final=0 target=keyboard"
  assert_no_log "the keyboard was not left waiting" "kbd.ack result=timeout"
  trigger kbd-request-stop
  wait_log "e2e outcome kind=stopped" 10
  sleep 0.5
  assert_count "stopped once" "e2e outcome kind=stopped" 1
  assert_log "keyboard not visible: stop acked" "kbd.ack result=accepted"

  SCENARIO="n. hop, URL first"
  relaunch -LegatoFakeEngine "$TEXT" -LegatoForceTapToCopy NO || return
  trigger kbd-hop-start-url-first
  wait_log "e2e outcome kind=started" 10
  sleep 2
  assert_count "one run started" "e2e outcome kind=started" 1
  assert_count "one activity" "activity.request phase=starting" 1
  assert_log "hop screen shown" "hop shown"
  trigger kbd-request-stop
  wait_log "e2e outcome kind=stopped" 10
  sleep 0.5
  assert_eq "history has one entry per hop run (two in all)" "2" "$(history_texts | grep -c -x -F -- "$TEXT")"
}

scenario_q() {
  # The keyboard's own UI code (KeyboardController, KeyboardRootView, MicKey) in the app's harness, over a
  # UITextView document, on the real App Group values and Darwin notes: the keyboard-side planner types
  # the fake engine's text into the harness document, and the mic key talks to the real app.
  begin "q. harness: Action Button streams into the keyboard UI" -LegatoFakeEngine "$TEXT" -LegatoForceTapToCopy NO -LegatoKeyboardHarness YES || return
  xcrun simctl pbcopy "$UDID" <<< "sentinel"
  wait_log "e2e harness visible value=1" 10
  assert_log "the harness keyboard beats presence" "harness visible value=1"
  run_once 1
  assert_log "press routes to the keyboard" "route target=keyboard activity=required keepAliveSeconds=0"
  assert_eq "harness document == script" "$TEXT " "$(log_field "harness apply final=1" doc)"
  assert_eq "final link.host committed == script" "$TEXT " "$(log_field "link.host phase=idle final=1" committed)"
  assert_eq "clipboard untouched (the text landed)" "sentinel" "$(pasteboard)"
  assert_no_log "clipboard not written" "clipboard.write source=coordinator"
  assert_eq "history has the entry once" "1" "$(history_texts | grep -c -x -F -- "$TEXT")"

  # The mic key with the microphone held (keep-alive): a request over the link, no hop.
  SCENARIO="q. harness: mic key, remote start and stop"
  relaunch -LegatoFakeEngine "$TEXT" -LegatoForceTapToCopy NO -LegatoKeepAliveSeconds 30 -LegatoKeyboardHarness YES || return
  wait_log "e2e harness visible value=1" 10
  run_once 1
  trigger harness-mic
  wait_log "harness mic mode=remote-start" 10
  wait_log_n "e2e outcome kind=started" 2 10
  assert_log "the mic key asked the running app to start" "harness mic mode=remote-start"
  assert_log "the app acked accepted" "harness ack result=accepted"
  assert_log "remote start: keyboard target, best-effort activity" "route target=keyboard activity=bestEffort keepAliveSeconds=30"
  sleep 1.5
  trigger harness-mic
  wait_log "harness mic mode=remote-stop" 10
  wait_log_n "e2e outcome kind=stopped" 2 10
  sleep 0.5
  assert_log "the mic key asked the running app to stop" "harness mic mode=remote-stop"
  assert_count "both requests acked accepted" "harness ack result=accepted" 2
  assert_count "still one session" "session.make" 1
  assert_eq "harness document == script twice" "$TEXT $TEXT " "$(log_field_last "harness apply final=1" doc)"

  # No running app to ask: the mic key is an open-app key; the request goes out all the same and the
  # idle app answers hop (the URL, which the Link opens, is what starts the run).
  SCENARIO="q. harness: mic key, app not running a lease"
  relaunch -LegatoFakeEngine "$TEXT" -LegatoForceTapToCopy NO -LegatoKeyboardHarness YES || return
  wait_log "e2e harness visible value=1" 10
  trigger harness-mic
  wait_log "harness ack" 5
  sleep 0.5
  assert_log "no lease: the mic key opens the app" "harness mic mode=openApp"
  assert_log "the idle app answers hop" "harness ack result=hop"
  assert_no_log "nothing started over the link" "e2e outcome kind=started"
}

scenario_t() {
  # The typing engine through the keyboard's real commit path (TypingModel over the harness document):
  # autocapitalization, shift and caps lock, double-space period, delete, pages. The expected texts are
  # written here, not derived from the code under test.
  begin "t. harness: typing rules" -LegatoKeyboardHarness YES || return
  wait_log "e2e harness ready" 10
  assert_eq "return key label (en)" "return" "$(log_field "harness ready" returnLabel)"
  assert_eq "space key label (en)" "space" "$(log_field "harness ready" spaceLabel)"
  assert_eq "letters page rows have 10, 9, 9 and 4 keys (no globe)" "10,9,9,4" "$(sed -n 's/.* keys=\([0-9,]*\).*/\1/p' "$LOG" | head -1)"
  trigger harness-type
  wait_log "harness typing case=double-space-after-punctuation " 10
  sleep 0.3
  local pair name expected
  for pair in "autocap=Hi" "double-space=Hi. There" "single-space=Hi there" "shift=Hi Bye" "caps-lock=Hi ABc" \
    "delete=Hello wor" "delete-recapitalizes=C" "numbers=Ab12c" "double-space-after-punctuation=Ok,  x"; do
    name="${pair%%=*}"; expected="${pair#*=}"
    assert_eq "typing: $name" "$expected" "$(log_field "harness typing case=$name " text)"
  done

  SCENARIO="t. harness: German labels, email and number fields"
  relaunch -LegatoKeyboardHarness YES -LegatoHarnessReturn send -AppleLanguages "(de)" || return
  wait_log "e2e harness ready" 10
  assert_eq "return key label (de, send)" "Senden" "$(log_field "harness ready" returnLabel)"
  assert_eq "space key label (de)" "Leerzeichen" "$(log_field "harness ready" spaceLabel)"
  relaunch -LegatoKeyboardHarness YES -LegatoHarnessKeyboardType email -LegatoHarnessGlobe YES || return
  wait_log "e2e harness ready" 10
  assert_eq "email letters page: bottom row adds @ and . (globe shown)" "10,9,9,7" "$(sed -n 's/.* keys=\([0-9,]*\).*/\1/p' "$LOG" | head -1)"
  relaunch -LegatoKeyboardHarness YES -LegatoHarnessKeyboardType phone || return
  wait_log "e2e harness ready" 10
  assert_eq "phone field: numpad rows (3 columns, bottom row + 0 delete)" "3,3,3,3" "$(sed -n 's/.* keys=\([0-9,]*\).*/\1/p' "$LOG" | head -1)"
  relaunch -LegatoKeyboardHarness YES -LegatoHarnessKeyboardType numbers || return
  wait_log "e2e harness ready" 10
  assert_log "numbers-and-punctuation field starts on the numbers page" "page=numbers"
}

scenario_s() {
  # Screenshots of the keyboard UI in the harness: light, dark, landscape and a few field types. Saved to
  # $LEGATO_E2E_SHOTS (default: inside the work directory, so only the size is checked).
  local dir="${LEGATO_E2E_SHOTS:-$WORK/shots}"
  mkdir -p "$dir"
  local name file
  shot() { # shot <name> <launch args...>: relaunch the harness with the args, then take the screenshot
    name="$1"; shift
    file="$dir/keyboard-$name.png"
    SCENARIO="s. screenshots"
    relaunch -LegatoKeyboardHarness YES "$@" || return 1
    wait_log "e2e harness ready" 10
    sleep 1.2
  }
  take() {
    xcrun simctl io "$UDID" screenshot "$file" > /dev/null 2>&1
    local size; size="$(stat -f %z "$file" 2> /dev/null || echo 0)"
    if [ "$size" -gt 20000 ]; then record PASS "screenshot $name ($size bytes)"; else record FAIL "screenshot $name" "no usable image at $file"; fi
  }
  begin "s. screenshots" -LegatoKeyboardHarness YES -LegatoHarnessAppearance light -LegatoHarnessSuggestions typ,type,tip || return
  wait_log "e2e harness ready" 10
  trigger harness-type   # leaves some text in the field
  sleep 1.2
  name=light; file="$dir/keyboard-light.png"; take
  shot dark -LegatoHarnessAppearance dark -LegatoHarnessSuggestions typ,type,tip && take
  shot landscape -LegatoHarnessAppearance light -LegatoHarnessLandscape YES && {
    take
    sips -r 90 "$file" --out "$file" > /dev/null 2>&1
    local w h
    w="$(sips -g pixelWidth "$file" 2> /dev/null | awk '/pixelWidth/ {print $2}')"
    h="$(sips -g pixelHeight "$file" 2> /dev/null | awk '/pixelHeight/ {print $2}')"
    if [ "${w:-0}" -gt "${h:-1}" ]; then record PASS "landscape screenshot is wider than tall (${w}x${h})"
    else record FAIL "landscape screenshot is wider than tall" "${w}x${h}"; fi
  }
  shot landscape-dark -LegatoHarnessAppearance dark -LegatoHarnessLandscape YES && { take; sips -r 90 "$file" --out "$file" > /dev/null 2>&1; }
  shot numbers -LegatoHarnessAppearance light && { trigger harness-numbers; sleep 1; take; }
  shot email-send -LegatoHarnessAppearance light -LegatoHarnessKeyboardType email -LegatoHarnessReturn send -LegatoHarnessGlobe YES && take
  shot german-go -LegatoHarnessAppearance dark -LegatoHarnessReturn go -AppleLanguages "(de)" && take
  shot phone -LegatoHarnessAppearance light -LegatoHarnessKeyboardType phone -LegatoHarnessGlobe YES && take
  [ "${LEGATO_E2E_SHOTS:-}" != "" ] && echo "Screenshots: $dir"
}

# The last value of key=<value> on the last line matching a fixed string (values without spaces).
log_kv_last() { # log_kv_last <line marker> <key>
  grep -F -- "$1" "$LOG" | tail -1 | sed -n "s/.* $2=\\([^ ]*\\).*/\\1/p"
}

scenario_r() {
  # The real keyboard extension, not the harness: the system presents it for a plain text field, and the
  # extension logs where its keys are (`kbd.geometry`, Debug builds; KeyboardGeometryLog.swift). All four key
  # rows must lie inside the visible keyboard, at the height the extension asked for. Regression for a
  # portrait keyboard (402 x 301) read as landscape because it is wider than tall: 190 pt, rows 3 and 4 cut.
  # Enabling the keyboard: the Settings preferences below (a simulator reads them when the app starts).
  # Screenshots go to $LEGATO_E2E_SHOTS (default: inside the work directory).
  local dir="${LEGATO_E2E_SHOTS:-$WORK/shots}"
  mkdir -p "$dir"
  xcrun simctl spawn "$UDID" defaults write -g AppleKeyboards -array "$BID.keyboard" "en_US@sw=QWERTY;hw=Automatic" "emoji@sw=Emoji"
  xcrun simctl spawn "$UDID" defaults write -g AppleKeyboardsExpanded -int 1
  xcrun simctl spawn "$UDID" defaults write com.apple.Preferences KeyboardsCurrentAndNext -array "$BID.keyboard" "en_US@sw=QWERTY;hw=Automatic"
  local appearance file size
  for appearance in light dark; do
    SCENARIO="r. real extension ($appearance)"
    begin "$SCENARIO" -LegatoKeyboardHarness YES -LegatoHarnessSystemField YES -LegatoHarnessAppearance "$appearance" || return
    if ! wait_log "kbd.geometry" 8; then   # the first launch after the preferences changed may not see the keyboard yet
      relaunch -LegatoKeyboardHarness YES -LegatoHarnessSystemField YES -LegatoHarnessAppearance "$appearance" || return
      wait_log "kbd.geometry" 10
    fi
    sleep 2.5   # the system resizes the keyboard while it comes up; the last layout counts
    assert_log "the system presented the Legato keyboard extension" "kbd.geometry"
    assert_log "the extension asked for the portrait height (301 pt, not landscape's 190)" "constraint=301@999"
    assert_no_log "portrait is never taken for landscape" "constraint=190@"
    assert_eq "the keyboard view is 301 pt high" "301" "$(last_line "kbd.view" | sed -n 's/.* bounds=[0-9-]*,[0-9-]*,[0-9]*x\([0-9]*\) .*/\1/p')"
    assert_eq "all four key rows are inside the visible keyboard" "1" "$(log_kv_last kbd.geometry visible)"
    local bottom height
    bottom="$(log_kv_last kbd.geometry keysMaxY)"
    height="$(last_line kbd.geometry | sed -n 's/.* grid=[0-9-]*,[0-9-]*,[0-9]*x\([0-9]*\) .*/\1/p')"
    if [ -n "$bottom" ] && [ -n "$height" ] && [ "$bottom" -le "$height" ]; then record PASS "lowest key edge ${bottom} pt <= keyboard height ${height} pt"
    else record FAIL "lowest key edge <= keyboard height" "keysMaxY=<$bottom> height=<$height>"; fi
    file="$dir/keyboard-extension-$appearance.png"
    xcrun simctl io "$UDID" screenshot "$file" > /dev/null 2>&1
    size="$(stat -f %z "$file" 2> /dev/null || echo 0)"
    if [ "$size" -gt 20000 ]; then record PASS "screenshot of the real extension ($appearance, $size bytes)"; else record FAIL "screenshot of the real extension ($appearance)" "no usable image at $file"; fi
  done
}

t_run=$SECONDS
for s in a b c d e f g h i p j o k l m n q t r s; do "scenario_$s"; done
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
