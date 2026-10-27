#!/usr/bin/env bash
# Remove build output that no live checkout owns. DRY RUN unless --delete is given.
#
# Usage: prune-build-caches.sh [--delete]
#
# Prunes:
#   1. ~/Library/Developer/Xcode/DerivedData/{Legato,LegatoMac,LegatoKit}-<hash> whose info.plist WorkspacePath no
#      longer exists (the worktree was deleted), plus the SwiftPM "<checkout name>-<hash>" sibling that shares
#      the hash of a pruned LegatoKit dir. Other projects' DerivedData is never touched.
#   2. <cache>/e2e-derived/<hash> (see ios-sim.sh) whose recorded checkout no longer exists.
#   3. Stale $TMPDIR/legato-e2e.* work dirs (dead owner; kept dirs after LEGATO_E2E_KEEP_DAYS), the same sweep
#      ios-sim.sh runs at start.
# Does not touch: DerivedData of live checkouts, <cache>/SourcePackages (shared, reused), a checkout's .build.
set -uo pipefail
# shellcheck source-path=SCRIPTDIR source=../e2e/work-dir.sh
source "$(dirname "${BASH_SOURCE[0]}")/../e2e/work-dir.sh"

delete=0
case "${1:-}" in
  "") ;;
  --delete) delete=1 ;;
  *) echo "usage: $0 [--delete]" >&2; exit 64 ;;
esac

DD="${LEGATO_DERIVED_DATA:-$HOME/Library/Developer/Xcode/DerivedData}"
total_kb=0

prune() { # prune <dir> <reason>
  local kb
  kb="$(du -sk "$1" 2> /dev/null | awk '{print $1}')"
  total_kb=$((total_kb + ${kb:-0}))
  printf '%6.0f MB  %s  (%s)\n' "$(echo "${kb:-0} / 1024" | bc)" "$1" "$2"
  if [ "$delete" = 1 ]; then rm -rf "$1"; fi
}

if [ "$delete" = 1 ]; then echo DELETING; else echo "DRY RUN (pass --delete to remove)"; fi

# 1. DerivedData of deleted checkouts.
pruned_hashes=""
if [ -d "$DD" ]; then
  for d in "$DD"/*/; do
    d="${d%/}"; name="$(basename "$d")"
    [[ "$name" =~ ^(Legato|LegatoMac|LegatoKit)-([a-z]{28})$ ]] || continue
    ws="$(/usr/libexec/PlistBuddy -c 'Print :WorkspacePath' "$d/info.plist" 2> /dev/null)" || continue
    [ -n "$ws" ] || continue
    [ -e "$ws" ] && continue
    case "$pruned_hashes" in *"${BASH_REMATCH[2]}"*) ;; *) pruned_hashes="$pruned_hashes ${BASH_REMATCH[2]}" ;; esac
    prune "$d" "workspace gone: $ws"
  done
  for h in $pruned_hashes; do   # SwiftPM package dirs are named after the checkout directory, same hash
    for d in "$DD"/*-"$h"; do
      [ -d "$d" ] && [ ! -f "$d/info.plist" ] && prune "$d" "package build of a deleted checkout"
    done
  done
fi

# 2. e2e DerivedData of deleted checkouts.
for d in "$(legato_cache_dir)"/e2e-derived/*/; do
  d="${d%/}"; [ -d "$d" ] || continue
  co="$(cat "$d/legato-checkout" 2> /dev/null)"
  if [ -z "$co" ] || [ ! -e "$co" ]; then prune "$d" "checkout gone: ${co:-unknown}"; fi
done

# 3. Stale e2e work dirs.
if [ "$delete" = 1 ]; then sweep_stale_work_dirs "${TMPDIR:-/tmp}"; echo "swept stale ${TMPDIR:-/tmp}legato-e2e.* dirs"
else sweep_stale_work_dirs "${TMPDIR:-/tmp}" 1; fi

printf 'Total in DerivedData and e2e caches: %.1f GB\n' "$(echo "$total_kb / 1048576" | bc -l)"
