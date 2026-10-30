#!/usr/bin/env bash
# Queue regression against an already running INTERNAL Mac app. No model/settings/process changes.
# Requires an explicit LEGATO_MAC_ROOT, LEGATO_MAC_PID and Accessibility permission for osascript.
# Starts only with an empty message queue and idle dictation/probe. Leaves evidence in its printed directory.
set -euo pipefail

root="${LEGATO_MAC_ROOT:?set the running internal Mac bridge root}"
pid="${LEGATO_MAC_PID:?set the running internal Mac PID}"
[[ "$pid" =~ ^[0-9]+$ ]] || { echo 'LEGATO_MAC_PID must be numeric' >&2; exit 2; }
[ -d "$root/inbox" ] && [ -f "$root/log.jsonl" ] || { echo 'bridge is not ready' >&2; exit 2; }
[ "$(jq -r 'select(.event == "started") | .pid' "$root/log.jsonl" | tail -1)" = "$pid" ] || {
  echo 'bridge generation does not match LEGATO_MAC_PID' >&2; exit 2;
}
work="$(mktemp -d "${TMPDIR:-/tmp}/legato-mac-overlay-smoke.XXXXXX")"
prefix="overlay-$(uuidgen)"

send() { # send <id> <command> [args...]
  local id="$1" command="$2" args='[]' file
  shift 2
  if [ "$#" -gt 0 ]; then args="$(printf '%s\0' "$@" | jq -Rs 'split("\u0000")[:-1]')"; fi
  file="$(mktemp "$root/inbox/.overlay-smoke.XXXXXX")"
  jq -nc --arg id "$id" --arg command "$command" --argjson args "$args" '{id:$id,command:$command,args:$args}' > "$file"
  mv "$file" "$root/inbox/$id.json"
}
wait_event() { # wait_event <id> <event> <output file>
  local deadline=$((SECONDS + 15)) hit
  while [ "$SECONDS" -lt "$deadline" ]; do
    hit="$(jq -c --arg id "$1" --arg event "$2" 'select(.id == $id and (.event == $event or .event == "error"))' "$root/log.jsonl" 2> /dev/null | tail -1 || true)"
    if [ -n "$hit" ]; then
      printf '%s\n' "$hit" > "$3"
      jq -e --arg event "$2" '.event == $event' "$3" > /dev/null
      return
    fi
    sleep 0.1
  done
  echo "timed out waiting for $1 / $2 (evidence: $work)" >&2
  exit 1
}

send "$prefix-initial" state
wait_event "$prefix-initial" "done" "$work/initial.json"
jq -e '.messages.queued == 0 and .probeRunning == false and .phase == "idle" and .pendingControls == 0' "$work/initial.json" > /dev/null || {
  echo 'requires an empty message queue and idle app; no messages were changed' >&2; exit 2;
}
say_id="$prefix-say"
ask_id="$prefix-ask"
send "$say_id" say 'Queue regression: dismiss this message'
wait_event "$say_id" "done" "$work/say.json"
send "$ask_id" ask 'Queue behind' OK --timeout 0.5
wait_event "$ask_id" "done" "$work/ask.json"
send "$prefix-before" state
wait_event "$prefix-before" "done" "$work/before.json"
jq -e --arg say "$say_id" '.messages.queued == 2 and .messages.currentID == $say' "$work/before.json" > /dev/null
jq -s -e --arg ask "$ask_id" 'all(.[]; .id != $ask or (.event != "shown" and .event != "reply"))' "$root/log.jsonl" > /dev/null

# Dismiss the real first card through its accessibility button in the exact target process.
osascript - "$pid" > "$work/dismiss.txt" <<'APPLESCRIPT'
on run argv
  set targetPID to item 1 of argv as integer
  tell application "System Events"
    set targetProcess to first application process whose unix id is targetPID
    repeat with targetWindow in windows of targetProcess
      set targetElements to get entire contents of targetWindow
      repeat with targetElement in targetElements
        try
          set identifierValue to get value of attribute "AXIdentifier" of targetElement
          if identifierValue is "legato-debug-dismiss" then
            perform action "AXPress" of targetElement
            return "pressed legato-debug-dismiss"
          end if
        end try
      end repeat
    end repeat
  end tell
  error "No dismiss button in target process"
end run
APPLESCRIPT
wait_event "$say_id" dismissed "$work/dismissed.json"
wait_event "$ask_id" shown "$work/shown.json"
wait_event "$ask_id" reply "$work/reply.json"
jq -e '.choice == "timeout"' "$work/reply.json" > /dev/null
send "$prefix-after" state
wait_event "$prefix-after" "done" "$work/after.json"
jq -e '.messages.queued == 0' "$work/after.json" > /dev/null
jq -n --argjson pid "$pid" --arg say "$say_id" --arg ask "$ask_id" \
  --slurpfile before "$work/before.json" --slurpfile shown "$work/shown.json" \
  --slurpfile reply "$work/reply.json" --slurpfile after "$work/after.json" \
  '{pid:$pid,sayID:$say,askID:$ask,before:$before[0],shown:$shown[0],reply:$reply[0],after:$after[0]}' > "$work/report.json"
printf 'PASS Mac queued ask shown -> timeout after actual dismissal; evidence: %s\n' "$work/report.json"
