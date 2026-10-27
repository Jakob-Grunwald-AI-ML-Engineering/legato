#!/usr/bin/env bash
# Regression test for #34: ios-sim.sh must not leak its legato-e2e.* work dir.
# Uses a private TMPDIR and a stub in place of the build (LEGATO_E2E_TEST_STUB), so it needs no Xcode build.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SCRIPT="$ROOT/scripts/e2e/ios-sim.sh"
T="$(mktemp -d "${TEST_SCRATCH:-${TMPDIR:-/tmp}}/cleanup-test.XXXXXX")"
STUB="$T/stub.sh"
# shellcheck disable=SC2016  # the stub expands $$ itself
printf '%s\n' '#!/bin/bash' 'echo $$ > "$1/stub.pid"' 'exec sleep 300' > "$STUB"; chmod +x "$STUB"
fails=0; pids=(); strays=()

teardown() {
  local p
  for p in "${pids[@]}" "${strays[@]}"; do kill "$p" 2> /dev/null; done
  for p in "$T"/legato-e2e.*/stub.pid; do [ -f "$p" ] && kill "$(cat "$p")" 2> /dev/null; done
  rm -rf "$T"
}
trap teardown EXIT

check() { if [ "$2" = ok ]; then echo "PASS  $1"; else echo "FAIL  $1  ($2)"; fails=$((fails + 1)); fi; }
dirs() { find "$T" -maxdepth 1 -name 'legato-e2e.*' -type d | sort; }

# start_run <var> [env...]: starts a stubbed run in the background and waits until its work dir has a live stub.
start_run() {
  local var="$1"; shift
  set -m   # job control: background jobs of a non-interactive shell would otherwise start with SIGINT ignored
  env TMPDIR="$T/" LEGATO_CACHE_DIR="$T/cache" LEGATO_E2E_DERIVED="$T/derived-$var" LEGATO_E2E_TEST_STUB="$STUB" "$@" "$SCRIPT" run > "$T/$var.out" 2>&1 &
  local pid=$!; set +m; pids+=("$pid"); printf -v "$var" '%s' "$pid"
  local i
  for ((i = 0; i < 100; i++)); do
    sleep 0.1
    [ -n "$(dir_of_run "$pid")" ] && return 0
  done
  return 1
}
# The work dir of a run = the one whose stub.pid names a live child of that run.
dir_of_run() {
  local d sp
  for d in "$T"/legato-e2e.*; do
    [ -f "$d/stub.pid" ] || continue
    sp="$(cat "$d/stub.pid")"
    [ "$(ps -o ppid= -p "$sp" 2> /dev/null | tr -d ' ')" = "$1" ] && { echo "$d"; return; }
  done
}

# reap <pid>...: give the runs 5 s to exit on their own, then SIGKILL stragglers (a run that ignores its signal).
reap() {
  local p i
  for p in "$@"; do
    for ((i = 0; i < 50; i++)); do kill -0 "$p" 2> /dev/null || break; sleep 0.1; done
    kill -KILL "$p" 2> /dev/null; wait "$p" 2> /dev/null
  done
  for p in "$T"/legato-e2e.*/stub.pid; do [ -f "$p" ] && kill "$(cat "$p")" 2> /dev/null; done
}

wait_gone() { # wait_gone <dir> — up to 5 s
  local i; for ((i = 0; i < 50; i++)); do [ -d "$1" ] || return 0; sleep 0.1; done; return 1
}

for sig in TERM INT; do
  start_run RUN || { check "SIG$sig: run starts" "no work dir"; continue; }
  d="$(dir_of_run "$RUN")"
  kill -"$sig" "$RUN"
  if wait_gone "$d"; then check "SIG$sig removes the work dir" ok; else check "SIG$sig removes the work dir" "still there: $d"; fi
  reap "$RUN"
  [ -z "$(dirs)" ] || { rm -rf "$T"/legato-e2e.*; }
done

# SIGKILL leaks (no trap can run), the next run sweeps it.
start_run A || check "SIGKILL: run starts" "no work dir"
dA="$(dir_of_run "$A")"
stubA="$(cat "$dA/stub.pid")"; strays=("$stubA")   # SIGKILL orphans the stub; it is ours to stop
kill -KILL "$A"; wait "$A" 2> /dev/null
[ -d "$dA" ] || check "SIGKILL precondition (dir left behind)" "dir missing"
start_run B
if wait_gone "$dA"; then check "next run sweeps the dir of a SIGKILLed run" ok; else check "next run sweeps the dir of a SIGKILLed run" "still there: $dA"; fi
dB="$(dir_of_run "$B")"

# A live concurrent run must survive another run's sweep.
start_run C
if [ -d "$dB" ]; then check "live concurrent run's dir is not swept" ok; else check "live concurrent run's dir is not swept" "deleted"; fi
kill -TERM "$B" "$C"; reap "$B" "$C"

# KEEP=1 keeps the dir, and later runs do not sweep it.
start_run K LEGATO_E2E_KEEP=1
dK="$(dir_of_run "$K")"
kill -TERM "$K"; reap "$K"
sleep 0.5
if [ -d "$dK" ]; then check "LEGATO_E2E_KEEP=1 keeps the dir" ok; else check "LEGATO_E2E_KEEP=1 keeps the dir" "deleted"; fi
start_run L
if [ -d "$dK" ]; then check "a later run does not sweep a kept dir" ok; else check "a later run does not sweep a kept dir" "deleted"; fi
kill -TERM "$L"; reap "$L"

if [ "$fails" = 0 ]; then echo "ALL PASS"; else echo "$fails FAILED"; exit 1; fi
