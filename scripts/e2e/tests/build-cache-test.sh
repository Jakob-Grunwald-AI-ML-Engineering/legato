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
# The pruner also reports agent scratchpads and test caches: keep every root inside the fixture.
export LEGATO_SCRATCH_ROOT="$T/claude" LEGATO_SCRATCH_PROJECT_GLOB='-Users-x-Documents-legato*' LEGATO_TESTS_CACHE="$T/LegatoTests"
C="$LEGATO_CACHE_DIR"
mkdir -p "$TMPDIR" "$C"
source "$ROOT/scripts/e2e/work-dir.sh"
OLD=202001010000
fails=0
check() { if [ "$2" = ok ]; then echo "PASS $1"; else echo "FAIL $1 ($2)"; fails=$((fails+1)); fi; }
tree() { # <dir> [touch -t stamp]: a 1 MiB build-output stand-in
  mkdir -p "$1/Build"
  head -c 1048576 /dev/zero > "$1/Build/blob"
  if [ -n "${2:-}" ]; then find "$1" -exec touch -t "$2" {} +; fi
}

# --- Fixed layout: four targets plus SourcePackages survive, even when old and unmarked. ---
for t in "${LEGATO_BUILD_TARGETS[@]}"; do tree "$C/derived/$t" $OLD; done
tree "$C/SourcePackages" $OLD
[ "${LEGATO_BUILD_TARGETS[*]}" = 'ios-device ios-sim mac gate' ] && check 'the four build targets are fixed' ok || check 'the four build targets are fixed' "${LEGATO_BUILD_TARGETS[*]}"
[ "$(derived_dir mac)" = "$C/derived/mac" ] && [ "$(packages_dir)" = "$C/SourcePackages" ] && check 'derived_dir and packages_dir paths' ok || check 'derived_dir and packages_dir paths' wrong
touch "$C/derived/mac.guard" "$C/SourcePackages.guard"
mkdir "$C/derived/mac.lock"; proc_stamp "$$" > "$C/derived/mac.lock/owner"   # a live build on mac
rmdir_mac_lock() { rm -rf "$C/derived/mac.lock"; }

# --- Obsolete output: old per-checkout roots, strays, symlinks, locked entries. ---
tree "$C/build-derived/gate-aaaa" $OLD; tree "$C/build-derived/mac-bbbb" $OLD
tree "$C/e2e-derived/cccc" $OLD; tree "$C/device-derived/dddd" $OLD
tree "$C/phone-derived" $OLD; tree "$C/derived/stray" $OLD
tree "$C/build-derived/locked-eeee" $OLD
mkdir "$C/build-derived/locked-eeee.lock"; proc_stamp "$$" > "$C/build-derived/locked-eeee.lock/owner"
tree "$C/e2e-derived/claimed-ffff" $OLD
claim_cache_lock "$C/e2e-derived/claimed-ffff" 0          # kernel-held claim, no .lock dir
tree "$C/build-derived/fresh-gggg"; : > "$C/build-derived/fresh-gggg/new"   # modified just now
OUTSIDE="$T/outside"; tree "$OUTSIDE/victim" $OLD
ln -s "$OUTSIDE" "$C/linked-cache"
ln -s "$OUTSIDE" "$C/derived/linked-target"
ln -s "$OUTSIDE" "$C/device-derived/linked-entry"
# TMPDIR: old CI-style work dir, recent one, tool cache, unrelated, dead and live e2e work dirs.
tree "$TMPDIR/legato-gate.OLD1" $OLD; tree "$TMPDIR/legato-mac.NEW1"; tree "$TMPDIR/legato-xcodegen-1" $OLD; tree "$TMPDIR/unrelated-old" $OLD
mkdir -p "$TMPDIR/legato-e2e.DEAD" "$TMPDIR/legato-e2e.LIVE"
printf '999999 dead\n' > "$TMPDIR/legato-e2e.DEAD/owner"; proc_stamp "$$" > "$TMPDIR/legato-e2e.LIVE/owner"
find "$TMPDIR/legato-e2e.DEAD" "$TMPDIR/legato-e2e.LIVE" -exec touch -t $OLD {} +
# Xcode's own DerivedData: only Legato* goes (never other projects), and not while in use.
tree "$T/dd/Legato-abcdefgh" $OLD; tree "$T/dd/LegatoMac-recent"; tree "$T/dd/OtherApp-xyz" $OLD
# Downloaded models and agent scratchpads are outside this tool's scope.
tree "$LEGATO_TESTS_CACHE/Models/m" $OLD; tree "$LEGATO_SCRATCH_ROOT/-Users-x-Documents-legato/sess/scratchpad/DerivedData" $OLD

"$ROOT/scripts/dev/prune-build-caches.sh" > "$T/dry.log"
[ -d "$C/build-derived/gate-aaaa" ] && [ -d "$C/phone-derived" ] && [ -d "$TMPDIR/legato-gate.OLD1" ] && [ -d "$T/dd/Legato-abcdefgh" ] && [ -d "$TMPDIR/legato-e2e.DEAD" ] \
  && check 'dry run deletes nothing' ok || check 'dry run deletes nothing' 'something removed'
grep -q "obsolete: .*$C/phone-derived$" "$T/dry.log" && check 'dry run lists obsolete cache entries' ok || check 'dry run lists obsolete cache entries' 'not listed'

"$ROOT/scripts/dev/prune-build-caches.sh" --delete > "$T/delete.log"
gone=ok
for x in "$C/build-derived/gate-aaaa" "$C/build-derived/mac-bbbb" "$C/e2e-derived/cccc" "$C/device-derived/dddd" "$C/phone-derived" "$C/derived/stray" "$TMPDIR/legato-gate.OLD1" "$T/dd/Legato-abcdefgh" "$TMPDIR/legato-e2e.DEAD"; do
  [ ! -e "$x" ] || gone="$x retained"
done
check 'old per-checkout dirs, strays, stale temp, dead work dirs and Xcode Legato* copies are removed' "$gone"
for t in "${LEGATO_BUILD_TARGETS[@]}"; do [ -s "$C/derived/$t/Build/blob" ] || gone="derived/$t removed"; done
[ -s "$C/SourcePackages/Build/blob" ] || gone='SourcePackages removed'
[ "$gone" = ok ] && check 'fixed target dirs and SourcePackages are never pruned' ok || check 'fixed target dirs and SourcePackages are never pruned' "$gone"
[ -d "$C/build-derived/locked-eeee" ] && check 'entry with a live .lock owner is kept' ok || check 'entry with a live .lock owner is kept' removed
[ -d "$C/e2e-derived/claimed-ffff" ] && check 'entry with a kernel-held claim is kept' ok || check 'entry with a kernel-held claim is kept' removed
release_cache_claim "$C/e2e-derived/claimed-ffff"
[ -d "$C/build-derived/fresh-gggg" ] && check 'recently used entry is kept' ok || check 'recently used entry is kept' removed
[ -d "$TMPDIR/legato-mac.NEW1" ] && [ -d "$TMPDIR/legato-xcodegen-1" ] && [ -d "$TMPDIR/unrelated-old" ] && [ -d "$TMPDIR/legato-e2e.LIVE" ] \
  && check 'recent legato-*, xcodegen tool cache, non-legato and live-owner TMPDIR dirs are kept' ok || check 'recent legato-*, xcodegen tool cache, non-legato and live-owner TMPDIR dirs are kept' removed
[ -d "$T/dd/LegatoMac-recent" ] && [ -d "$T/dd/OtherApp-xyz" ] && check 'recent Xcode copy and other projects are kept' ok || check 'recent Xcode copy and other projects are kept' removed
[ -L "$C/linked-cache" ] && [ -L "$C/derived/linked-target" ] && [ -L "$C/device-derived/linked-entry" ] && [ -d "$OUTSIDE/victim" ] \
  && check 'symlinks are neither followed nor removed' ok || check 'symlinks are neither followed nor removed' 'touched'
[ -d "$LEGATO_TESTS_CACHE/Models/m" ] && [ -d "$LEGATO_SCRATCH_ROOT/-Users-x-Documents-legato/sess/scratchpad/DerivedData" ] \
  && check 'LegatoTests models and agent scratchpads are not touched' ok || check 'LegatoTests models and agent scratchpads are not touched' removed
[ -e "$C/derived/mac.guard" ] && [ -e "$C/SourcePackages.guard" ] && check 'lock guard files are kept' ok || check 'lock guard files are kept' removed
rmdir_mac_lock

# --- Report: per-target sizes, prunable items, no deletion. ---
tree "$C/stale-report" $OLD
"$ROOT/scripts/dev/prune-build-caches.sh" --report > "$T/report.log"
rep=ok
for label in 'derived/ios-device' 'derived/ios-sim' 'derived/mac' 'derived/gate' 'SourcePackages' 'Kept total' "$C/stale-report" 'Prunable total'; do
  grep -q -- "$label" "$T/report.log" || rep="missing $label"
done
mac_kb="$(awk '/derived\/mac/ {print $1}' "$T/report.log")"
{ [ "$rep" = ok ] && [ -n "$mac_kb" ] && [ "$mac_kb" -ge 1024 ]; } && check 'report lists sizes per target and the prunable items' ok || check 'report lists sizes per target and the prunable items' "$rep kb=${mac_kb:-none}"
[ -d "$C/stale-report" ] && check 'report deletes nothing' ok || check 'report deletes nothing' removed
[ "$fails" = 0 ] || { echo "$fails prune checks failed"; exit 1; }

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
expected="$C/derived/mac"
grep -Fx -- "$expected" "$BUILD_ARGS" >/dev/null || { echo 'FAIL mac build does not use the fixed derived/mac'; exit 1; }
grep -Fx -- "$C/SourcePackages" "$BUILD_ARGS" >/dev/null || { echo 'FAIL mac build does not share package clones'; exit 1; }
[ ! -d "$expected.lock" ] && [ ! -d "$C/SourcePackages.lock" ] || { echo 'FAIL mac build leaks locks'; exit 1; }
[ -z "$(find "$C/derived" "$C/build-derived" -mindepth 1 -maxdepth 1 -name 'mac-*' -print -quit 2>/dev/null)" ] || { echo 'FAIL mac build created another build directory'; exit 1; }
echo 'PASS mac-build entry point uses derived/mac, shared clones and releases locks'
# A second build (even from another checkout path) lands in the same directory.
: > "$expected/earlier-build-output"
env -u CI PATH="$T/bin:$PATH" bash "$ROOT/scripts/ci/release.sh" mac-build > "$T/mac2.log"
[ -e "$expected/earlier-build-output" ] && [ "$(grep -Fxc -- "$expected" "$BUILD_ARGS")" = 2 ] || { echo 'FAIL second mac build did not reuse derived/mac'; exit 1; }
echo 'PASS repeated mac-build reuses the same directory'
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

# The local gate helper uses its own fixed directory.
# shellcheck disable=SC2016 # The child shell expands its own environment.
env -u CI bash -c '
  set -euo pipefail
  source "$1/scripts/e2e/work-dir.sh"
  trap finish_build_cache EXIT
  prepare_build_cache gate
  [ "$BUILD_WORK" = "$LEGATO_CACHE_DIR/derived/gate" ]
  [ "$BUILD_PACKAGES" = "$LEGATO_CACHE_DIR/SourcePackages" ]
' fixture "$ROOT" > "$T/gate.log"
echo 'PASS local gate uses derived/gate and shared clones'
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

# Run real simulator startup, stopping at the XcodeGen boundary.
cat > "$T/bin/xcodegen" <<'STUB'
#!/bin/bash
if [ "$1" = --version ]; then printf 'Version: %s\n' "$(cat .xcodegen-version)"; exit; fi
if [ -d "$LEGATO_CACHE_DIR/SourcePackages" ] && [ -d "$LEGATO_CACHE_DIR/derived/ios-sim" ] &&
   [ -d "$LEGATO_CACHE_DIR/derived/ios-sim.lock" ] && [ -d "$LEGATO_CACHE_DIR/SourcePackages.lock" ]; then
  echo ready > "$BUILD_ARGS.startup"
else
  echo missing > "$BUILD_ARGS.startup"
fi
exit 77 # Stop before simulator/build work.
STUB
rm -rf "$C/SourcePackages" "$C/derived/ios-sim"
startup_status=0
env -u CI PATH="$T/bin:$PATH" bash "$ROOT/scripts/e2e/ios-sim.sh" release-check > "$T/startup.log" 2>&1 || startup_status=$?
[ "$startup_status" = 2 ] || { echo 'FAIL simulator did not stop at fake XcodeGen'; exit 1; }
new_fails=0
if [ "$(cat "$BUILD_ARGS.startup")" = ready ]; then
  echo 'PASS simulator holds derived/ios-sim and package locks and recreates both'
else
  echo 'FAIL simulator did not create and lock derived/ios-sim and SourcePackages'; new_fails=$((new_fails+1))
fi
[ ! -d "$C/derived/ios-sim.lock" ] && [ ! -d "$C/SourcePackages.lock" ] || { echo 'FAIL simulator exit leaked locks'; new_fails=$((new_fails+1)); }

# An explicit LEGATO_E2E_DERIVED override bypasses the shared directory.
rm -rf "$C/derived/ios-sim"
env -u CI LEGATO_E2E_DERIVED="$T/custom-derived" PATH="$T/bin:$PATH" bash "$ROOT/scripts/e2e/ios-sim.sh" release-check > "$T/custom.log" 2>&1 || true
[ -d "$T/custom-derived" ] && [ ! -d "$C/derived/ios-sim" ] && echo 'PASS LEGATO_E2E_DERIVED override is honoured' || { echo 'FAIL LEGATO_E2E_DERIVED override ignored'; new_fails=$((new_fails+1)); }

# Timing out while waiting for clones must release the already-acquired DerivedData lock.
mkdir -p "$C/SourcePackages.lock"
proc_stamp "$$" > "$C/SourcePackages.lock/owner"
# shellcheck disable=SC2016 # The child shell expands its own environment.
if env -u CI LEGATO_LOCK_WAIT=0 bash -c '
  set -euo pipefail
  source "$1/scripts/e2e/work-dir.sh"
  trap finish_build_cache EXIT
  prepare_build_cache gate
' fixture "$ROOT" > "$T/timeout.log" 2>&1; then
  echo 'FAIL package lock unexpectedly acquired'; exit 1
fi
if [ ! -d "$C/derived/gate.lock" ]; then
  echo 'PASS package-lock timeout releases DerivedData lock'
else
  echo 'FAIL package-lock timeout leaked DerivedData lock'; new_fails=$((new_fails+1))
fi
unlock_dir "$C/SourcePackages"
[ "$new_fails" = 0 ]
