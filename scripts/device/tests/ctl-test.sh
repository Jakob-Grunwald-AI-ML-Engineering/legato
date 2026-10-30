#!/usr/bin/env bash
# Exercise the real CLI; CoreDevice is the only substituted boundary.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin"
cat > "$work/bin/xcrun" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$FIXTURE/calls"
args=" $* "
if [ "${2:-}" = simctl ]; then shift; fi
if [ "${1:-}" = simctl ]; then
  shift
  case "$1 $2" in
    'get_app_container '*) printf '%s\n' "$FIXTURE/container" ;;
    'list devices') printf '%s\n' '{"devices":{"runtime":[{"udid":"sim-fixture","state":"Booted","isAvailable":true}]}}' ;;
    'launch '*) echo "$3: 555"; mkdir -p "$FIXTURE/container/Library/Caches/debug-bridge"; echo '{"id":"-","event":"started","pid":555,"generation":"sim-new"}' > "$FIXTURE/container/Library/Caches/debug-bridge/log.jsonl" ;;
    'install '* | 'terminate '*) : ;;
    *) echo "unexpected sim command: $*" >&2; exit 81 ;;
  esac
  exit 0
fi
dest= source= json= timeout=
while [ $# -gt 0 ]; do
  case "$1" in
    --destination) dest="$2"; shift ;;
    --source) source="$2"; shift ;;
    --json-output) json="$2"; shift ;;
    --timeout) timeout="$2"; shift ;;
  esac
  shift
done
[ -n "$timeout" ] && [ "$timeout" -ge 5 ] || { echo 'Please specify a timeout value between 5 and 9223372036854775807' >&2; exit 64; }
if [[ "$args" == *' list devices '* ]]; then
  if [ "$SCENARIO" = discovery ]; then
    [ -n "$timeout" ] || { echo 'discovery has no timeout' >&2; exit 70; }
    echo "$$" >> "$FIXTURE/children"
    sleep "$timeout" & sleeper=$!; echo "$sleeper" >> "$FIXTURE/children"
    wait "$sleeper"; echo 'discovery timed out' >&2; exit 1
  fi
  echo 'Test phone 00008150-000E60360245401C (UDID) available (paired) iPhone'
elif [[ "$args" == *' install app '* ]]; then
  :
elif [[ "$args" == *' process launch '* ]]; then
  touch "$FIXTURE/launched"
  [ -z "$json" ] || printf '%s\n' '{"result":{"process":{"processIdentifier":555}}}' > "$json"
elif [[ "$args" == *' copy from '* ]]; then
  n=0; [ ! -f "$FIXTURE/pulls" ] || n="$(cat "$FIXTURE/pulls")"
  n=$((n + 1)); echo "$n" > "$FIXTURE/pulls"
  case "$SCENARIO" in
    ask-newline)
      jq -nc --arg id "$(jq -r .id "$FIXTURE/sent.json")" --arg choice "$FIXTURE_CHOICE" '{id:$id,event:"reply",choice:$choice}' > "$dest" ;;
    control)
      echo '{"id":"c-test","event":"done","accepted":true,"waitFor":"control.done"}' > "$dest"
      [ "$n" -lt 2 ] || echo '{"id":"c-test","event":"control.done","outcome":"ok"}' >> "$dest" ;;
    failed) echo 'fixture transfer unavailable' >&2; exit 1 ;;
    stalled)
      [ -n "$timeout" ] || { echo 'pull has no timeout' >&2; exit 70; }
      echo "$$" >> "$FIXTURE/children"
      sleep "$timeout" & sleeper=$!; echo "$sleeper" >> "$FIXTURE/children"
      wait "$sleeper"; echo 'fixture transfer timed out' >&2; exit 1 ;;
    later) [ ! -e "$dest" ] || { echo 'destination exists' >&2; exit 1; }; if [ "$n" -eq 1 ]; then echo '{"id":"c-test","event":"received"}' > "$dest"; else cp "$FIXTURE/done" "$dest"; fi ;;
    startup)
      if [ -f "$FIXTURE/launched" ] && [ "$n" -gt 2 ]; then
        echo '{"id":"-","event":"started","pid":555,"generation":"new"}' > "$dest"
        touch "$FIXTURE/ready-observed"
      else echo '{"id":"-","event":"started","pid":555,"generation":"old"}' > "$dest"; fi ;;
    *) [ ! -e "$dest" ] || { echo 'destination exists' >&2; exit 1; }; cp "$FIXTURE/done" "$dest" ;;
  esac
elif [[ "$args" == *' copy to '* ]]; then
  cp "$source" "$FIXTURE/sent.json"
  [ "$SCENARIO" != startup ] || [ -f "$FIXTURE/ready-observed" ] || { touch "$FIXTURE/premature-send"; echo 'send preceded readiness' >&2; exit 1; }
else echo "unexpected command: $args" >&2; exit 80
fi
FAKE
cat > "$work/bin/open" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$@" > "$FIXTURE/open-args"
root=
while [ $# -gt 0 ]; do
  case "$1" in --env) root="${2#LEGATO_MAC_ROOT=}"; shift ;; esac
  shift
done
[ -n "$root" ] || { echo 'launch omitted explicit bridge root' >&2; exit 81; }
printf '%s\n' '{"id":"-","event":"started","pid":444444,"generation":"launch-services"}' > "$root/log.jsonl"
FAKE
chmod +x "$work/bin/open"
cat > "$work/bin/ps" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
if [ "${1:-}" = -p ]; then
  case "$SCENARIO" in
    mac-dead) exit 1 ;;
    mac-foreign) echo '/Applications/Foreign.app/Contents/MacOS/Foreign' ;;
    *) printf '%s\n' "$FIXTURE/Test.app/Contents/MacOS/Fixture --fixture-argument" ;;
  esac
elif [ "$SCENARIO" = mac-existing ]; then
  printf '12345 %s\n' "$FIXTURE/Test.app/Contents/MacOS/Fixture"
  # More than a pipe buffer: early consumer exit must not hide the duplicate-process diagnostic.
  for ((n=0; n<5000; n++)); do echo '23456 /unrelated/process'; done
fi
FAKE
chmod +x "$work/bin/ps"

chmod +x "$work/bin/xcrun"
export PATH="$work/bin:$PATH"
failures=0
setup() {
  export SCENARIO="$1" FIXTURE="$work/$1" LEGATO_DEVICE_STATE="$work/$1/state"
  mkdir -p "$LEGATO_DEVICE_STATE"
  printf '%s\n' '{"id":"c-test","event":"received"}' '{"id":"c-test","event":"done"}' > "$FIXTURE/done"
}
run_ctl() { bash "$ROOT/scripts/device/ctl.sh" "$@" > "$FIXTURE/out" 2> "$FIXTURE/err"; }
check() { if "$@"; then echo "PASS $SCENARIO"; else echo "FAIL $SCENARIO"; failures=$((failures + 1)); cat "$FIXTURE/err"; fi; }
completed() { run_ctl wait c-test 2 && grep -q '"event":"done"' "$FIXTURE/out"; }
setup complete; check completed
setup later; check completed
setup decimal
leading_zero() { run_ctl wait c-test 08 && grep -q '"event":"done"' "$FIXTURE/out"; }
check leading_zero
setup failed
# Prime the target-specific cache through the public CLI before inducing failure.
SCENARIO=complete run_ctl wait c-test 2
cache="$(printf '%s\n' "$LEGATO_DEVICE_STATE"/*/log.jsonl)"
[ -f "$cache" ] || cache="$LEGATO_DEVICE_STATE/log.jsonl"
echo '{"id":"other","event":"done"}' > "$cache"
failed_preserves() {
  ! run_ctl wait c-test 1 && grep -q '"id":"other"' "$cache" && grep -q 'fixture transfer unavailable' "$FIXTURE/err"
}
check failed_preserves
bounded() {
  local began=$SECONDS
  ! run_ctl wait c-test 1 || return 1
  [ "$((SECONDS - began))" -le 2 ] || return 1
  grep -q -- '--timeout 5' "$FIXTURE/calls" || return 1
  ! grep -q 'Please specify a timeout' "$FIXTURE/err" || return 1
  [ -s "$FIXTURE/children" ] || return 1
  local child
  while read -r child; do
    if kill -0 "$child" 2> /dev/null; then echo "leaked child $child" >&2; return 1; fi
  done < "$FIXTURE/children"
  ! compgen -G "$LEGATO_DEVICE_STATE/*/devicectl.*" > /dev/null
}
setup discovery; check bounded
setup stalled; check bounded
setup terminal
echo '{"id":"c-test","event":"error","message":"bad command"}' > "$FIXTURE/done"
terminal() { ! run_ctl wait c-test 2 && grep -q 'bad command' "$FIXTURE/out"; }
check terminal
setup startup
startup() {
  run_ctl launch && run_ctl send ping && [ -f "$FIXTURE/ready-observed" ] && [ ! -f "$FIXTURE/premature-send" ] && grep -q '^c' "$FIXTURE/out"
}
check startup
setup control
completion() { run_ctl wait c-test 3 && jq -e -s 'last.event == "control.done"' "$FIXTURE/out" > /dev/null; }
check completion
setup ack
SCENARIO=control
acknowledgement() { run_ctl wait c-test 2 --ack && jq -e -s 'last.accepted == true and last.event == "done"' "$FIXTURE/out" > /dev/null && [ "$(cat "$FIXTURE/pulls")" = 1 ]; }
check acknowledgement
setup probe
printf '%s\n' '{"id":"c-test","event":"done","accepted":true,"probeID":"probe-fixture","waitFor":"session.probe.done"}' '{"id":"probe-fixture","event":"session.probe.done","outcome":"ok","ok":true}' > "$FIXTURE/done"
probe() { run_ctl wait c-test 2 && jq -e -s 'last.id == "probe-fixture" and last.outcome == "ok"' "$FIXTURE/out" > /dev/null && run_ctl wait probe-fixture 2; }
check probe
setup probe-error
echo '{"id":"probe-fixture","event":"session.probe.done","outcome":"failed","ok":false}' > "$FIXTURE/done"
probe_error() { ! run_ctl wait probe-fixture 1 && grep -q '"outcome":"failed"' "$FIXTURE/out"; }
check probe_error
setup reply
printf '%s\n' '{"id":"c-test","event":"done","waitFor":"reply"}' '{"id":"c-test","event":"reply","choice":"Continue"}' > "$FIXTURE/done"
reply() { run_ctl wait c-test 2 && jq -e -s 'last.choice == "Continue"' "$FIXTURE/out" > /dev/null; }
check reply
setup malformed
echo 'broken JSON' > "$FIXTURE/done"
malformed() { ! run_ctl wait c-test 1 && grep -q 'invalid bridge log' "$FIXTURE/err"; }
check malformed
setup sim
mkdir -p "$FIXTURE/container/Library/Caches/debug-bridge/inbox"
complex=$'Line one\nLine two "quoted" \ literal'
sim() {
  LEGATO_SIMULATOR=sim-fixture run_ctl --target sim send say "$complex" || return 1
  jq -e --arg text "$complex" '.args == [$text] and .command == "say"' "$FIXTURE/container/Library/Caches/debug-bridge/inbox/$(cat "$FIXTURE/out").json" > /dev/null
}
check sim
setup mac
mkdir -p "$FIXTURE/mac/inbox"
mac() {
  LEGATO_MAC_ROOT="$FIXTURE/mac" run_ctl --target mac send say "$complex" || return 1
  jq -e --arg text "$complex" '.args == [$text]' "$FIXTURE/mac/inbox/$(cat "$FIXTURE/out").json" > /dev/null
}
check mac
setup identities
mkdir -p "$FIXTURE/mac/inbox"
identities() {
  LEGATO_BUNDLE=example.first LEGATO_MAC_ROOT="$FIXTURE/mac" run_ctl --target mac send ping || return 1
  LEGATO_BUNDLE=example.second LEGATO_MAC_ROOT="$FIXTURE/mac" run_ctl --target mac send ping || return 1
  local dirs=("$LEGATO_DEVICE_STATE"/*)
  [ "${#dirs[@]}" -eq 2 ]
}
check identities
setup overrides
mkdir -p "$FIXTURE/Test.app"
overrides() {
  LEGATO_BUNDLE=example.test LEGATO_GROUP=group.example.test LEGATO_APP="$FIXTURE/Test.app" run_ctl install || return 1
  grep -q -- "$FIXTURE/Test.app" "$FIXTURE/calls" || return 1
  LEGATO_BUNDLE=example.test LEGATO_GROUP=group.example.test run_ctl pull --group Documents/value || return 1
  grep -q -- '--domain-identifier group.example.test' "$FIXTURE/calls"
}
check overrides
setup ask-newline
export FIXTURE_CHOICE=$'First line\nSecond line'
ask_newline() { run_ctl ask --timeout 2 'Question?' "$FIXTURE_CHOICE" Other && [ "$(cat "$FIXTURE/out")" = "$FIXTURE_CHOICE" ]; }
check ask_newline
setup sim-lifecycle
mkdir -p "$FIXTURE/container/Library/Caches/debug-bridge/inbox" "$FIXTURE/Test.app" "$FIXTURE/container/Documents"
echo container-value > "$FIXTURE/container/Documents/value"
sim_lifecycle() {
  export LEGATO_SIMULATOR=sim-fixture LEGATO_APP="$FIXTURE/Test.app"
  run_ctl --target sim install && run_ctl --target sim launch && run_ctl --target sim pull Documents/value || return 1
  grep -q container-value "$FIXTURE/out" || return 1
  run_ctl --target sim terminate || return 1
  unset LEGATO_SIMULATOR LEGATO_APP
  grep -q -- 'simctl install sim-fixture' "$FIXTURE/calls" && grep -q -- '--terminate-running-process sim-fixture' "$FIXTURE/calls"
}
check sim_lifecycle
setup sim-alias
mkdir -p "$FIXTURE/container/Library/Caches/debug-bridge/inbox"
sim_alias() {
  run_ctl --target sim send ping || return 1
  LEGATO_SIMULATOR=sim-fixture run_ctl --target sim send ping || return 1
  local counters=("$LEGATO_DEVICE_STATE"/*/seq)
  [ "${#counters[@]}" -eq 1 ] && [ "$(cat "${counters[0]}")" -eq 2 ]
}
check sim_alias
setup mac-unavailable
mkdir -p "$FIXTURE/Test.app"
mac_unavailable() { ! LEGATO_APP="$FIXTURE/Test.app" run_ctl --target mac install && grep -q 'Mac install unavailable' "$FIXTURE/err"; }
check mac_unavailable
setup mac-launch
mkdir -p "$FIXTURE/Test.app/Contents/MacOS" "$FIXTURE/mac/inbox"
cat > "$FIXTURE/Test.app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>CFBundleExecutable</key><string>Fixture</string></dict></plist>
PLIST
cat > "$FIXTURE/Test.app/Contents/MacOS/Fixture" <<'APP'
#!/usr/bin/env bash
touch "$FIXTURE/direct-execution"
APP
chmod +x "$FIXTURE/Test.app/Contents/MacOS/Fixture"
mac_launch() {
  LEGATO_DEVICE_LAUNCH_TIMEOUT=1 LEGATO_APP="$FIXTURE/Test.app" LEGATO_MAC_ROOT="$FIXTURE/mac" run_ctl --target mac launch --fixture-argument || return 1
  [ ! -f "$FIXTURE/direct-execution" ] && grep -qx -- "LEGATO_MAC_ROOT=$FIXTURE/mac" "$FIXTURE/open-args" &&
    grep -qx -- '--fixture-argument' "$FIXTURE/open-args" && [ "$(cat "$LEGATO_DEVICE_STATE"/*/pid)" = 444444 ]
}
check mac_launch
for scenario in mac-foreign mac-dead mac-stale mac-existing; do
  setup "$scenario"
  mkdir -p "$FIXTURE/mac/inbox"
  cp -R "$work/mac-launch/Test.app" "$FIXTURE/Test.app"
  if [ "$scenario" = mac-stale ]; then
    echo '{"id":"-","event":"started","pid":444444,"generation":"launch-services"}' > "$FIXTURE/mac/log.jsonl"
  fi
  rejects_invalid_mac_launch() {
    ! LEGATO_DEVICE_LAUNCH_TIMEOUT=1 LEGATO_APP="$FIXTURE/Test.app" LEGATO_MAC_ROOT="$FIXTURE/mac" run_ctl --target mac launch || return 1
    local pids=("$LEGATO_DEVICE_STATE"/*/pid)
    [ ! -f "${pids[0]}" ] || return 1
    if [ "$SCENARIO" = mac-existing ]; then grep -q 'Mac app already runs as PID 12345' "$FIXTURE/err"; fi
  }
  check rejects_invalid_mac_launch
done
setup malformed-timeout
malformed_timeout() { ! run_ctl wait c-test nonsense && grep -q 'positive integer' "$FIXTURE/err" && [ ! -f "$FIXTURE/calls" ]; }
check malformed_timeout
setup invalid-target
invalid_target() { ! run_ctl --target nonsense send ping && grep -q 'unknown target' "$FIXTURE/err"; }
check invalid_target
[ "$failures" -eq 0 ]
