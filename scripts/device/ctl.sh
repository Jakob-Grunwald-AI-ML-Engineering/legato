#!/usr/bin/env bash
# Drive the Legato iOS app on a physical iPhone without taps. Pairs with the in-app bridge
# (Apps/iOS/App/Debug/DebugBridge.swift): commands go into a file inbox in the app's data container,
# results come back as JSON lines (Library/Caches/debug-bridge/log.jsonl). Needs a Debug (or internal) build.
#
# Usage: ctl.sh [--target device|sim|mac] <subcommand> [args...]
#   devices                  list connected devices; says "unlock/plug in" when the iPhone is unavailable
#   build                    xcodegen + signed Debug device build (derived data kept under the cache dir)
#   install                  install the last build on the device
#   launch [args...]        (re)start Legato, e.g. launch -LegatoFakeEngine "hello world"; Debug builds start the bridge
#   send <command> [args...] queue a bridge command, print its id
#   wait <id|event> [secs] [--ack]   wait (default 30) for a command's done/error line, or for a new line with that event
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
# LEGATO_DEVICE_TIMEOUT (per-operation cap, 10s), LEGATO_DEVICE_INSTALL_TIMEOUT (120s),
# LEGATO_DEVICE_LAUNCH_TIMEOUT and LEGATO_DEVICE_SEND_TIMEOUT (total budget, 30s each).
# Limits: the phone must be unlocked for launch/copy; the keyboard extension and locking the phone
# cannot be driven from here.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE/../.."

die() { echo "ctl.sh: $*" >&2; exit 1; }
TARGET=device
if [ "${1:-}" = --target ]; then
  [ $# -ge 2 ] || die "--target requires device, sim or mac"
  TARGET="$2"; shift 2
fi
case "$TARGET" in device | sim | mac) ;; *) die "unknown target: $TARGET" ;; esac
DEVICE="${LEGATO_DEVICE:-00008150-000E60360245401C}"
SIM="${LEGATO_SIMULATOR:-${LEGATO_SIM_UDID:-booted}}"
TEAM="${LEGATO_DEVICE_TEAM:-XWSGN23W75}"
BID="${LEGATO_BUNDLE:-${LEGATO_BUNDLE_ID:-de.gruenwald.legato}}"
[ "$TARGET" != mac ] || BID="${LEGATO_BUNDLE:-${LEGATO_BUNDLE_ID:-de.gruenwald.legato.mac}}"
GROUP="${LEGATO_GROUP:-${LEGATO_GROUP_ID:-group.de.gruenwald.legato}}"
MAC_ROOT="${LEGATO_MAC_ROOT:-$HOME/Library/Caches/Legato/debug-bridge}"
case "$MAC_ROOT" in /*) ;; *) die "LEGATO_MAC_ROOT must be an absolute path" ;; esac
case "$BID" in '' | *[!a-zA-Z0-9._-]*) die "invalid bundle identity" ;; esac
case "$GROUP" in group.*) ;; *) die "invalid app group identity" ;; esac
identity="$DEVICE"
[ "$TARGET" != sim ] || identity="$SIM"
[ "$TARGET" != mac ] || identity="$MAC_ROOT"
STATE_BASE="${LEGATO_STATE:-${LEGATO_DEVICE_STATE:-${TMPDIR:-/tmp}/legato-device-ctl}}"
configure_state() {
  local state_key
  case "$1" in
    *[!a-zA-Z0-9._-]*) state_key="$(printf '%s' "$TARGET|$1|$BID" | shasum | cut -c1-16)" ;;
    *) state_key="$BID-$1" ;;
  esac
  STATE="$STATE_BASE/$TARGET-$state_key"
  LOG="$STATE/log.jsonl"; SEEN="$STATE/seen"
  mkdir -p "$STATE"
}
configure_state "$identity"
BRIDGE="Library/Caches/debug-bridge"
DERIVED=""
case "$TARGET" in
  device | sim) APP="${LEGATO_APP:-}" ;;
  mac) APP="${LEGATO_APP:-$HOME/Applications/Legato.app}" ;;
esac
mkdir -p "$STATE"

positive_seconds() {
  case "$1" in '' | *[!0-9]*) die "$2 must be a positive integer" ;; esac
  [ "$1" -gt 0 ] || die "$2 must be a positive integer"
}

# CoreDevice requires a native timeout of at least five seconds. Enforce shorter host budgets
# ourselves, with a private process group so a timed-out tool cannot leave descendants behind.
run_bounded_tool() (
  # Bash 3 unwinds function locals before running the EXIT trap on timeout.
  # This function already has its own subshell: these variables cannot escape it.
  budget="$1" child="" output="" rc=0 end=0 grace=0
  shift
  output="$(mktemp "$STATE/devicectl.XXXXXX")"
  trap 'if [ -n "$child" ]; then kill -KILL -- "-$child" 2> /dev/null || true; wait "$child" 2> /dev/null || true; fi; rm -f "$output"' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM HUP
  end=$((SECONDS + 10#$budget))
  # Enable job control only while creating this child, giving it a separate, captured group ID.
  set -m
  "$@" > "$output" 2>&1 &
  child=$!
  set +m
  while kill -0 "$child" 2> /dev/null; do
    if [ "$SECONDS" -ge "$end" ]; then
      kill -TERM -- "-$child" 2> /dev/null || true
      grace=0
      while kill -0 "$child" 2> /dev/null && [ "$grace" -lt 5 ]; do
        sleep 0.02
        grace=$((grace + 1))
      done
      kill -KILL -- "-$child" 2> /dev/null || true
      wait "$child" 2> /dev/null || true
      child=""
      cat "$output"
      echo "ctl.sh: device operation timed out after ${budget}s (host deadline)" >&2
      exit 124
    fi
    sleep 0.02
  done
  wait "$child" || rc=$?
  child=""
  cat "$output"
  exit "$rc"
)

# devicectl wrapper: on failure explains the usual causes (locked, unplugged) instead of the raw dump.
dc() {
  local out rc=0 limit="${DC_TIMEOUT:-${LEGATO_DEVICE_TIMEOUT:-10}}" remaining native
  positive_seconds "$limit" "device timeout"
  if [ -n "${DC_DEADLINE:-}" ]; then
    remaining=$((DC_DEADLINE - SECONDS))
    [ "$remaining" -gt 0 ] || { echo "ctl.sh: device operation deadline expired" >&2; return 124; }
    [ "$limit" -le "$remaining" ] || limit="$remaining"
  fi
  native="$limit"; [ "$native" -ge 5 ] || native=5
  out="$(run_bounded_tool "$limit" xcrun devicectl --timeout "$native" "$@" 2>&1)" || rc=$?
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
  listing="$(dc list devices)" || return 1
  state="$(awk -v d="$DEVICE" 'index($0, d) { sub(/.*\(UDID\) +/, ""); print; exit }' <<< "$listing")"
  case "$state" in available* | connected*) return 0 ;; *) return 1 ;; esac
}

sc() {
  local limit="${DC_TIMEOUT:-${LEGATO_DEVICE_TIMEOUT:-10}}" remaining
  positive_seconds "$limit" "simulator operation timeout"
  if [ -n "${DC_DEADLINE:-}" ]; then
    remaining=$((DC_DEADLINE - SECONDS))
    [ "$remaining" -gt 0 ] || { echo "ctl.sh: simulator operation deadline expired" >&2; return 124; }
    [ "$limit" -le "$remaining" ] || limit="$remaining"
  fi
  run_bounded_tool "$limit" xcrun simctl "$@"
}
require_device() {
  case "$TARGET" in
    device) device_available || die "device $DEVICE is not connected or unavailable: unlock / plug in, then retry" ;;
    sim)
      if [ "$SIM" = booted ]; then
        local booted
        booted="$(sc list devices booted -j | jq -r '.devices[][] | select(.state == "Booted") | .udid')" || die "could not discover booted simulator"
        [ -n "$booted" ] && [[ "$booted" != *$'\n'* ]] || die "select one simulator with LEGATO_SIMULATOR"
        SIM="$booted"
        configure_state "$SIM"
      fi
      TARGET_DATA_ROOT="$(sc get_app_container "$SIM" "$BID" data)" || die "simulator $SIM or app $BID unavailable"
      [ -d "$TARGET_DATA_ROOT" ] || die "simulator app container unavailable: $TARGET_DATA_ROOT" ;;
    mac) [ -d "$MAC_ROOT" ] || die "Mac harness root unavailable: $MAC_ROOT (launch an internal build)" ;;
  esac
}
local_path() {
  local path="$1" root
  case "$path" in '' | /* | .. | ../* | */../* | */..) die "invalid container-relative path: $path" ;; esac
  if [ "$TARGET" = sim ]; then
    root="$TARGET_DATA_ROOT"
    if [ "${2:-}" = group ]; then root="$(sc get_app_container "$SIM" "$BID" "$GROUP")" || return 1; fi
  else
    if [ "${2:-}" = group ]; then
      [ -n "${LEGATO_MAC_GROUP_ROOT:-}" ] || die "Mac group pull requires LEGATO_MAC_GROUP_ROOT"
      root="$LEGATO_MAC_GROUP_ROOT"
    elif [ "$path" = "$BRIDGE" ]; then printf '%s\n' "$MAC_ROOT"; return
    elif [[ "$path" == "$BRIDGE/"* ]]; then printf '%s/%s\n' "$MAC_ROOT" "${path#"$BRIDGE/"}"; return
    else root="${LEGATO_MAC_DATA_ROOT:-$HOME}"; fi
  fi
  printf '%s/%s\n' "$root" "$path"
}
copy_from() {
  if [ "$TARGET" != device ]; then cp -R "$(local_path "$1" "${3:-}")" "$2"; return; fi
  local domain=(--domain-type appDataContainer --domain-identifier "$BID")
  [ "${3:-}" = group ] && domain=(--domain-type appGroupDataContainer --domain-identifier "$GROUP")
  dc device copy from --device "$DEVICE" "${domain[@]}" --source "$1" --destination "$2" > /dev/null
}
copy_to() {
  if [ "$TARGET" != device ]; then
    local dest staging
    dest="$(local_path "$2")"
    staging="$(mktemp "$dest.XXXXXX")" || return 1
    if ! cp "$1" "$staging" || ! mv "$staging" "$dest"; then rm -f "$staging"; return 1; fi
    return
  fi
  dc device copy to --device "$DEVICE" --domain-type appDataContainer --domain-identifier "$BID" \
    --source "$1" --destination "$2" > /dev/null
}

LOG="$STATE/log.jsonl"
SEEN="$STATE/seen"

pull_log() {
  # An absent destination avoids CoreDevice's ambiguous existing-file behavior. Publish only a
  # complete successful snapshot; a failed/partial transfer must never destroy the last good log.
  local staging rc=0
  # Keep the last transfer diagnostic when the enclosing operation has exhausted its budget.
  if [ -n "${DC_DEADLINE:-}" ] && [ "$SECONDS" -ge "$DC_DEADLINE" ]; then return 124; fi
  staging="$(mktemp -d "$STATE/log.XXXXXX")"
  copy_from "$BRIDGE/log.jsonl" "$staging/log.jsonl" 2> "$STATE/log.error" || rc=$?
  if [ "$rc" -eq 0 ]; then
    mv "$staging/log.jsonl" "$LOG"
    : > "$STATE/log.error"
  fi
  rm -rf "$staging"
  return "$rc"
}

cmd_devices() {
  case "$TARGET" in
    device) dc list devices ;;
    sim) sc list devices available -j ;;
    mac) printf 'app=%s\nharness=%s\n' "$APP" "$MAC_ROOT" ;;
  esac
}
set_derived() {
  DERIVED="${LEGATO_CACHE_DIR:-$HOME/Library/Caches/legato}/device-derived/$(pwd | shasum | cut -c1-12)"
}
cmd_build() {
  # Build machinery is intentionally lazy: polling must not pay for git/Xcode discovery on every call.
  # shellcheck source-path=SCRIPTDIR source=../ci/lib.sh
  source "$HERE/../ci/lib.sh"
  set_derived
  select_xcode
  ensure_xcodegen
  local dir=Apps/iOS project=Legato.xcodeproj destination="id=$DEVICE" extra=(-allowProvisioningUpdates DEVELOPMENT_TEAM="$TEAM")
  case "$TARGET" in
    sim) destination='generic/platform=iOS Simulator'; extra=(CODE_SIGNING_ALLOWED=NO) ;;
    mac) dir=Apps/macOS; project=LegatoMac.xcodeproj; destination='generic/platform=macOS'; extra=(CODE_SIGNING_ALLOWED=NO) ;;
  esac
  (cd "$dir" && "$XCODEGEN" generate)
  mkdir -p "$DERIVED"
  echo "building (log: $STATE/build.log)"
  xcodebuild build -quiet -project "$dir/$project" -scheme Legato -configuration Debug \
    -destination "$destination" -derivedDataPath "$DERIVED" "${extra[@]}" > "$STATE/build.log" 2>&1 || { tail -n 30 "$STATE/build.log" >&2; die "build failed"; }
  echo "built $DERIVED/Build/Products"
}
cmd_install() {
  if [ -z "$APP" ]; then
    set_derived
    local platform=iphoneos
    [ "$TARGET" != sim ] || platform=iphonesimulator
    APP="$DERIVED/Build/Products/Debug-$platform/Legato.app"
  fi
  [ -d "$APP" ] || die "no build at $APP: set LEGATO_APP or run build first"
  local DC_TIMEOUT="${LEGATO_DEVICE_INSTALL_TIMEOUT:-120}"
  positive_seconds "$DC_TIMEOUT" "install timeout"
  case "$TARGET" in
    device) require_device; dc device install app --device "$DEVICE" "$APP" ;;
    sim) sc install "$SIM" "$APP" ;;
    mac) die "Mac install unavailable: launch the build directly with LEGATO_APP=/absolute/path/Legato.app" ;;
  esac
}
cmd_launch() {
  local budget="${LEGATO_DEVICE_LAUNCH_TIMEOUT:-30}"
  positive_seconds "$budget" "launch timeout"
  local DC_DEADLINE=$((SECONDS + 10#$budget))
  local previous="" pid="" result out executable
  if [ "$TARGET" = mac ]; then mkdir -p "$MAC_ROOT/inbox"; fi
  require_device
  pull_log || true
  if [ -f "$LOG" ]; then
    previous="$(jq -r -s '[.[] | select(.event == "started") | (.generation // .ts)] | last // ""' "$LOG")"
  fi
  case "$TARGET" in
    device)
      result="$(mktemp "$STATE/launch.XXXXXX")"
      if ! dc device process launch --json-output "$result" --device "$DEVICE" --terminate-existing -- "$BID" "$@"; then rm -f "$result"; return 1; fi
      pid="$(jq -er '.result.process.processIdentifier' "$result")" || { rm -f "$result"; die "launch returned no process identifier"; }
      rm -f "$result" ;;
    sim)
      out="$(sc launch --terminate-running-process "$SIM" "$BID" "$@")" || return 1
      pid="${out##*: }"
      [[ "$pid" != *[!0-9]* ]] && [ -n "$pid" ] || die "simulator launch returned no process identifier: $out" ;;
    mac)
      [ -d "$APP" ] || die "Mac app unavailable: $APP"
      if [ -f "$STATE/pid" ] && kill -0 "$(cat "$STATE/pid")" 2> /dev/null; then die "this Mac target already runs; use foreground or terminate first"; fi
      executable="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$APP/Contents/Info.plist")"
      local existing
      existing="$(ps -axo pid=,command= -ww | awk -v app="$APP/Contents/MacOS/$executable" '{pid=$1; sub(/^[[:space:]]*[0-9]+[[:space:]]+/, ""); if ($0 == app || index($0, app " ") == 1) {if (!found) found=pid}} END {if (found) print found}')"
      [ -z "$existing" ] || die "Mac app already runs as PID $existing; use foreground or an isolated app composition"
      # LaunchServices owns the app lifetime after this CLI/tool session exits.
      [ "$SECONDS" -lt "$DC_DEADLINE" ] || wait_failure "Mac launch deadline"
      run_bounded_tool "$((DC_DEADLINE - SECONDS))" open -a "$APP" \
        --env "LEGATO_MAC_ROOT=$MAC_ROOT" --stdout "$STATE/app.log" --stderr "$STATE/app.log" --args "$@" || return 1 ;;
  esac
  [ -z "$pid" ] || echo "$pid" > "$STATE/pid"
  while :; do
    if pull_log; then
      if [ "$TARGET" = mac ]; then
        pid="$(jq -r -s --arg previous "$previous" '[.[] | select(.event == "started" and (.generation // .ts) != $previous) | .pid | select(type == "number" and . > 0)] | last // ""' "$LOG")"
        if [ -n "$pid" ]; then
          local process_command
          process_command="$(ps -p "$pid" -o command= -ww)" || process_command=""
          [[ "$process_command" == "$APP/Contents/MacOS/$executable" || "$process_command" == "$APP/Contents/MacOS/$executable "* ]] || pid=""
        fi
      fi
      if [ -n "$pid" ] && jq -e -s --arg previous "$previous" --argjson pid "$pid" \
        'any(.[]; .event == "started" and .pid == $pid and (.generation // .ts) != $previous)' "$LOG" > /dev/null; then echo "$pid" > "$STATE/pid"; return 0; fi
    fi
    [ "$SECONDS" -lt "$DC_DEADLINE" ] || wait_failure "bridge readiness for process $pid"
    sleep 0.2
  done
}

cmd_send() {
  [ $# -ge 1 ] && [ -n "$1" ] || die "usage: send <command> [args...]"
  local budget="${LEGATO_DEVICE_SEND_TIMEOUT:-30}"
  positive_seconds "$budget" "send timeout"
  local DC_DEADLINE=$((SECONDS + 10#$budget))
  require_device
  # Ids sort in send order (the bridge runs the oldest name first): epoch seconds, then a persistent counter.
  local n=0 id file args=[]
  [ -f "$STATE/seq" ] && n="$(cat "$STATE/seq")"
  n=$((10#$n + 1))
  echo "$n" > "$STATE/seq"
  id="$(printf 'c%010d-%08d-%d' "$(date +%s)" "$n" "$$")"
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
  if [ "$TARGET" != device ]; then copy_to "$file" "$BRIDGE/inbox/$id.json"; return; fi
  for try in 1 2 3; do
    dc device copy to --device "$DEVICE" --domain-type appDataContainer --domain-identifier "$BID" \
      --source "$file" --destination "$BRIDGE/inbox/$id.json" > /dev/null 2>&1 && return 0
    landed "$id" && return 0
    [ "$try" -eq 3 ] || sleep 1
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
  positive_seconds "$timeout" "ask timeout"
  positive_seconds "${LEGATO_ASK_CAP:-3600}" "ask cap"
  [ $# -ge 2 ] || die "usage: ask [--timeout s] <text> <choice>..."
  local id line deadline="" cap
  require_device  # Resolve the simulator container in this shell, before send runs in a substitution.
  id="$(cmd_send ask "$1" --timeout "$timeout" "${@:2}")"
  cap=$((SECONDS + 10#${LEGATO_ASK_CAP:-3600})) # the card may queue behind others for a long while
  while :; do
    pull_log || true
    # The phone starts the timeout when the card reaches the front (event "shown"); so does this.
    if [ -z "$deadline" ] && jq -e --arg k "$id" 'select(.id == $k and .event == "shown")' "$LOG" > /dev/null 2>&1; then
      deadline=$((SECONDS + 10#$timeout + 30))
    fi
    line="$(jq -c -s --arg k "$id" '[.[] | select(.id == $k and (.event == "reply" or .event == "error"))] | first // empty' "$LOG" 2> /dev/null || true)"
    if [ -n "$line" ]; then
      if ! jq -e '.event == "reply"' <<< "$line" > /dev/null; then die "$(jq -r '.message' <<< "$line")"; fi
      jq -r '.choice' <<< "$line"
      return 0
    fi
    [ "$SECONDS" -lt "$cap" ] || die "no reply to $id (gave up waiting for it to be shown)"
    [ -z "$deadline" ] || [ "$SECONDS" -lt "$deadline" ] || die "no reply to $id"
    sleep 1
  done
}

wait_failure() {
  if [ -s "$STATE/log.error" ]; then
    cat "$STATE/log.error" >&2
    die "log transfer failed while waiting for $1"
  fi
  die "timed out waiting for $1"
}

cmd_wait() {
  [ $# -ge 1 ] || die "usage: wait <id|event> [timeout] [--ack]"
  local key="$1" timeout=30 ack=false supplied=false hit start=0
  shift
  for arg in "$@"; do
    case "$arg" in
      --ack) ack=true ;;
      *) [ "$supplied" = false ] || die "unexpected wait argument: $arg"; timeout="$arg"; supplied=true ;;
    esac
  done
  positive_seconds "$timeout" "wait timeout"
  local DC_DEADLINE=$((SECONDS + 10#$timeout))
  require_device
  pull_log || true
  [ ! -f "$LOG" ] || start="$(wc -l < "$LOG" | tr -d ' ')"
  while :; do
    if [ -s "$LOG" ]; then
      hit="$(jq -c --arg k "$key" --argjson start "$start" --argjson ack "$ack" -s '
        def failed: .event == "error" or .ok == false or (.outcome != null and .outcome != "ok");
        def terminal: .event == "error" or .event == "done" or .event == "session.probe.done" or .event == "control.done";
        [.[] | select(.id == $k)] as $own |
        ($own | map(select(.event == "done")) | last) as $done |
        if ($own | any(.event == "error")) then {lines:$own,failed:true}
        elif $done != null and $ack then {lines:[$done],failed:($done|failed)}
        elif $done != null and $done.waitFor == null then {lines:$own,failed:($own|any(failed))}
        elif $done.waitFor != null then
          [.[] | select(.id == ($done.probeID // $k) and (.event == $done.waitFor or .event == "error"))] as $end |
          if ($end|length) > 0 then {lines:([$done]+$end),failed:($end|any(failed))} else null end
        elif ($own|any(terminal)) then {lines:$own,failed:($own|any(failed))}
        elif ($own|length) == 0 then
          [to_entries[] | select(.key >= $start and .value.event == $k) | .value] as $new |
          if ($new|length)>0 then {lines:$new,failed:($new|any(failed))} else null end
        else null end' "$LOG")" || die "invalid bridge log: $LOG"
      if [ "$hit" != null ]; then
        jq -c '.lines[]' <<< "$hit"
        if jq -e '.failed' <<< "$hit" > /dev/null; then return 1; fi
        return 0
      fi
    fi
    [ "$SECONDS" -lt "$DC_DEADLINE" ] || wait_failure "$key (${timeout}s budget)"
    sleep 0.2
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

cmd_background() {
  require_device
  case "$TARGET" in
    device) dc device process launch --device "$DEVICE" com.apple.Preferences ;;
    sim) sc launch "$SIM" com.apple.Preferences ;;
    mac) local id; id="$(cmd_send background)"; cmd_wait "$id" ;;
  esac
}
cmd_foreground() {
  require_device
  case "$TARGET" in
    device) dc device process launch --device "$DEVICE" "$BID" ;;
    sim) sc launch "$SIM" "$BID" ;;
    mac) local id; id="$(cmd_send foreground)"; cmd_wait "$id" ;;
  esac
}
cmd_terminate() {
  if [ "$TARGET" = sim ]; then sc terminate "$SIM" "$BID"; return; fi
  [ -f "$STATE/pid" ] || die "terminate requires the PID captured by ctl launch for this target"
  local pid
  pid="$(cat "$STATE/pid")"
  case "$pid" in '' | *[!0-9]*) die "invalid saved process identifier" ;; esac
  if [ "$TARGET" = device ]; then
    require_device; dc device process terminate --device "$DEVICE" --pid "$pid"
  else
    local command
    command="$(ps -p "$pid" -o command=)" || die "captured Mac process is no longer running"
    [[ "$command" == "$APP/Contents/MacOS/"* ]] || die "captured PID no longer belongs to this app"
    kill -TERM "$pid"
  fi
}

cmd_pull() {
  local group=""
  [ "${1:-}" = "--group" ] && { group=group; shift; }
  [ $# -eq 1 ] || die "usage: pull [--group] <path>"
  case "$1" in '' | /* | .. | ../* | */../* | */..) die "invalid container-relative path: $1" ;; esac
  require_device
  local dest
  dest="$STATE/pulled/$(basename "$1")"
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
