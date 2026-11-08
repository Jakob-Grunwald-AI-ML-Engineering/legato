#!/usr/bin/env bash
# Headless end-to-end check of the iOS app on a simulator: the composer keyboard link and whole-take dictation.
#
# Usage: ios-sim.sh [run|release-check|list]
#   run             (default) build the Debug app, run the scenarios, print a PASS/FAIL table.
#   release-check   build the Release app (arm64 simulator) and verify none of the debug/e2e code is in the binary;
#                   every needle must still occur in the sources (stale-needle control).
#   list            print the scenario names, one per line (no build).
#
# The keyboard extension cannot be loaded headless, so the app is launched with -LegatoKeyboardHarness YES: the
# real KeyboardController and KeyboardRootView over a text view, inside the app (Apps/iOS/App/Debug/KeyboardHarness.swift).
# They talk to the app's own composer and dictation through the real App Group values and Darwin notes, like the
# extension does. Nothing here is faked on the link: the host publishes, the keyboard polls, applies and acknowledges.
# SpeechTranscriber, Soniox and Haiku are never called: the composer draft is seeded (composer-debug-seed) and the
# dictation cleanup is a scripted streaming cleaner (dictation-debug-stream) that capitalizes the take in chunks
# and can fail on cue. The scenarios are driven by `scripts/device/ctl.sh --target sim send <command>` (the bridge
# in Apps/iOS/App/Debug/DebugBridge.swift) and assert on the bridge's replies (harness-state: the field, the surface,
# the draft the keyboard shows, the held take) and on the app's `e2e` os_log lines (subsystem de.gruenwald.legato).
#
# Scenarios (names for LEGATO_E2E_ONLY): composer, take_stream, take_retry, take_insert_raw, take_fail_hook.
#
# Environment:
#   LEGATO_E2E_UDID      use this (already created) simulator; it is shut down afterwards only if the script booted it
#                        and never erased
#   LEGATO_E2E_ERASE=1   at exit shut down and erase (simctl erase) the "legato-e2e" simulator this script owns,
#                        returning its disk space; ignored with LEGATO_E2E_UDID. Default: keep it for the next run
#   LEGATO_E2E_DERIVED   DerivedData directory to use instead of the shared <cache>/derived/ios-sim (unmanaged:
#                        never pruned; see "Build caches" below)
#   LEGATO_E2E_KEEP=1    keep the work directory (logs) and print its path; kept dirs are swept after
#                        LEGATO_E2E_KEEP_DAYS (default 7)
#   LEGATO_CACHE_DIR     root of the shared build caches (default: ~/Library/Caches/legato)
#   LEGATO_E2E_ONLY      space-separated scenario names to run (for example "composer take_retry"); default: all.
#                        An unknown name, or a selection that runs nothing, fails the run.
# Without LEGATO_E2E_UDID a simulator named "legato-e2e" is created once (iPhone, newest iOS 26+ runtime),
# reused by later runs, and shut down at the end.
#
# Work directory: $TMPDIR/legato-e2e.* holds logs only (a few MB), tagged with the owner PID. It is removed on
# exit and on SIGINT/SIGTERM (the running build is killed first). A SIGKILL leaves it behind; every new run first
# sweeps such dirs, never one whose owner is still alive. See scripts/e2e/work-dir.sh.
#
# Build caches (all under LEGATO_CACHE_DIR, so deleting worktrees does not strand gigabytes):
#   SourcePackages/      cloned SwiftPM packages, shared by every checkout and run (-clonedSourcePackagesDirPath;
#                        held locked through resolution and every build read).
#   derived/ios-sim/     the one DerivedData for simulator builds, overwritten by whichever checkout builds next and
#                        shared by every worktree. Builds on it serialize on its lock (OS-backed guard + owner marker;
#                        dead legacy owners are recovered under the guard).
# scripts/dev/prune-build-caches.sh removes every other Legato build output.
set -uo pipefail
# shellcheck source-path=SCRIPTDIR source=../ci/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/../ci/lib.sh"   # also cd's to the repo root

mode="${1:-run}"

# The scenarios, in run order. Each name has a function scenario_<name> below; scripts/e2e/tests/dispatch-test.sh
# checks that the list is not empty and matches the functions.
SCENARIOS=(composer take_stream take_retry take_insert_raw take_fail_hook)
case "$mode" in
  run | release-check | list) ;;
  *) echo "usage: ios-sim.sh [run|release-check|list]"; exit 2 ;;
esac
if [ "$mode" = list ]; then printf '%s\n' "${SCENARIOS[@]}"; exit 0; fi
# The selection is validated before anything is built, so a typo fails in a second, not after the build.
SELECTED=()
if [ "$mode" = run ]; then
  if [ -n "${LEGATO_E2E_ONLY+x}" ]; then
    # shellcheck disable=SC2206 # split on whitespace on purpose
    requested=($LEGATO_E2E_ONLY)
    [ "${#requested[@]}" -gt 0 ] || { echo "LEGATO_E2E_ONLY selects no scenario (known: ${SCENARIOS[*]})"; exit 2; }
    for name in "${requested[@]}"; do
      case " ${SCENARIOS[*]} " in
        *" $name "*) SELECTED+=("$name") ;;
        *) echo "Unknown scenario in LEGATO_E2E_ONLY: <$name> (known: ${SCENARIOS[*]})"; exit 2 ;;
      esac
    done
    [ "${#SELECTED[@]}" -gt 0 ] || { echo "LEGATO_E2E_ONLY selects no scenario (known: ${SCENARIOS[*]})"; exit 2; }
  else
    SELECTED=("${SCENARIOS[@]}")
  fi
fi
BID=de.gruenwald.legato
SIM_NAME=legato-e2e
# shellcheck source-path=SCRIPTDIR source=work-dir.sh
source "$(dirname "${BASH_SOURCE[0]}")/work-dir.sh"

sweep_stale_work_dirs "${TMPDIR:-/tmp}"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/legato-e2e.XXXXXX")"
tag_work_dir "$WORK"
CACHE="$(legato_cache_dir)"
PKGS="$CACHE/SourcePackages"
DERIVED_LOCKED=""
PKGS_LOCKED=""
if [ -n "${LEGATO_E2E_DERIVED:-}" ]; then
  DERIVED="$LEGATO_E2E_DERIVED"
else
  DERIVED="$(derived_dir ios-sim)"
fi
mkdir -p "$PKGS" "$DERIVED"

UDID=""
BOOTED_BY_US=0
LOGPID=""
CHILD=""

cleanup() {
  if declare -F stop_log > /dev/null; then stop_log; fi
  if [ "$BOOTED_BY_US" = 1 ] && [ -n "$UDID" ]; then xcrun simctl shutdown "$UDID" > /dev/null 2>&1; fi
  # Opt-in: give the owned legato-e2e simulator's disk back (never a simulator named by LEGATO_E2E_UDID).
  if [ "${LEGATO_E2E_ERASE:-0}" = 1 ] && [ -n "$UDID" ] && [ -z "${LEGATO_E2E_UDID:-}" ]; then
    xcrun simctl shutdown "$UDID" > /dev/null 2>&1
    xcrun simctl erase "$UDID" > /dev/null 2>&1 && echo "Erased simulator $SIM_NAME ($UDID)"
  fi
  if [ -n "$PKGS_LOCKED" ]; then unlock_dir "$PKGS"; fi
  if [ -n "$DERIVED_LOCKED" ]; then unlock_dir "$DERIVED"; fi
  if [ "${LEGATO_E2E_KEEP:-0}" = 1 ]; then touch "$WORK/keep"; echo "Work directory kept: $WORK"; else rm -rf "$WORK"; fi
}
trap cleanup EXIT

# Run a long foreground command so a signal is handled at once (bash defers traps until a foreground child exits):
# it runs in its own process group and `wait` returns as soon as a trap fires; the trap kills the group.
run_fg() {
  set -m
  "$@" &
  CHILD=$!
  set +m
  wait "$CHILD"
  local rc=$?
  CHILD=""
  return "$rc"
}
on_signal() { # on_signal <exit status>
  local status="$1" i
  trap '' INT TERM
  if [ -n "$CHILD" ]; then
    kill -TERM -- "-$CHILD" 2> /dev/null
    for ((i = 0; i < 100; i++)); do kill -0 "$CHILD" 2> /dev/null || break; sleep 0.1; done
    kill -KILL -- "-$CHILD" 2> /dev/null
    wait "$CHILD" 2> /dev/null
  fi
  exit "$status"
}
trap 'on_signal 130' INT
trap 'on_signal 143' TERM

lock_dir "$DERIVED" || exit 2
DERIVED_LOCKED=1
mkdir -p "$DERIVED" || exit 2

# Test seam (scripts/e2e/tests/cleanup-test.sh): run a stub instead of the real work, so the trap and sweep are testable.
if [ -n "${LEGATO_E2E_TEST_STUB:-}" ]; then run_fg "$LEGATO_E2E_TEST_STUB" "$WORK"; exit $?; fi

# Hold the shared clones through every build read, so pruning and another resolver cannot race it.
lock_dir "$PKGS" || exit 2
PKGS_LOCKED=1
mkdir -p "$PKGS" || exit 2


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

# Resolve under the shared-clone lock held for this entire run. Builds disable automatic resolution.
PKGS_RESOLVED=""
resolve_packages() {
  [ -z "$PKGS_RESOLVED" ] || return 0
  run_fg xcodebuild -resolvePackageDependencies -project Apps/iOS/Legato.xcodeproj -scheme Legato \
    -clonedSourcePackagesDirPath "$PKGS" > "$WORK/resolve.log" 2>&1
  local rc=$?
  [ "$rc" = 0 ] || { tail -30 "$WORK/resolve.log"; echo "Package resolution failed ($WORK/resolve.log)"; LEGATO_E2E_KEEP=1; exit 2; }
  PKGS_RESOLVED=1
}

build_app() { # build_app <configuration> <extra xcodebuild args...>
  local config="$1"; shift
  resolve_packages
  run_fg xcodebuild build -project Apps/iOS/Legato.xcodeproj -scheme Legato -configuration "$config" \
    -destination "${DEST:-generic/platform=iOS Simulator}" -derivedDataPath "$DERIVED" \
    -clonedSourcePackagesDirPath "$PKGS" -disableAutomaticPackageResolution "$@" \
    > "$WORK/build-$config.log" 2>&1 || { tail -30 "$WORK/build-$config.log"; echo "Build failed ($WORK/build-$config.log)"; LEGATO_E2E_KEEP=1; exit 2; }
}

# ---------------------------------------------------------------------------------------------- release check

if [ "$mode" = release-check ]; then
  # Release only, arm64 simulator slice only (half the compile of the default fat build). The scan covers every
  # Mach-O in the bundle, whatever the slice count.
  build_app Release CODE_SIGNING_ALLOWED=NO ARCHS=arm64 ONLY_ACTIVE_ARCH=YES
  app="$DERIVED/Build/Products/Release-iphonesimulator/Legato.app"
  # Identifiers that exist only in the e2e hooks. Positive control (no Debug build): each must still occur in
  # the iOS sources, or the needle is stale (renamed/removed) and the scan would pass vacuously.
  needles=(KeyboardHarness LegatoKeyboardHarness harness-mic harness-mic-hop harness-type harness-numbers
    harness-state harness-visible harness-hidden harness-surface harness-send harness-retry harness-insert-raw harness-clear
    harness.edit LegatoHarnessAppearance LegatoHarnessKeyboardType LegatoHarnessReturn LegatoHarnessGlobe LegatoHarnessLandscape
    LegatoHarnessAutocap LegatoHarnessSuggestions LegatoHarnessSystemField kbd.geometry kbd.view systemfield.document
    harness-mic-hop-retry dictation-debug-stream dictation-debug-mode dictation-debug-model dictation-debug-replay dictation-debug-replay-cancel dictation-debug-fail-take composer-debug-seed
)
  scan() { # every Mach-O file in the bundle: the app, the widget and keyboard extensions, frameworks
    find "$1" -type f -print0 | xargs -0 file | grep -F 'Mach-O' | cut -d: -f1 | tr '\n' '\0' | xargs -0 strings -a
  }
  scan "$app" > "$WORK/release.strings"
  fail=0
  if [ ! -s "$WORK/release.strings" ]; then echo "FAIL  scan found no Mach-O strings in $app"; fail=1; fi
  for n in "${needles[@]}"; do
    if grep -q -F -- "$n" "$WORK/release.strings"; then echo "FAIL  Release contains: $n"; fail=1; fi
  done
  if [ "$fail" = 0 ]; then echo "PASS  Release build contains none of: ${needles[*]}"; fi
  stale=0
  for n in "${needles[@]}"; do
    if ! git grep -q -F -- "$n" -- Apps/iOS; then echo "FAIL  stale needle (not in the sources): $n"; stale=1; fi
  done
  if [ "$stale" = 1 ]; then fail=1; else echo "PASS  control: every needle occurs in the iOS sources"; fi
  bash scripts/ci/check-internal-exclusion.sh ios "$app" || fail=1
  exit "$fail"
fi

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
RAN=0
SCENARIO=""
LOG=""
LOGSEQ=0
REPLY=""         # the last bridge reply (a JSON object)

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

ctl() {
  LEGATO_SIMULATOR="$UDID" LEGATO_BUNDLE="$BID" LEGATO_STATE="$WORK/ctl" bash scripts/device/ctl.sh --target sim "$@"
}

# bridge <command> [args...]: run a bridge command and keep its reply (the done line) in REPLY. Fails with the
# bridge's error line in REPLY when the command is refused.
bridge() {
  local id
  REPLY=""
  id="$(ctl send "$@" 2> "$WORK/ctl.err")" || { REPLY="$(cat "$WORK/ctl.err")"; return 1; }
  REPLY="$(ctl wait "$id" 20 2> "$WORK/ctl.err" | tail -1)" || { REPLY="${REPLY:-$(cat "$WORK/ctl.err")}"; return 1; }
}
# One field of the last reply: strings as they are, other values as JSON, "" when absent.
field() {
  jq -r --arg k "$1" 'if has($k) then (.[$k] | if type == "string" then . else tojson end) else "" end' <<< "$REPLY" 2> /dev/null
}
# The keyboard harness's state field <key> now.
kbd() {
  bridge harness-state || { echo "<bridge: $REPLY>"; return; }
  field "$1"
}

# await_kbd <key> <expected> [timeout seconds]: poll the harness state until the field has the value.
await_kbd() {
  local deadline=$((SECONDS + ${3:-10})) value=""
  while :; do
    value="$(kbd "$1")"
    [ "$value" = "$2" ] && return 0
    [ "$SECONDS" -lt "$deadline" ] || break
    sleep 0.3
  done
  LAST_SEEN="$value"
  return 1
}
LAST_SEEN=""
# check_kbd <description> <key> <expected> [timeout]: PASS once the harness state has the value.
check_kbd() {
  if await_kbd "$2" "$3" "${4:-10}"; then record PASS "$1"; else record FAIL "$1" "$2: expected <$3> got <$LAST_SEEN>"; fi
}

# retry_bridge <timeout seconds> <command> [args...]: a command that is refused until the host has noticed the
# keyboard (its presence) is retried until it is accepted.
retry_bridge() {
  local deadline=$((SECONDS + $1)); shift
  until bridge "$@"; do
    [ "$SECONDS" -lt "$deadline" ] || return 1
    sleep 0.4
  done
}

# begin <scenario name>: clean install, log capture, launch with the in-app keyboard.
begin() {
  SCENARIO="$1"
  stop_log
  xcrun simctl terminate "$UDID" "$BID" > /dev/null 2>&1
  xcrun simctl uninstall "$UDID" "$BID" > /dev/null 2>&1
  xcrun simctl install "$UDID" "$APP" || { record FAIL "install" "simctl install failed"; return 1; }
  LOG="$WORK/${SCENARIO%%.*}-$((++LOGSEQ)).log"
  : > "$LOG"
  xcrun simctl spawn "$UDID" log stream --level debug --style compact \
    --predicate 'subsystem == "de.gruenwald.legato" AND category == "e2e"' > "$LOG" 2>&1 &
  LOGPID=$!
  sleep 1.5
  if ! ctl launch -LegatoKeyboardHarness YES > "$WORK/launch.out" 2>&1; then
    record FAIL "app launches with the bridge" "$(tail -3 "$WORK/launch.out")"; return 1
  fi
  if ! wait_log "harness ready" 15; then record FAIL "keyboard harness is up" "no 'harness ready' line"; return 1; fi
  record PASS "app launches, keyboard harness is up"
}

# ---------------------------------------------------------------------------------------------- scenarios

# await_host_open <true|false>: poll the host's keyboard session until it matches (the keyboard's presence).
await_host_open() {
  local deadline=$((SECONDS + 10)) value=""
  while :; do
    bridge composer-state && value="$(jq -r '.keyboardSession.open' <<< "$REPLY")"
    [ "$value" = "$1" ] && return 0
    [ "$SECONDS" -lt "$deadline" ] || return 1
    sleep 0.3
  done
}

scenario_composer() {
  # The composer surface: the host's draft reaches the keyboard over the link, the keyboard's presence reaches the
  # host, and Send types the draft into the field exactly once.
  begin composer || return
  local draft="Meet at noon and bring the budget"
  bridge harness-surface composer && bridge harness-visible
  check_kbd "keyboard is visible on the composer surface" visible true
  assert_eq "keyboard surface" composer "$(kbd surface)"
  if await_host_open true; then record PASS "host sees the keyboard appear"; else record FAIL "host sees the keyboard appear" "keyboardSession.open stayed false"; fi
  bridge composer-debug-seed "$draft" || { record FAIL "seed a draft" "$REPLY"; return; }
  check_kbd "keyboard shows the host's draft" composerText "$draft"
  bridge harness-hidden
  check_kbd "keyboard hides" visible false
  if await_host_open false; then record PASS "host sees the keyboard hide"; else record FAIL "host sees the keyboard hide" "keyboardSession.open stayed true"; fi
  # A new appearance starts a fresh composition on the host, so the draft is seeded again.
  bridge harness-visible
  if await_host_open true; then record PASS "host sees the keyboard reappear"; else record FAIL "host sees the keyboard reappear" "keyboardSession.open stayed false"; fi
  bridge composer-debug-seed "$draft" || { record FAIL "seed the draft again" "$REPLY"; return; }
  check_kbd "keyboard shows the draft again" composerText "$draft"
  assert_eq "nothing typed before Send" "" "$(kbd text)"
  bridge harness-send
  check_kbd "Send types the draft into the field" text "$draft"
  check_kbd "Send is acknowledged by the host" pendingInsert false
  sleep 2
  assert_eq "the draft is in the field exactly once" "$draft" "$(kbd text)"
  assert_log "keyboard logged the typing" "harness.edit"
}

# Open the dictation surface and wait until the host accepts debug lines (it has noticed the keyboard).
open_dictation() {
  bridge harness-clear
  bridge harness-surface typing && bridge harness-visible
  check_kbd "keyboard is visible on the ABC dictation surface" visible true
  # These legs exercise the take path; the default mode types as you speak (`live`).
  bridge dictation-debug-mode onStop || record FAIL "set the send mode" "$REPLY"
  bridge dictation-debug-stream "$@" || record FAIL "scripted streaming cleaner" "$REPLY"
}
# take <text>: speak one line and end the take as the mic key does.
take() {
  retry_bridge 15 dictation-debug-line "$1" || { record FAIL "host accepts a dictated line" "$REPLY"; return 1; }
  bridge dictation-debug-stop || { record FAIL "end the take" "$REPLY"; return 1; }
}

scenario_take_stream() {
  # A take is cleaned in one streamed call and typed progressively; the field ends with the complete cleaned text.
  begin take_stream || return
  open_dictation 60
  take "the quick brown fox jumps" || return
  check_kbd "cleaned take is typed completely" text "The Quick Brown Fox Jumps" 20
  local edits
  edits="$(grep -c -F 'harness.edit' "$LOG")"
  if [ "$edits" -ge 4 ]; then record PASS "take arrives progressively ($edits edits)"; else record FAIL "take arrives progressively" "only $edits edits"; fi
  sleep 1.5
  assert_eq "take is in the field exactly once" "The Quick Brown Fox Jumps" "$(kbd text)"
  assert_eq "no failure is reported afterwards" false "$(kbd takeFailed)"
}

# fail_take: speak a take whose stream fails after two chunks, and wait for the failed state.
fail_take() {
  open_dictation 40 2
  take "the quick brown fox" || return 1
  check_kbd "failed take is reported to the keyboard" takeFailed true 20
  assert_eq "failed take holds the failed phase" failed "$(kbd takePhase)"
}

scenario_take_retry() {
  # Retry after a failed take: the partial text is erased and the cleaned take is typed once.
  begin take_retry || return
  fail_take || return
  bridge harness-retry
  check_kbd "Retry types the cleaned take" text "The Quick Brown Fox" 20
  check_kbd "failed state clears after Retry" takeFailed false
  sleep 1.5
  assert_eq "retried take is in the field exactly once" "The Quick Brown Fox" "$(kbd text)"
}

scenario_take_insert_raw() {
  # Insert as-is after a failed take: the partial text is erased and the raw words are typed once.
  begin take_insert_raw || return
  fail_take || return
  bridge harness-insert-raw
  check_kbd "Insert as-is types the raw take" text "The quick brown fox" 20
  check_kbd "failed state clears after Insert as-is" takeFailed false
  sleep 1.5
  assert_eq "raw take is in the field exactly once" "The quick brown fox" "$(kbd text)"
}

scenario_take_fail_hook() {
  # The forced failure (dictation-debug-fail-take) fails before any text streams: nothing is typed until Retry.
  begin take_fail_hook || return
  open_dictation 40
  bridge dictation-debug-fail-take 1
  take "send the report today" || return
  check_kbd "forced failure is reported to the keyboard" takeFailed true 20
  assert_eq "nothing is typed while the take is held" "" "$(kbd text)"
  bridge harness-retry
  check_kbd "Retry types the cleaned take" text "Send The Report Today" 20
  sleep 1.5
  assert_eq "retried take is in the field exactly once" "Send The Report Today" "$(kbd text)"
}

# ---------------------------------------------------------------------------------------------- dispatch

t_run=$SECONDS
for name in "${SELECTED[@]}"; do
  if ! declare -F "scenario_$name" > /dev/null; then
    SCENARIO="$name"; record FAIL "scenario function exists" "scenario_$name is not defined"; continue
  fi
  RAN=$((RAN + 1))
  "scenario_$name"
  stop_log
done
xcrun simctl terminate "$UDID" "$BID" > /dev/null 2>&1

# ---------------------------------------------------------------------------------------------- report

echo
printf '%-20s %-62s %s\n' SCENARIO CHECK RESULT
printf '%-20s %-62s %s\n' -------------------- -------------------------------------------------------------- ------
for row in "${ROWS[@]}"; do
  IFS='|' read -r s c r <<< "$row"
  printf '%-20s %-62s %s\n' "$s" "$c" "$r"
done
echo
if [ "${#DETAILS[@]}" -gt 0 ]; then
  echo "Failures:"
  printf '  %s\n' "${DETAILS[@]}"
  echo
fi
echo "Scenarios ran in $((SECONDS - t_run))s (build $((t_run - t_start))s, total $((SECONDS - t_start))s)."
if [ "$RAN" -eq 0 ]; then echo "FAIL: no scenario ran."; exit 1; fi
if [ "${#ROWS[@]}" -eq 0 ]; then echo "FAIL: scenarios ran but recorded no checks."; exit 1; fi
if [ "$FAILED" -gt 0 ]; then echo "FAIL: $FAILED check(s) failed (logs: LEGATO_E2E_KEEP=1)."; LEGATO_E2E_KEEP=1; exit 1; fi
echo "PASS: ${#ROWS[@]} checks in $RAN scenario(s)."
