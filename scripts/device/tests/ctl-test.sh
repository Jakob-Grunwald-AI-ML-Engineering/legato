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
elif [[ "$args" == *' process launch '* ]]; then
  touch "$FIXTURE/launched"
  [ -z "$json" ] || printf '%s\n' '{"result":{"process":{"processIdentifier":555}}}' > "$json"
elif [[ "$args" == *' copy from '* ]]; then
  n=0; [ ! -f "$FIXTURE/pulls" ] || n="$(cat "$FIXTURE/pulls")"
  n=$((n + 1)); echo "$n" > "$FIXTURE/pulls"
  case "$SCENARIO" in
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
  [ "$SCENARIO" != startup ] || [ -f "$FIXTURE/ready-observed" ] || { touch "$FIXTURE/premature-send"; echo 'send preceded readiness' >&2; exit 1; }
else echo "unexpected command: $args" >&2; exit 80
fi
FAKE
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
echo '{"id":"other","event":"done"}' > "$LEGATO_DEVICE_STATE/log.jsonl"
failed_preserves() {
  ! run_ctl wait c-test 1 && grep -q '"id":"other"' "$LEGATO_DEVICE_STATE/log.jsonl" && grep -q 'fixture transfer unavailable' "$FIXTURE/err"
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
  ! compgen -G "$LEGATO_DEVICE_STATE/devicectl.*" > /dev/null
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
[ "$failures" -eq 0 ]
