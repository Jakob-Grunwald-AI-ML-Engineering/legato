#!/usr/bin/env bash
# Private filesystem fixtures only; no Xcode/Swift builds or real cache deletion.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
T="$(mktemp -d "${TEST_SCRATCH:-${TMPDIR:-/tmp}}/build-cache-test.XXXXXX")"
run_pid=""
child_pid=""
teardown() {
  if [ -n "$child_pid" ]; then kill -TERM "$child_pid" 2>/dev/null || true; fi
  if [ -n "$run_pid" ]; then kill -TERM "$run_pid" 2>/dev/null || true; wait "$run_pid" 2>/dev/null || true; fi
  rm -rf "$T"
}
trap teardown EXIT
export LEGATO_CACHE_DIR="$T/cache" LEGATO_DERIVED_DATA="$T/dd" TMPDIR="$T/tmp"
# The default prune also scans agent scratchpads and test caches: keep every root inside the fixture.
export LEGATO_SCRATCH_ROOT="$T/claude" LEGATO_SCRATCH_PROJECT_GLOB='-Users-x-Documents-legato*' LEGATO_TESTS_CACHE="$T/LegatoTests"
mkdir -p "$TMPDIR" "$LEGATO_CACHE_DIR/build-derived"
source "$ROOT/scripts/e2e/work-dir.sh"
fixture() {
  mkdir -p "$LEGATO_CACHE_DIR/build-derived/$1"
  printf 'v1\n' > "$LEGATO_CACHE_DIR/build-derived/$1/legato-managed"
  touch -t "$2" "$LEGATO_CACHE_DIR/build-derived/$1/legato-last-used"
}
fixture stale 202001010000
fixture active 202001010000
mkdir "$LEGATO_CACHE_DIR/build-derived/active.lock"
proc_stamp "$$" > "$LEGATO_CACHE_DIR/build-derived/active.lock/owner"
mkdir -p "$LEGATO_CACHE_DIR/SourcePackages" "$LEGATO_CACHE_DIR/SourcePackages.lock"
printf 'v1\n' > "$LEGATO_CACHE_DIR/SourcePackages/legato-managed"
touch -t 202001010000 "$LEGATO_CACHE_DIR/SourcePackages/legato-last-used"
proc_stamp "$$" > "$LEGATO_CACHE_DIR/SourcePackages.lock/owner"
mkdir "$LEGATO_CACHE_DIR/build-derived/unmanaged"
ln -s "$T" "$LEGATO_CACHE_DIR/build-derived/linked"
"$ROOT/scripts/dev/prune-build-caches.sh" > "$T/dry.log"
[ -d "$LEGATO_CACHE_DIR/build-derived/stale" ] || { echo 'FAIL dry run deleted cache'; exit 1; }
"$ROOT/scripts/dev/prune-build-caches.sh" --delete > "$T/delete.log"
[ ! -d "$LEGATO_CACHE_DIR/build-derived/stale" ] || { echo 'FAIL expired managed cache retained'; exit 1; }
[ -d "$LEGATO_CACHE_DIR/build-derived/active" ] || { echo 'FAIL active cache removed'; exit 1; }
[ -d "$LEGATO_CACHE_DIR/build-derived/unmanaged" ] && [ -L "$LEGATO_CACHE_DIR/build-derived/linked" ] || { echo 'FAIL unmanaged cache removed'; exit 1; }
[ -d "$LEGATO_CACHE_DIR/SourcePackages" ] || { echo 'FAIL active shared clones removed'; exit 1; }
unlock_dir "$LEGATO_CACHE_DIR/SourcePackages"
echo 'PASS dry run, TTL, active lock and unmanaged/symlink protection'
fixture older 203001010000
fixture newer 203101010000
# Cap zero forces removal of inactive entries regardless of age.
LEGATO_CACHE_MAX_KB=0 "$ROOT/scripts/dev/prune-build-caches.sh" --delete > "$T/cap.log"
[ ! -d "$LEGATO_CACHE_DIR/build-derived/older" ] && [ ! -d "$LEGATO_CACHE_DIR/build-derived/newer" ] || { echo 'FAIL size cap retained inactive cache'; exit 1; }
[ -d "$LEGATO_CACHE_DIR/build-derived/active" ] || { echo 'FAIL cap removed active cache'; exit 1; }
older_line="$(grep -n 'build-derived/older$' "$T/cap.log" | cut -d: -f1)"
newer_line="$(grep -n 'build-derived/newer$' "$T/cap.log" | cut -d: -f1)"
[ "$older_line" -lt "$newer_line" ] || { echo 'FAIL cap did not evict oldest first'; exit 1; }
echo 'PASS cap evicts inactive caches and preserves active cache'

# --- Unmanaged/legacy output: agent scratchpads, TMPDIR legato-* dirs, unmarked cache dirs, LegatoTests. ---
u_fails=0
ucheck() { if [ "$2" = ok ]; then echo "PASS $1"; else echo "FAIL $1 ($2)"; u_fails=$((u_fails+1)); fi; }
OLD=202001010000
PRJ="$LEGATO_SCRATCH_ROOT/-Users-x-Documents-legato/sess/scratchpad"
OTHER="$LEGATO_SCRATCH_ROOT/-Users-x-Documents-other/sess/scratchpad"
dd_fixture() { # <dir> <touch -t stamp or "now">
  mkdir -p "$1/ModuleCache.noindex" "$1/Build"
  head -c 1048576 /dev/zero > "$1/Build/blob"
  : > "$1/ModuleCache.noindex/f"
  if [ "$2" != now ]; then find "$1" -exec touch -t "$2" {} +; fi
}
dd_fixture "$PRJ/xcb-old" $OLD
dd_fixture "$PRJ/nested/xcb-new" now
dd_fixture "$PRJ/xcb-claimed" $OLD
dd_fixture "$PRJ/xcb-locked" $OLD
dd_fixture "$OTHER/xcb-old" $OLD
mkdir -p "$PRJ/SourcePackages/checkouts" "$PRJ/notes"
: > "$PRJ/SourcePackages/workspace-state.json"; : > "$PRJ/notes/keep.txt"
find "$PRJ/SourcePackages" "$PRJ/notes" -exec touch -t $OLD {} +
mkdir "$PRJ/xcb-claimed.lock"; proc_stamp "$$" > "$PRJ/xcb-claimed.lock/owner"
claim_cache_lock "$PRJ/xcb-locked" 0   # kernel-held claim, no .lock dir
mkdir -p "$TMPDIR/legato-gate.OLD1" "$TMPDIR/legato-xcodegen-1" "$TMPDIR/unrelated-old" "$TMPDIR/legato-mac.NEW1"
: > "$TMPDIR/legato-gate.OLD1/f"; : > "$TMPDIR/legato-xcodegen-1/f"; : > "$TMPDIR/unrelated-old/f"
find "$TMPDIR/legato-gate.OLD1" "$TMPDIR/legato-xcodegen-1" "$TMPDIR/unrelated-old" -exec touch -t $OLD {} +
mkdir -p "$LEGATO_CACHE_DIR/phone-derived/Build" "$LEGATO_TESTS_CACHE/Models/m" "$LEGATO_TESTS_CACHE/leftover"
: > "$LEGATO_CACHE_DIR/phone-derived/Build/f"; : > "$LEGATO_TESTS_CACHE/Models/m/f"; : > "$LEGATO_TESTS_CACHE/leftover/f"
find "$LEGATO_CACHE_DIR/phone-derived" "$LEGATO_TESTS_CACHE" -exec touch -t $OLD {} +
# A symlinked session dir must not lead the pruner outside the scratch root.
OUTSIDE="$T/outside-root"; dd_fixture "$OUTSIDE/scratchpad/DerivedData" $OLD
ln -s "$OUTSIDE" "$LEGATO_SCRATCH_ROOT/-Users-x-Documents-legato/linked-sess"

"$ROOT/scripts/dev/prune-build-caches.sh" > "$T/udry.log"
if [ -d "$PRJ/xcb-old" ] && [ -d "$TMPDIR/legato-gate.OLD1" ] && [ -d "$LEGATO_CACHE_DIR/phone-derived" ] && [ -d "$LEGATO_TESTS_CACHE/leftover" ]; then
  ucheck 'dry run deletes nothing unmanaged' ok; else ucheck 'dry run deletes nothing unmanaged' 'something removed'; fi
grep -q "expired: .*$PRJ/xcb-old$" "$T/udry.log" && ucheck 'dry run lists old scratchpad DerivedData' ok || ucheck 'dry run lists old scratchpad DerivedData' 'not listed'

"$ROOT/scripts/dev/prune-build-caches.sh" --delete > "$T/udel.log"
[ ! -d "$PRJ/xcb-old" ] && ucheck 'old scratchpad DerivedData is pruned' ok || ucheck 'old scratchpad DerivedData is pruned' 'retained'
[ ! -d "$PRJ/SourcePackages" ] && ucheck 'old scratchpad package clones are pruned' ok || ucheck 'old scratchpad package clones are pruned' 'retained'
[ -d "$PRJ/nested/xcb-new" ] && ucheck 'recent scratchpad DerivedData is kept' ok || ucheck 'recent scratchpad DerivedData is kept' 'removed'
[ -d "$PRJ/xcb-claimed" ] && ucheck 'old DerivedData with a live .lock owner is kept' ok || ucheck 'old DerivedData with a live .lock owner is kept' 'removed'
[ -d "$PRJ/xcb-locked" ] && ucheck 'old DerivedData with a kernel-held claim is kept' ok || ucheck 'old DerivedData with a kernel-held claim is kept' 'removed'
release_cache_claim "$PRJ/xcb-locked"
[ -d "$OTHER/xcb-old" ] && ucheck 'other project scratchpad is never touched' ok || ucheck 'other project scratchpad is never touched' 'removed'
[ -d "$OUTSIDE/scratchpad/DerivedData" ] && ucheck 'symlinked session dir is never followed out of the scratch root' ok || ucheck 'symlinked session dir is never followed out of the scratch root' 'removed'
[ -f "$PRJ/notes/keep.txt" ] && ucheck 'non-build files in a legato scratchpad are kept' ok || ucheck 'non-build files in a legato scratchpad are kept' 'removed'
[ ! -d "$TMPDIR/legato-gate.OLD1" ] && ucheck 'old TMPDIR legato-gate dir is pruned' ok || ucheck 'old TMPDIR legato-gate dir is pruned' 'retained'
[ -d "$TMPDIR/legato-mac.NEW1" ] && [ -d "$TMPDIR/legato-xcodegen-1" ] && [ -d "$TMPDIR/unrelated-old" ] && ucheck 'recent legato-*, xcodegen tool cache and non-legato TMPDIR dirs are kept' ok || ucheck 'recent legato-*, xcodegen tool cache and non-legato TMPDIR dirs are kept' 'removed'
[ ! -d "$LEGATO_CACHE_DIR/phone-derived" ] && ucheck 'old unmarked cache dir is pruned' ok || ucheck 'old unmarked cache dir is pruned' 'retained'
[ ! -d "$LEGATO_TESTS_CACHE/leftover" ] && [ -d "$LEGATO_TESTS_CACHE/Models" ] && ucheck 'LegatoTests leftovers are pruned, downloaded Models kept' ok || ucheck 'LegatoTests leftovers are pruned, downloaded Models kept' 'wrong'

# Cap: oldest unclaimed first; entries inside the grace window stay.
dd_fixture "$PRJ/cap-older" "$(date -v-30H +%Y%m%d%H%M)"
dd_fixture "$PRJ/cap-newer" "$(date -v-10H +%Y%m%d%H%M)"
dd_fixture "$PRJ/cap-fresh" now
LEGATO_CACHE_MAX_KB=0 "$ROOT/scripts/dev/prune-build-caches.sh" --delete > "$T/ucap.log"
if [ ! -d "$PRJ/cap-older" ] && [ ! -d "$PRJ/cap-newer" ] && [ -d "$PRJ/cap-fresh" ]; then ucheck 'cap prunes unmanaged output but keeps the grace-window entry' ok
else ucheck 'cap prunes unmanaged output but keeps the grace-window entry' 'wrong set'; fi
lo="$(grep -n 'cap-older$' "$T/ucap.log" | cut -d: -f1)"; ln="$(grep -n 'cap-newer$' "$T/ucap.log" | cut -d: -f1)"
{ [ -n "$lo" ] && [ -n "$ln" ] && [ "$lo" -lt "$ln" ]; } && ucheck 'unmanaged cap evicts oldest first' ok || ucheck 'unmanaged cap evicts oldest first' "order ${lo:-none}/${ln:-none}"

# Report: per-category totals against the budget, nothing deleted.
"$ROOT/scripts/dev/prune-build-caches.sh" --report > "$T/report.log"
scratch_kb="$(awk '/scratchpad build output/ {print $1}' "$T/report.log")"
{ [ -n "$scratch_kb" ] && [ "$scratch_kb" -ge 1024 ]; } && ucheck 'report shows scratchpad build output size' ok || ucheck 'report shows scratchpad build output size' "kb=${scratch_kb:-none}"
for label in 'agent scratchpads' 'TMPDIR legato-' 'legato cache' 'LegatoTests' 'Xcode DerivedData' 'Total' 'Budget'; do
  grep -q "$label" "$T/report.log" && ucheck "report has '$label' line" ok || ucheck "report has '$label' line" missing
done
[ -d "$PRJ/xcb-claimed" ] && [ -d "$OTHER/xcb-old" ] && ucheck 'report deletes nothing' ok || ucheck 'report deletes nothing' removed
# Default project glob derives from HOME (-Users-x-Documents-legato*).
def_kb="$(env -u LEGATO_SCRATCH_PROJECT_GLOB HOME=/Users/x "$ROOT/scripts/dev/prune-build-caches.sh" --report | awk '/agent scratchpads/ {print $1}')"
{ [ -n "$def_kb" ] && [ "$def_kb" -gt 0 ]; } && ucheck 'default project glob matches the legato project dir' ok || ucheck 'default project glob matches the legato project dir' "kb=${def_kb:-none}"
rm -rf "$PRJ"/xcb-claimed* "$PRJ"/xcb-locked*
[ "$u_fails" = 0 ] || { echo "$u_fails unmanaged-prune checks failed"; exit 1; }
# Exercise the real mac-build entry point with only the external Xcode tools replaced.
mkdir -p "$T/bin"
cat > "$T/bin/xcodegen" <<'STUB'
#!/bin/bash
if [ "$1" = --version ]; then printf 'Version: %s\n' "$(cat .xcodegen-version)"; fi
STUB
cat > "$T/bin/xcodebuild" <<'STUB'
#!/bin/bash
if [ "$1" = -showComponent ]; then echo 'Status: installed'; exit; fi
printf '%s\n' "$@" >> "$BUILD_ARGS"
STUB
chmod +x "$T/bin/xcodegen" "$T/bin/xcodebuild"
export BUILD_ARGS="$T/build.args"
env -u CI PATH="$T/bin:$PATH" bash "$ROOT/scripts/ci/release.sh" mac-build > "$T/mac.log"
expected="$LEGATO_CACHE_DIR/build-derived/mac-$(cd "$ROOT" && pwd -P | shasum | cut -c1-12)"
grep -Fx -- "$expected" "$BUILD_ARGS" >/dev/null || { echo 'FAIL mac build uses implicit DerivedData'; exit 1; }
grep -Fx -- "$LEGATO_CACHE_DIR/SourcePackages" "$BUILD_ARGS" >/dev/null || { echo 'FAIL mac build does not share package clones'; exit 1; }
[ ! -d "$expected.lock" ] && [ ! -d "$LEGATO_CACHE_DIR/SourcePackages.lock" ] || { echo 'FAIL mac build leaks locks'; exit 1; }
[ -f "$expected/legato-last-used" ] || { echo 'FAIL mac build lacks explicit last-use stamp'; exit 1; }
echo 'PASS mac-build entry point uses managed DerivedData, shared clones and releases locks'
# CI uses a unique cold directory, then removes it, regardless of the persistent local cache.
mkdir "$T/runner"
CI=true RUNNER_TEMP="$T/runner" bash -c '
  set -euo pipefail
  source "$1/scripts/e2e/work-dir.sh"
  trap finish_build_cache EXIT
  prepare_build_cache gate
  printf "%s\n" "$BUILD_WORK" >> "$BUILD_ARGS"
  mkdir -p "$BUILD_WORK/derived"
' fixture "$ROOT" > "$T/ci-gate.log"
[ -z "$(find "$T/runner" -mindepth 1 -print -quit)" ] || { echo 'FAIL CI leaked temporary build directory'; exit 1; }
grep -F -- "$T/runner/legato-gate." "$BUILD_ARGS" >/dev/null || { echo 'FAIL CI reused local DerivedData'; exit 1; }
echo 'PASS CI builds use disposable cold output'

# The local gate helper uses a different reusable DerivedData entry from mac-build.
# shellcheck disable=SC2016 # The child shell expands its own environment.
env -u CI bash -c '
  set -euo pipefail
  source "$1/scripts/e2e/work-dir.sh"
  trap finish_build_cache EXIT
  prepare_build_cache gate
  [ "$BUILD_WORK" = "$LEGATO_CACHE_DIR/build-derived/gate-$(pwd -P | shasum | cut -c1-12)" ]
  [ "$BUILD_PACKAGES" = "$LEGATO_CACHE_DIR/SourcePackages" ]
' fixture "$ROOT" > "$T/gate.log"
echo 'PASS local gate uses its reusable entry and shared clones'
# Signal cleanup must reap the owned build before releasing its cache locks.
cat > "$T/bin/xcodebuild" <<'STUB'
#!/bin/bash
if [ "$1" = -showComponent ]; then echo 'Status: installed'; exit; fi
if [ "$1" = build ]; then echo $$ > "$BUILD_ARGS.pid"; exec sleep 300; fi
STUB
set -m
env -u CI PATH="$T/bin:$PATH" bash "$ROOT/scripts/ci/release.sh" mac-build > "$T/signal.log" 2>&1 &
run_pid=$!
set +m
for ((i=0; i<100; i++)); do [ ! -f "$BUILD_ARGS.pid" ] || break; sleep 0.05; done
[ -f "$BUILD_ARGS.pid" ] || { kill "$run_pid"; wait "$run_pid" || true; echo 'FAIL fake build never started'; exit 1; }
child_pid="$(cat "$BUILD_ARGS.pid")"
kill -TERM "$run_pid"
for ((i=0; i<40; i++)); do kill -0 "$run_pid" 2>/dev/null || break; sleep 0.05; done
if kill -0 "$run_pid" 2>/dev/null; then
  kill -TERM "$child_pid" 2>/dev/null || true
  wait "$run_pid" || true
  echo 'FAIL TERM did not reap build promptly'; exit 1
fi
wait "$run_pid" 2>/dev/null || true
if kill -0 "$child_pid" 2>/dev/null; then kill -TERM "$child_pid"; echo 'FAIL build outlived cache lock'; exit 1; fi
[ ! -d "$expected.lock" ] && [ ! -d "$LEGATO_CACHE_DIR/SourcePackages.lock" ] || { echo 'FAIL TERM leaked cache locks'; exit 1; }
echo 'PASS TERM reaps owned build before releasing cache locks'

run_pid=""
child_pid=""

# Run real simulator startup through package pruning, stopping at the XcodeGen boundary.
printf 'v1\n' > "$LEGATO_CACHE_DIR/SourcePackages/legato-managed"
touch -t 202001010000 "$LEGATO_CACHE_DIR/SourcePackages/legato-last-used"
cat > "$T/bin/xcodegen" <<'STUB'
#!/bin/bash
if [ "$1" = --version ]; then printf 'Version: %s\n' "$(cat .xcodegen-version)"; exit; fi
if [ -f "$LEGATO_CACHE_DIR/SourcePackages/legato-managed" ] &&
   [ -f "$LEGATO_CACHE_DIR/SourcePackages/legato-last-used" ]; then
  echo ready > "$BUILD_ARGS.startup"
else
  echo missing > "$BUILD_ARGS.startup"
fi
exit 77 # Stop before simulator/build work.
STUB
startup_status=0
env -u CI PATH="$T/bin:$PATH" bash "$ROOT/scripts/e2e/ios-sim.sh" release-check > "$T/startup.log" 2>&1 || startup_status=$?
[ "$startup_status" = 2 ] || { echo 'FAIL simulator did not stop at fake XcodeGen'; exit 1; }
new_fails=0
if [ "$(cat "$BUILD_ARGS.startup")" = ready ]; then
  echo 'PASS simulator recreates pruned package cache under its lock'
else
  echo 'FAIL simulator package cache absent after pruning'; new_fails=$((new_fails+1))
fi

# Timing out while waiting for clones must release the already-acquired DerivedData lock.
mkdir -p "$LEGATO_CACHE_DIR/SourcePackages.lock"
proc_stamp "$$" > "$LEGATO_CACHE_DIR/SourcePackages.lock/owner"
# shellcheck disable=SC2016 # The child shell expands its own environment.
if env -u CI LEGATO_LOCK_WAIT=0 bash -c '
  set -euo pipefail
  source "$1/scripts/e2e/work-dir.sh"
  trap finish_build_cache EXIT
  prepare_build_cache timeout
' fixture "$ROOT" > "$T/timeout.log" 2>&1; then
  echo 'FAIL package lock unexpectedly acquired'; exit 1
fi
timeout_work="${expected/mac-/timeout-}"
if [ ! -d "$timeout_work.lock" ]; then
  echo 'PASS package-lock timeout releases DerivedData lock'
else
  echo 'FAIL package-lock timeout leaked DerivedData lock'; new_fails=$((new_fails+1))
fi
unlock_dir "$LEGATO_CACHE_DIR/SourcePackages"
[ "$new_fails" = 0 ]
