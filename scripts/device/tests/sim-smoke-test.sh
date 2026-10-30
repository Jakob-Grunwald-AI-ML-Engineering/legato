#!/usr/bin/env bash
# Exercise smoke preference ownership with the CLI transport boundary substituted.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
export LEGATO_SIMULATOR=preference-fixture
LEGATO_SMOKE_OUTPUT="$(mktemp -d /tmp/legato-smoke-preferences.XXXXXX)"
export LEGATO_SMOKE_OUTPUT
work="$LEGATO_SMOKE_OUTPUT"
# Load the real production prefix without starting its runtime drive. Bash 3's source
# can return before reading a process-substitution pipe; use a complete regular file.
definitions="$work/smoke-definitions.sh"
sed '/^save_preferences$/,$d' "$ROOT/scripts/device/tests/sim-smoke.sh" > "$definitions"
# shellcheck disable=SC1090
source "$definitions"
fixture_ctl() {
  if [ "$1" = send ]; then
    if [ "$2" = set-setting ]; then printf '%s=%s\n' "$3" "$4" >> "$work/restored"; fi
    echo fixture-command
  elif [ "$1" = wait ]; then
    echo '{"event":"done","settings":{"audioPolicy":"pauseOthers","debugShowPauseOthers":true,"debugForceTapToCopy":true}}'
  fi
}
ctl() { fixture_ctl "$@"; }
save_preferences
restore_preferences
printf '%s\n' 'audioPolicy=pauseOthers' 'debugShowPauseOthers=true' 'debugForceTapToCopy=true' > "$work/expected"
if ! cmp "$work/expected" "$work/restored"; then echo 'FAIL smoke did not restore all changed settings' >&2; exit 1; fi
# Successful restoration is idempotent, including the EXIT cleanup path.
restore_preferences
cmp "$work/expected" "$work/restored"
echo 'PASS smoke snapshots and restores every changed preference once'
failure_rc=0
(
  export LEGATO_SMOKE_OUTPUT="$LEGATO_SMOKE_OUTPUT/failure"
  # shellcheck disable=SC1090
  source "$definitions"
  # Called by sourced smoke functions and their EXIT trap.
  # shellcheck disable=SC2329
  ctl() { fixture_ctl "$@"; }
  save_preferences
  exit 23
) || failure_rc=$?
[ "$failure_rc" -eq 23 ]
cmp "$work/expected" "$work/failure/restored"
echo 'PASS smoke restores settings on failure and preserves the original failure status'
