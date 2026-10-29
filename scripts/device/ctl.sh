#!/usr/bin/env bash
# Drive the Legato iOS app on a physical iPhone without taps. Pairs with the in-app bridge
# (Apps/iOS/App/Debug/DebugBridge.swift): commands go into a file inbox in the app's data container,
# results come back as JSON lines (Library/Caches/debug-bridge/log.jsonl). Needs a Debug (or internal) build.
#
# Usage: ctl.sh <subcommand> [args...]
#   devices                  list connected devices; says "unlock/plug in" when the iPhone is unavailable
#   build                    xcodegen + signed Debug device build (derived data kept under the cache dir)
#   install                  install the last build on the device
#   launch [args...]        (re)start Legato, e.g. launch -LegatoFakeEngine "hello world"; Debug builds start the bridge
#   send <command> [args...] queue a bridge command, print its id
#   wait <id|event> [secs]   wait (default 30) for a command's done/error line, or for a new line with that event
#   log                      print the bridge log lines not shown yet
#   say <text>               show a dismissable message on the phone
#   ask [--timeout s] <text> <choice>...   show buttons, block until he answers, print the choice (default timeout 300s: prints "timeout")
#   status <text>            persistent banner on the phone; clear removes it and any messages
#   clear                    remove the banner, messages and any tap blocking
#   block on|off             cover the app so taps outside the DEBUG card/banner do nothing
#   background               launch com.apple.Preferences, which pushes Legato to the background
#   foreground               bring Legato forward (no restart)
#   terminate                stop the Legato process
#   pull [--group] <path>    copy a file from the data container (Library/, Documents/, tmp/) or, with
#                            --group, the App Group container, and print it (e.g. pull Library/Caches/audio-diag.jsonl)
#
# Bridge commands (send): ping, commands, state, set-setting <key> <value>, plus in Debug builds every
# simulator e2e command (toggle, interrupt, copy-last, result-insert, result-copy, foreground, background,
# kbd-*, harness-*, meeting-*; see E2E.swift). `commands` lists what the running build accepts.
#
# Environment: LEGATO_DEVICE (UDID, default the project iPhone), LEGATO_DEVICE_TEAM (default XWSGN23W75),
# LEGATO_DEVICE_STATE (scratch dir for pulled logs), LEGATO_CACHE_DIR (build caches).
# Limits: the phone must be unlocked for launch/copy; the keyboard extension and locking the phone
# cannot be driven from here.
set -euo pipefail

# lib.sh changes to the repo root itself.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../ci/lib.sh
source "$HERE/../ci/lib.sh"

DEVICE="${LEGATO_DEVICE:-00008150-000E60360245401C}"
TEAM="${LEGATO_DEVICE_TEAM:-XWSGN23W75}"
BID="de.gruenwald.legato"
GROUP="group.de.gruenwald.legato"
STATE="${LEGATO_DEVICE_STATE:-${TMPDIR:-/tmp}/legato-device-ctl}"
BRIDGE="Library/Caches/debug-bridge"
DERIVED="${LEGATO_CACHE_DIR:-$HOME/Library/Caches/legato}/device-derived/$(pwd | shasum | cut -c1-12)"
APP="$DERIVED/Build/Products/Debug-iphoneos/Legato.app"
mkdir -p "$STATE"

die() { echo "ctl.sh: $*" >&2; exit 1; }

# devicectl wrapper: on failure explains the usual causes (locked, unplugged) instead of the raw dump.
dc() {
  local out rc=0
  out="$(xcrun devicectl "$@" 2>&1)" || rc=$?
  if [ "$rc" -ne 0 ]; then
    if grep -qiE 'locked|passcode' <<< "$out"; then
      echo "ctl.sh: the iPhone is locked: unlock it and retry." >&2
    elif grep -qiE 'no devices|not (found|connected|available)|unavailable|could not connect|timed out' <<< "$out"; then
      echo "ctl.sh: the iPhone is not reachable: unlock it / plug it in (or join the same Wi-Fi) and retry." >&2
    fi
    echo "$out" >&2
    return "$rc"
  fi
  [ -z "$out" ] || printf '%s\n' "$out"
}

# 0 if the target device is listed as available.
# The State column is the text after "(UDID)"; "unavailable" must not match.
device_available() {
  local listing state
  listing="$(xcrun devicectl list devices 2> /dev/null || true)"
  state="$(awk -v d="$DEVICE" 'index($0, d) { sub(/.*\(UDID\) +/, ""); print; exit }' <<< "$listing")"
  case "$state" in available* | connected*) return 0 ;; *) return 1 ;; esac
}

require_device() {
  device_available || {
    echo "ctl.sh: device $DEVICE is not connected or unavailable: unlock the iPhone / plug it in, then retry ('ctl.sh devices')." >&2
    exit 2
  }
}

copy_from() { # copy_from <device path> <local path> [group]
  local domain=(--domain-type appDataContainer --domain-identifier "$BID")
  [ "${3:-}" = group ] && domain=(--domain-type appGroupDataContainer --domain-identifier "$GROUP")
  dc device copy from --device "$DEVICE" "${domain[@]}" --source "$1" --destination "$2" > /dev/null
}

copy_to() { # copy_to <local path> <device path>
  dc device copy to --device "$DEVICE" --domain-type appDataContainer --domain-identifier "$BID" \
    --source "$1" --destination "$2" > /dev/null
}

LOG="$STATE/log.jsonl"
SEEN="$STATE/seen"

pull_log() {
  copy_from "$BRIDGE/log.jsonl" "$LOG" 2> /dev/null || { : > "$LOG"; return 1; }
}

cmd_devices() {
  xcrun devicectl list devices
  device_available || echo "ctl.sh: target $DEVICE is not available: unlock the iPhone / plug it in." >&2
}

cmd_build() {
  select_xcode
  ensure_xcodegen
  (cd Apps/iOS && "$XCODEGEN" generate)
  mkdir -p "$DERIVED"
  echo "building (log: $STATE/build.log)"
  xcodebuild build -quiet -project Apps/iOS/Legato.xcodeproj -scheme Legato -configuration Debug \
    -destination "id=$DEVICE" -derivedDataPath "$DERIVED" -allowProvisioningUpdates \
    DEVELOPMENT_TEAM="$TEAM" > "$STATE/build.log" 2>&1 || { tail -n 30 "$STATE/build.log" >&2; die "build failed"; }
  echo "built $APP"
}

cmd_install() {
  [ -d "$APP" ] || die "no build at $APP: run 'ctl.sh build' first"
  require_device
  dc device install app --device "$DEVICE" "$APP"
}

cmd_launch() {
  require_device
  # `--` keeps app arguments such as -LegatoDebugBridge from being parsed as devicectl options.
  dc device process launch --device "$DEVICE" --terminate-existing -- "$BID" "$@"
}

cmd_send() {
  [ $# -ge 1 ] || die "usage: send <command> [args...]"
  require_device
  # Ids sort in send order (the bridge runs the oldest name first): epoch seconds, then a persistent counter.
  local n=0 id file args=[]
  [ -f "$STATE/seq" ] && n="$(cat "$STATE/seq")"
  n=$((n + 1))
  echo "$n" > "$STATE/seq"
  id="$(printf 'c%010d-%08d' "$(date +%s)" "$n")"
  file="$STATE/$id.json"
  # NUL-separated so values starting with "-" or holding newlines survive.
  [ $# -le 1 ] || args="$(printf '%s\0' "${@:2}" | jq -Rs 'split("\u0000")[:-1]')"
  jq -nc --arg id "$id" --arg command "$1" --argjson args "$args" '{id: $id, command: $command, args: $args}' > "$file"
  deliver "$id" "$file" || { rm -f "$file"; return 1; }
  rm -f "$file"
  echo "$id"
}

# 0 if command <id> reached the phone: its file is still in the inbox or the bridge already logged its id.
landed() {
  local probe="$STATE/landed.probe"
  rm -rf "$probe"
  copy_from "$BRIDGE/inbox/$1.json" "$probe" 2> /dev/null && return 0
  pull_log 2> /dev/null && grep -q "\"id\":\"$1\"" "$LOG"
}

# Copies a command file; CoreDevice sometimes reports an error (7000) although the file arrived, so a failure
# is verified by reading back before a retry. Retries reuse the id and file name, and the bridge drops duplicates.
deliver() { # deliver <id> <file>
  local id="$1" file="$2" try
  for try in 1 2 3; do
    xcrun devicectl device copy to --device "$DEVICE" --domain-type appDataContainer --domain-identifier "$BID" \
      --source "$file" --destination "$BRIDGE/inbox/$id.json" > /dev/null 2>&1 && return 0
    landed "$id" && return 0
    sleep 1
  done
  copy_to "$file" "$BRIDGE/inbox/$id.json" # a last try that prints the reason
}

cmd_say() { cmd_send say "$@"; }
cmd_status() { cmd_send status "$@"; }
cmd_clear() { cmd_send clear; }
cmd_block() { cmd_send block "$@"; }

cmd_ask() {
  local timeout=300
  if [ "${1:-}" = "--timeout" ]; then timeout="${2:?--timeout needs seconds}"; shift 2; fi
  [ $# -ge 2 ] || die "usage: ask [--timeout s] <text> <choice>..."
  local id line deadline="" cap
  id="$(cmd_send ask "$1" --timeout "$timeout" "${@:2}")"
  cap=$((SECONDS + ${LEGATO_ASK_CAP:-3600})) # the card may queue behind others for a long while
  while :; do
    pull_log || true
    # The phone starts the timeout when the card reaches the front (event "shown"); so does this.
    if [ -z "$deadline" ] && jq -e --arg k "$id" 'select(.id == $k and .event == "shown")' "$LOG" > /dev/null 2>&1; then
      deadline=$((SECONDS + timeout + 30))
    fi
    line="$(jq -r --arg k "$id" 'select(.id == $k and (.event == "reply" or .event == "error")) | "\(.event) \(.choice // .message)"' "$LOG" 2> /dev/null || true)"
    line="${line%%$'\n'*}"
    if [ -n "$line" ]; then
      [ "${line%% *}" = reply ] || die "${line#* }"
      echo "${line#* }"
      return 0
    fi
    [ "$SECONDS" -lt "$cap" ] || die "no reply to $id (gave up waiting for it to be shown)"
    [ -z "$deadline" ] || [ "$SECONDS" -lt "$deadline" ] || die "no reply to $id"
    sleep 1
  done
}

cmd_wait() {
  [ $# -ge 1 ] || die "usage: wait <id|event> [timeout]"
  require_device
  local key="$1" timeout="${2:-30}" deadline hit start=0
  pull_log || true
  start="$(wc -l < "$LOG" | tr -d ' ')"
  deadline=$((SECONDS + timeout))
  while :; do
    if [ -s "$LOG" ]; then
      hit="$(jq -c --arg k "$key" --argjson start "$start" -s '
        to_entries | map(select(.value.id == $k or (.key >= $start and .value.event == $k))) | map(.value)
        | if any(.[]; .id == $k) then (map(select(.id == $k)) | if any(.[]; .event == "done" or .event == "error") then .[] else empty end)
          else .[] end' "$LOG" 2> /dev/null || true)"
      if [ -n "$hit" ]; then
        printf '%s\n' "$hit"
        grep -q '"event":"error"' <<< "$hit" && return 1
        return 0
      fi
    fi
    [ "$SECONDS" -lt "$deadline" ] || die "timed out after ${timeout}s waiting for $key"
    sleep 1
    pull_log || true
  done
}

cmd_log() {
  require_device
  pull_log || die "no bridge log on the device yet (is a Debug build running?)"
  local seen=0
  [ -f "$SEEN" ] && seen="$(cat "$SEEN")"
  local total
  total="$(wc -l < "$LOG" | tr -d ' ')"
  [ "$total" -ge "$seen" ] || seen=0 # the log was recreated
  tail -n +"$((seen + 1))" "$LOG"
  echo "$total" > "$SEEN"
}

cmd_background() { require_device; dc device process launch --device "$DEVICE" com.apple.Preferences; }
cmd_foreground() { require_device; dc device process launch --device "$DEVICE" "$BID"; }

cmd_terminate() {
  require_device
  local pid procs
  procs="$(xcrun devicectl device info processes --device "$DEVICE" 2> /dev/null || true)"
  pid="$(awk -v b="/Legato.app/Legato" 'index($0, b) {print $1; exit}' <<< "$procs")"
  [ -n "$pid" ] || { echo "Legato is not running"; return 0; }
  dc device process terminate --device "$DEVICE" --pid "$pid"
}

cmd_pull() {
  local group=""
  [ "${1:-}" = "--group" ] && { group=group; shift; }
  [ $# -eq 1 ] || die "usage: pull [--group] <path>"
  case "/$1/" in */../*) die "pull: '..' is not allowed in $1" ;; esac
  require_device
  local dest="$STATE/pulled/$(basename "$1")"
  mkdir -p "$STATE/pulled"
  rm -rf "$dest"
  copy_from "$1" "$dest" "$group"
  if [ -d "$dest" ]; then ls -l "$dest"; else cat "$dest"; fi
}

sub="${1:-}"
[ $# -eq 0 ] || shift
case "$sub" in
  devices | build | install | launch | send | say | ask | status | clear | block | wait | log | background | foreground | terminate | pull) "cmd_$sub" "$@" ;;
  *) sed -n '2,/^set -euo/p' "${BASH_SOURCE[0]}" | sed '$d' | sed 's/^# \{0,1\}//'; [ -z "$sub" ] || exit 1 ;;
esac
