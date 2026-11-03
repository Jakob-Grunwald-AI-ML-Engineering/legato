#!/usr/bin/env bash
# The e2e runner must dispatch real scenarios and refuse to pass when none run. No Xcode build, no simulator.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
RUNNER="$ROOT/scripts/e2e/ios-sim.sh"
fails=0
check() { if [ "$2" = ok ]; then echo "PASS $1"; else echo "FAIL $1 ($2)"; fails=$((fails+1)); fi; }

names="$(/bin/bash "$RUNNER" list)"
if [ -n "$names" ]; then check "scenario list is not empty" ok; else check "scenario list is not empty" empty; fi
missing=""
while IFS= read -r name; do
  [ -n "$name" ] || continue
  grep -q "^scenario_${name}()" "$RUNNER" || missing="$missing $name"
done <<< "$names"
if [ -z "$missing" ]; then check "every listed scenario has a scenario_<name> function" ok; else check "every listed scenario has a scenario_<name> function" "missing:$missing"; fi
dupes="$(sort <<< "$names" | uniq -d)"
if [ -z "$dupes" ]; then check "scenario names are unique" ok; else check "scenario names are unique" "$dupes"; fi
# Every scenario function is listed (a function nobody dispatches never runs).
unlisted=""
while IFS= read -r fn; do
  grep -qx "$fn" <<< "$names" || unlisted="$unlisted $fn"
done < <(sed -n 's/^scenario_\([a-z0-9_]*\)().*/\1/p' "$RUNNER")
if [ -z "$unlisted" ]; then check "every scenario function is listed" ok; else check "every scenario function is listed" "unlisted:$unlisted"; fi
if grep -q "scenario_\$name" "$RUNNER"; then check "the runner dispatches scenario_<name>" ok; else check "the runner dispatches scenario_<name>" "no dispatch line"; fi

for only in "no_such_scenario" " " "composer no_such_scenario"; do
  rc=0
  out="$(LEGATO_E2E_ONLY="$only" /bin/bash "$RUNNER" run 2>&1)" || rc=$?
  if [ "$rc" -ne 0 ] && grep -q 'LEGATO_E2E_ONLY' <<< "$out"; then check "ONLY=<$only> fails before any build" ok
  else check "ONLY=<$only> fails before any build" "rc=$rc: $out"; fi
done
rc=0; /bin/bash "$RUNNER" bogus > /dev/null 2>&1 || rc=$?
if [ "$rc" -ne 0 ]; then check "unknown mode fails" ok; else check "unknown mode fails" "rc=0"; fi
[ "$fails" -eq 0 ]
