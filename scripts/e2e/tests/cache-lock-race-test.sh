#!/usr/bin/env bash
# Deterministic interleavings; all deletion is confined to this private fixture root.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
T="$(mktemp -d "${TEST_SCRATCH:-${TMPDIR:-/tmp}}/cache-lock-race.XXXXXX")"
child=""
teardown() {
  if [ -n "$child" ]; then kill -TERM "$child" 2>/dev/null || true; wait "$child" 2>/dev/null || true; fi
  rm -rf "$T"
}
trap teardown EXIT
source "$ROOT/scripts/e2e/work-dir.sh"
mkdir -p "$T/bin" "$T/cache/build-derived/old"
mkfifo "$T/ready" "$T/release"
exec 3<>"$T/ready"
exec 4<>"$T/release"
export RACE_READY="$T/ready" RACE_RELEASE="$T/release"
# Pause actual pruner owner publication after its owner file has been opened/truncated.
cat > "$T/bin/ps" <<'STUB'
#!/bin/bash
if [ "${RACE_PAUSE:-}" = 1 ]; then
  echo ready > "$RACE_READY"
  read -r reply < "$RACE_RELEASE"
fi
exec /bin/ps "$@"
STUB
chmod +x "$T/bin/ps"
printf 'v1\n' > "$T/cache/build-derived/old/legato-managed"
touch -t 202001010000 "$T/cache/build-derived/old/legato-last-used"
env LEGATO_CACHE_DIR="$T/cache" RACE_PAUSE=1 PATH="$T/bin:$PATH" \
  /bin/bash "$ROOT/scripts/dev/prune-build-caches.sh" --managed-only --delete > "$T/prune.log" 2>&1 &
child=$!
read -r -t 10 ready <&3
[ "$ready" = ready ]
acquired=0
LEGATO_LOCK_WAIT=0 lock_dir "$T/cache/build-derived/old" 2> "$T/contender.log" && acquired=1
echo release >&4
wait "$child"
child=""
fails=0
if [ "$acquired" = 0 ]; then echo 'PASS builder cannot steal pruner during owner publication'
else
  echo 'FAIL builder stole pruner lock during owner publication'; fails=$((fails+1))
  unlock_dir "$T/cache/build-derived/old"
fi

# Pause one contender after observing a dead legacy owner. Another must not recover the same marker.
mkdir "$T/stale.lock"
printf '999999 dead\n' > "$T/stale.lock/owner"
cat > "$T/contender.sh" <<'DRIVER'
#!/bin/bash
set -euo pipefail
source "$1/scripts/e2e/work-dir.sh"
eval "$(declare -f owner_alive | sed '1s/owner_alive/original_owner_alive/')"
owner_alive() {
  original_owner_alive "$@" && return 0
  echo ready > "$RACE_READY"
  read -r reply < "$RACE_RELEASE"
  return 1
}
LEGATO_LOCK_WAIT=0 lock_dir "$2"
echo acquired > "$3"
unlock_dir "$2"
DRIVER
/bin/bash "$T/contender.sh" "$ROOT" "$T/stale" "$T/stale-result" > "$T/stale.log" 2>&1 &
child=$!
read -r -t 10 ready <&3
[ "$ready" = ready ]
acquired=0
LEGATO_LOCK_WAIT=0 lock_dir "$T/stale" 2> "$T/stale-other.log" && acquired=1
echo release >&4
wait "$child"
child=""
if [ "$acquired" = 0 ] && [ "$(cat "$T/stale-result")" = acquired ]; then
  echo 'PASS stale-owner contenders cannot steal a replacement lock'
else
  echo 'FAIL stale-owner contender stole replacement lock'; fails=$((fails+1))
  unlock_dir "$T/stale"
fi

# Descriptor allocation must preserve inherited descriptors through nested locks and pruning.
exec 7>"$T/foreign-fd"
lock_dir "$T/outer"
lock_dir "$T/inner"
printf 'preserved\n' >&7
[ "$(cat "$T/foreign-fd")" = preserved ]
/bin/bash -c 'source "$1/scripts/e2e/work-dir.sh"; lock_dir "$2"; unlock_dir "$2"' fixture "$ROOT" "$T/child"
unlock_dir "$T/inner"
unlock_dir "$T/outer"
exec 7>&-
echo 'PASS nested and child claims preserve inherited descriptors'

# A rejected live legacy marker releases the auxiliary guard as well as its descriptor.
mkdir "$T/legacy.lock"
proc_stamp "$$" > "$T/legacy.lock/owner"
if LEGATO_LOCK_WAIT=0 lock_dir "$T/legacy" 2>"$T/legacy.log"; then
  echo 'FAIL live legacy owner was ignored'; exit 1
fi
/usr/bin/lockf -s -k -t 0 "$T/legacy.guard" true
rm -rf "$T/legacy.lock"
echo 'PASS live legacy-owner rejection releases guard'

# Real ios-sim startup: simulate deletion just before its DerivedData marker is acquired.
export LEGATO_CACHE_DIR="$T/sim-cache" TMPDIR="$T/tmp"
mkdir -p "$TMPDIR"
RACE_DERIVED="$LEGATO_CACHE_DIR/e2e-derived/$(cd "$ROOT" && pwd -P | shasum | cut -c1-12)"
export RACE_DERIVED
export RACE_RESULT="$T/sim-result"
cat > "$T/bin/mkdir" <<'STUB'
#!/bin/bash
if [ "$#" = 1 ] && [ "$1" = "$RACE_DERIVED.lock" ]; then rm -rf "$RACE_DERIVED"; fi
exec /bin/mkdir "$@"
STUB
cat > "$T/bin/xcodegen" <<'STUB'
#!/bin/bash
if [ "$1" = --version ]; then printf 'Version: %s\n' "$(cat .xcodegen-version)"; exit; fi
if [ -f "$RACE_DERIVED/legato-checkout" ] && [ -f "$RACE_DERIVED/legato-managed" ]; then echo ready > "$RACE_RESULT"; else echo missing > "$RACE_RESULT"; fi
exit 77
STUB
cat > "$T/bin/xcodebuild" <<'STUB'
#!/bin/bash
if [ "$1" = -showComponent ]; then echo 'Status: installed'; fi
STUB
chmod +x "$T/bin/mkdir" "$T/bin/xcodegen" "$T/bin/xcodebuild"
status=0
env -u CI PATH="$T/bin:$PATH" /bin/bash "$ROOT/scripts/e2e/ios-sim.sh" release-check > "$T/sim.log" 2>&1 || status=$?
[ "$status" = 2 ] || { echo 'FAIL simulator did not reach fake XcodeGen'; exit 1; }
if [ "$(cat "$RACE_RESULT")" = ready ]; then echo 'PASS simulator recreates DerivedData and checkout stamp under lock'
else echo 'FAIL simulator lost DerivedData before lock acquisition'; fails=$((fails+1)); fi
[ "$fails" = 0 ]
