#!/usr/bin/env bash
# Explicit runtime drive of an already installed internal app. No build, cache pruning or other targets.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
cd "$ROOT"
: "${LEGATO_SIMULATOR:?set the already booted test simulator UDID}"
work="${LEGATO_SMOKE_OUTPUT:-$(mktemp -d /tmp/legato-harness-sim-smoke.XXXXXX)}"
mkdir -p "$work"
export LEGATO_STATE="$work/ctl"
log_pid=""
app_started=""
preferences_saved=""
ctl() { bash scripts/device/ctl.sh --target sim "$@"; }
stop_log() {
  if [ -n "$log_pid" ]; then kill "$log_pid" 2> /dev/null || true; wait "$log_pid" 2> /dev/null || true; log_pid=""; fi
}
cleanup() {
  local rc=0
  stop_log
  restore_preferences || rc=1
  if [ -n "$app_started" ]; then ctl terminate || rc=1; app_started=""; fi
  return "$rc"
}
trap 'rc=$?; cleanup || rc=1; exit "$rc"' EXIT
launch() {
  stop_log
  current_log="$work/$1.log"; shift
  xcrun simctl spawn "$LEGATO_SIMULATOR" log stream --level debug --style compact \
    --predicate 'subsystem == "de.gruenwald.legato" AND category == "e2e"' > "$current_log" 2>&1 &
  log_pid=$!
  ctl launch -LegatoFakeEngine 'Harness reliable dictation.' -LegatoForceTapToCopy NO "$@"
}
run() { local id; id="$(ctl send "$@")"; ctl wait "$id" 15; }
state() { run state | jq -s 'map(select(.event == "done")) | last'; }
wait_log() {
  local deadline=$((SECONDS + 15))
  until grep -q -F "$1" "$current_log"; do
    [ "$SECONDS" -lt "$deadline" ] || { echo "missing runtime event: $1" >&2; return 1; }
    sleep 0.1
  done
}
save_preferences() {
  # Launch without fake-engine overrides before reading the three preferences this drive changes.
  ctl launch
  app_started=1
  state | jq -e '.settings | {audioPolicy,debugShowPauseOthers,debugForceTapToCopy}' > "$work/original-settings.json"
  preferences_saved=1
}
restore_preferences() {
  [ -n "$preferences_saved" ] || return 0
  local key
  for key in audioPolicy debugShowPauseOthers debugForceTapToCopy; do
    run set-setting "$key" "$(jq -r --arg key "$key" '.[$key]' "$work/original-settings.json")" > /dev/null || return 1
  done
  state | jq -e --slurpfile expected "$work/original-settings.json" \
    '.settings | {audioPolicy,debugShowPauseOthers,debugForceTapToCopy} == $expected[0]' > /dev/null || return 1
  preferences_saved=""
}
save_preferences
launch held -LegatoFakePreparationHeld YES
held="$(ctl send toggle)"
ctl wait "$held" 5 --ack | jq -s -e 'last.accepted == true' > /dev/null
wait_log 'preparation.wait'
run ping > "$work/held-ping.jsonl"
state > "$work/held-state.json"
probe="$(ctl send session-probe)"
if ctl wait "$probe" 5 > "$work/busy-probe.jsonl"; then echo 'probe accepted during held recording admission' >&2; exit 1; fi
grep -q 'busy' "$work/busy-probe.jsonl"
run preparation-release > "$work/release.jsonl"
ctl wait "$held" 15 > "$work/held-completion.jsonl"
wait_log 'outcome kind=started'
state | jq -e '.isDictating == true' > /dev/null
run stop > "$work/held-stop.jsonl"
state | jq -e '.isDictating == false' > /dev/null
echo 'PASS held toggle accepts, keeps controls responsive, refuses probe and completes after release'
launch cancelled -LegatoFakePreparationHeld YES
held="$(ctl send toggle)"
ctl wait "$held" 5 --ack > "$work/cancel-ack.jsonl"
wait_log 'preparation.wait'
run toggle > "$work/cancel-control.jsonl"
if ctl wait "$held" 5 > "$work/cancelled-completion.jsonl"; then echo 'cancelled start reported success' >&2; exit 1; fi
jq -s -e 'last.outcome == "cancelled"' "$work/cancelled-completion.jsonl" > /dev/null
run preparation-release > "$work/cancel-release.jsonl"
state | jq -e '.isDictating == false' > /dev/null
# The cancellation control joins the original owned operation; this is a settled barrier, not a guessed sleep.
if grep -q 'outcome kind=started' "$current_log"; then echo 'cancelled preparation started late' >&2; exit 1; fi
echo 'PASS cancellation joins admission and release cannot start it late'
launch messages
notice="$(ctl say 'Queue smoke notice')"; ctl wait "$notice" 5 > /dev/null
question="$(ctl send ask 'Queue smoke question' Yes --timeout 1)"; ctl wait "$question" 5 --ack > /dev/null
axe tap --udid "$LEGATO_SIMULATOR" --label 'Dismiss debug message' --wait-timeout 10
axe describe-ui --udid "$LEGATO_SIMULATOR" > "$work/queue-visible.json"
ctl wait "$question" 5 > "$work/queue-timeout.jsonl"
jq -s -e 'last.event == "reply" and last.choice == "timeout"' "$work/queue-timeout.jsonl" > /dev/null
question="$(ctl send ask 'Reply smoke question' Continue Cancel)"; ctl wait "$question" 5 --ack > /dev/null
axe tap --udid "$LEGATO_SIMULATOR" --label 'Answer: Continue' --wait-timeout 10
ctl wait "$question" 5 > "$work/reply.jsonl"
jq -s -e 'last.choice == "Continue"' "$work/reply.jsonl" > /dev/null
run status 'Smoke status' > /dev/null
run block on > /dev/null
run overlay-selftest > "$work/overlay-hit-test.jsonl"
jq -s -e 'last.onCardHits and (last.outsideHits|not) and last.outsideHitsWhileBlocking' "$work/overlay-hit-test.jsonl" > /dev/null
run clear > /dev/null
axe describe-ui --udid "$LEGATO_SIMULATOR" > "$work/cleared.json"
if grep -q 'Smoke status\|Debug mode: taps are blocked\|Reply smoke question' "$work/cleared.json"; then echo 'clear left overlay content visible' >&2; exit 1; fi
echo 'PASS native AX message dismissal/reply, queued presentation timeout, hit testing and clear'
probe="$(ctl send session-probe)"
ctl wait "$probe" 5 --ack > "$work/probe-ack.jsonl"
probe_id="$(jq -r -s 'last.probeID' "$work/probe-ack.jsonl")"
probe_rc=0
ctl wait "$probe" 90 > "$work/probe-terminal.jsonl" || probe_rc=$?
ctl wait "$probe_id" 5 > "$work/probe-history.jsonl" || [ "$probe_rc" -ne 0 ]
jq -s -e 'last.event == "session.probe.done"' "$work/probe-terminal.jsonl" > /dev/null
echo "PASS simulator probe terminal routing (exit=$probe_rc; inspect outcome; this is not physical-model proof)"
ctl pull Library/Caches/debug-bridge/log.jsonl > "$work/bridge.jsonl"
cleanup
trap - EXIT
printf 'PASS simulator smoke; evidence=%s\n' "$work"
