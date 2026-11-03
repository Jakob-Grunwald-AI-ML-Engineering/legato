#!/usr/bin/env bash
# Simulator pruning and the shared spike cache, on private fixtures: a stubbed xcrun on PATH and a temp
# LEGATO_CACHE_DIR. Never talks to CoreSimulator and never touches the real spike dir.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
T="$(mktemp -d "${TEST_SCRATCH:-${TMPDIR:-/tmp}}/prune-sims-test.XXXXXX")"
trap 'rm -rf "$T"' EXIT
export LEGATO_CACHE_DIR="$T/cache" LEGATO_DERIVED_DATA="$T/dd" TMPDIR="$T/tmp" LEGATO_SIM_DEVICES="$T/devices"
export LEGATO_SCRATCH_ROOT="$T/claude" LEGATO_SCRATCH_PROJECT_GLOB='-Users-x-Documents-legato*' LEGATO_TESTS_CACHE="$T/LegatoTests"
mkdir -p "$TMPDIR" "$LEGATO_CACHE_DIR" "$T/bin" "$T/devices"
fails=0
check() { if [ "$2" = ok ]; then echo "PASS $1"; else echo "FAIL $1 ($2)"; fails=$((fails+1)); fi; }

# --- Stubbed xcrun: `simctl list devices -j` from $T/sims.tsv (udid name state); `simctl delete` is logged. ---
cat > "$T/bin/xcrun" <<'STUB'
#!/usr/bin/env bash
if [ "$1 $2 $3" = 'simctl list devices' ]; then
  python3 -I -c '
import json, sys
devs = [dict(udid=u, name=n, state=s, isAvailable=True) for u, n, s in (l.rstrip("\n").split("\t") for l in open(sys.argv[1]))]
print(json.dumps({"devices": {"iOS-26-5": devs}}))' "$STUB_SIMS"
elif [ "$1 $2" = 'simctl delete' ]; then echo "$3" >> "$STUB_LOG"
else echo "unexpected xcrun $*" >> "$STUB_LOG"; exit 1; fi
STUB
chmod +x "$T/bin/xcrun"
export PATH="$T/bin:$PATH" STUB_SIMS="$T/sims.tsv" STUB_LOG="$T/xcrun.log"
printf '%s\t%s\t%s\n' U-E2E legato-e2e Booted U-KB legato-e2e-kb Shutdown U-AF legato-autofill Shutdown U-58 legato58-production Shutdown \
  U-BOOT legato-live Booted U-PIN legato-pinned Shutdown U-OTHER 'iPhone 17' Shutdown > "$STUB_SIMS"
for u in U-E2E U-KB U-AF U-58 U-BOOT U-PIN U-OTHER; do mkdir "$T/devices/$u"; head -c 1048576 /dev/zero > "$T/devices/$u/blob"; done
: > "$STUB_LOG"
P="$ROOT/scripts/dev/prune-build-caches.sh"

"$P" --report > "$T/report.log"
grep -q 'simulator legato-e2e-kb (Shutdown) U-KB' "$T/report.log" && grep -q 'simulator legato-live (Booted) U-BOOT' "$T/report.log" \
  && check 'report lists stale legato-* simulators with state' ok || check 'report lists stale legato-* simulators' "$(cat "$T/report.log")"
! grep -q 'U-OTHER' "$T/report.log" && [ "$(grep -c 'U-E2E' "$T/report.log")" = 1 ] && grep -q "legato-e2e (Booted) U-E2E (ios-sim.sh's" "$T/report.log" \
  && check 'report shows legato-e2e once as kept, omits non-legato simulators' ok || check 'report shows legato-e2e once as kept, omits non-legato simulators' "$(cat "$T/report.log")"
grep -q 'shared spike cache' "$T/report.log" && check 'report shows the spike cache' ok || check 'report shows the spike cache' missing

LEGATO_E2E_UDID=U-PIN "$P" > "$T/dry.log"
[ ! -s "$STUB_LOG" ] && check 'dry run deletes nothing' ok || check 'dry run deletes nothing' "$(cat "$STUB_LOG")"
grep -q 'stale simulator: .* legato-e2e-kb U-KB' "$T/dry.log" && ! grep -q 'U-E2E' "$T/dry.log" \
  && check 'dry run names stale sims, never legato-e2e' ok || check 'dry run names stale sims, never legato-e2e' "$(cat "$T/dry.log")"

LEGATO_E2E_UDID=U-PIN "$P" --delete > "$T/delete.log"
[ "$(sort "$STUB_LOG" | tr '\n' ' ')" = 'U-58 U-AF U-KB ' ] && check 'delete removes only shut-down stale sims' ok || check 'delete removes only shut-down stale sims' "$(cat "$STUB_LOG")"
grep -q 'KEEP Booted simulator: legato-live U-BOOT' "$T/delete.log" && grep -q 'KEEP LEGATO_E2E_UDID simulator: legato-pinned U-PIN' "$T/delete.log" \
  && check 'booted and LEGATO_E2E_UDID sims are kept with KEEP lines' ok || check 'KEEP lines' "$(cat "$T/delete.log")"

: > "$STUB_LOG"
LEGATO_PRUNE_SIMULATORS=0 "$P" --delete > /dev/null
[ ! -s "$STUB_LOG" ] && check 'LEGATO_PRUNE_SIMULATORS=0 skips simulators' ok || check 'LEGATO_PRUNE_SIMULATORS=0 skips simulators' "$(cat "$STUB_LOG")"

# --- The spike cache is reported but never deleted by --delete. ---
mkdir -p "$LEGATO_CACHE_DIR/spikes/ane-cleanup/models/m"; head -c 1048576 /dev/zero > "$LEGATO_CACHE_DIR/spikes/ane-cleanup/models/m/w"
touch -t 202001010000 "$LEGATO_CACHE_DIR/spikes/ane-cleanup/models/m/w"
"$P" --delete > /dev/null
[ -f "$LEGATO_CACHE_DIR/spikes/ane-cleanup/models/m/w" ] && check 'prune --delete keeps the shared spike cache' ok || check 'prune --delete keeps the shared spike cache' gone

# --- cache-link.sh on a copy of the spike scripts (tracked spike files untouched). ---
S="$T/spike"; mkdir -p "$S/scripts" "$S/conversion"; cp "$ROOT/spikes/ane-cleanup/scripts/cache-link.sh" "$S/scripts/"
echo tracked > "$S/conversion/keep.txt"
L="$LEGATO_CACHE_DIR/spikes/ane-cleanup"
rm -rf "$L"
mkdir -p "$S/.cache" "$S/models"; echo src > "$S/.cache/anemll.tar.gz"; echo w > "$S/models/weights"   # a pre-existing real cache
bash "$S/scripts/cache-link.sh" > /dev/null
{ [ -L "$S/.cache" ] && [ -L "$S/models" ] && [ "$(cat "$S/.cache/anemll.tar.gz")" = src ] && [ -f "$L/models/weights" ]; } \
  && check 'real .cache/models migrate into the shared dir and become symlinks' ok || check 'migration' failed
bash "$S/scripts/cache-link.sh" > /dev/null && [ "$(readlink "$S/.cache")" = "$L/cache" ] && check 'cache-link is idempotent' ok || check 'cache-link is idempotent' failed
S2="$T/spike2"; mkdir -p "$S2/scripts"; cp "$S/scripts/cache-link.sh" "$S2/scripts/"   # a fresh worktree
bash "$S2/scripts/cache-link.sh" > /dev/null && [ "$(cat "$S2/.cache/anemll.tar.gz")" = src ] \
  && check 'a fresh worktree reuses the shared cache' ok || check 'a fresh worktree reuses the shared cache' failed
S3="$T/spike3"; mkdir -p "$S3/scripts" "$S3/.cache"; cp "$S/scripts/cache-link.sh" "$S3/scripts/"; echo other > "$S3/.cache/anemll.tar.gz"
if bash "$S3/scripts/cache-link.sh" 2> /dev/null; then check 'name clash refuses' succeeded
elif [ -d "$S3/.cache" ] && [ ! -L "$S3/.cache" ] && [ "$(cat "$S3/.cache/anemll.tar.gz")" = other ] && [ "$(cat "$L/cache/anemll.tar.gz")" = src ]; then check 'name clash keeps both copies' ok
else check 'name clash keeps both copies' damaged; fi
[ "$(cat "$S/conversion/keep.txt")" = tracked ] && check 'tracked spike files untouched' ok || check 'tracked spike files untouched' changed

[ "$fails" = 0 ] || { echo "$fails prune-sims checks failed"; exit 1; }
