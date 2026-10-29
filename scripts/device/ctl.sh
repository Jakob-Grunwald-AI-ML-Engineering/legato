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

cd "$(dirname "${BASH_SOURCE[0]}")"
# shellcheck source=../ci/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/../ci/lib.sh"

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
device_available() {
  xcrun devicectl list devices 2> /dev/null | grep -F "$DEVICE" | grep -qiE 'available|connected'
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
  local id="c$(date +%s)-$RANDOM" file
  file="$STATE/$id.json"
  jq -nc --arg id "$id" --arg command "$1" '{id: $id, command: $command, args: $ARGS.positional}' --args "${@:2}" > "$file"
  copy_to "$file" "$BRIDGE/inbox/$id.json"
  echo "$id"
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
  local pid
  pid="$(xcrun devicectl device info processes --device "$DEVICE" 2> /dev/null | awk -v b="/Legato.app/Legato" 'index($0, b) {print $1; exit}')"
  [ -n "$pid" ] || { echo "Legato is not running"; return 0; }
  dc device process terminate --device "$DEVICE" --pid "$pid"
}

cmd_pull() {
  local group=""
  [ "${1:-}" = "--group" ] && { group=group; shift; }
  [ $# -eq 1 ] || die "usage: pull [--group] <path>"
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
  devices | build | install | launch | send | wait | log | background | foreground | terminate | pull) "cmd_$sub" "$@" ;;
  *) sed -n '2,/^set -euo/p' "${BASH_SOURCE[0]}" | sed '$d' | sed 's/^# \{0,1\}//'; [ -z "$sub" ] || exit 1 ;;
esac
