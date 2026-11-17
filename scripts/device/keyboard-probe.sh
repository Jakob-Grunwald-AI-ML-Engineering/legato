#!/bin/bash
# One interactive operation against the real internal keyboard extension. No preset walk.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
target=device
if [ "${1:-}" = --target ]; then
  [ "$#" -ge 3 ] || { echo 'Usage: keyboard-probe.sh [--target device|sim] ACTION [ARGS...]' >&2; exit 2; }
  target="$2"
  shift 2
fi
case "$target" in device|sim) ;; *) echo 'Probe target must be device or sim.' >&2; exit 2 ;; esac
case "${1:-}" in
  ''|-h|--help|help)
    cat <<'HELP'
Usage: keyboard-probe.sh [--target device|sim] ACTION [ARGS...]

begin                         Hold the real keyboard queue; bind the current field.
read                          Read exact current proxy windows and selection.
move SIGNED_DELTA [SETTLE_MS]   One native cursor move; settle defaults to zero.
pause MILLISECONDS            Wait the chosen interval, then read again.
delete N [SETTLE_MS]          N deleteBackward calls back to back.
insert TEXT [SETTLE_MS]       One insertText call.
burst MOVE N TEXT BACK [SETTLE_MS]
                              Move, N deletes, insert TEXT ('' for none), move BACK; no waits.
status                        Inspect the current probe lease and field.
end                           Release ownership at the current cursor; no return move.

Choose one action, inspect its result, then choose the next action.
Writes run only in a synthetic field: empty at begin, or showing PROBE: in its window.
Moves and writes return every host callback and silent window change until SETTLE_MS.
No model calls, scripted walks or automatic cursor return.
Requires an internal build, a running host and the real Legato keyboard in a
synthetic test field. Full text is returned: keep raw output private.
Existing LEGATO_DEVICE / LEGATO_SIMULATOR / LEGATO_BUNDLE identity variables apply.
LEGATO_PROBE_TIMEOUT sets the reply budget in seconds (default 45).
HELP
    exit 0 ;;
esac

# The extension owns argument validation and cursor semantics. Do not reinterpret
# native deltas as characters/UTF-16 units or normalize the returned windows here.
id="$(bash "$here/ctl.sh" --target "$target" send keyboard-probe "$@")"
bash "$here/ctl.sh" --target "$target" wait "$id" "${LEGATO_PROBE_TIMEOUT:-45}"
