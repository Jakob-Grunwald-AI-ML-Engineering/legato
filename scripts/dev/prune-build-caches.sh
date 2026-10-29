#!/usr/bin/env bash
# Remove build output that no live checkout owns. DRY RUN unless --delete is given.
#
# Usage: prune-build-caches.sh [--delete]
#
# Managed pass: 48-hour last-use TTL and 10 GiB soft cap across marked build-derived,
# e2e-derived and SourcePackages entries, skipping every locked entry. --managed-only
# omits the legacy passes below. Symlink entries and unmarked paths are excluded.
#
# Legacy passes:
#   1. ~/Library/Developer/Xcode/DerivedData/{Legato,LegatoMac,LegatoKit}-<hash> whose info.plist WorkspacePath no
#      longer exists (the worktree was deleted), plus the SwiftPM "<checkout name>-<hash>" sibling that shares
#      the hash of a pruned LegatoKit dir. Other projects' DerivedData is never touched.
#   2. <cache>/e2e-derived/<hash> (see ios-sim.sh) whose recorded checkout no longer exists.
#   3. Stale $TMPDIR/legato-e2e.* work dirs (dead owner; kept dirs after LEGATO_E2E_KEEP_DAYS), the same sweep
#      ios-sim.sh runs at start.
# Legacy passes do not touch live-checkout DerivedData or a checkout's .build.
set -uo pipefail
# shellcheck source-path=SCRIPTDIR source=../e2e/work-dir.sh
source "$(dirname "${BASH_SOURCE[0]}")/../e2e/work-dir.sh"

delete=0
managed_only=0
for arg in "$@"; do
  case "$arg" in
    --delete) delete=1 ;;
    --managed-only) managed_only=1 ;;
    *) echo "usage: $0 [--managed-only] [--delete]" >&2; exit 64 ;;
  esac
done

# Managed entries use a last-use stamp, never nested build-file mtimes. Lock before checking or
# removing: builders acquire this same lock before creating or touching their directory.
prune_managed() {
  local cache d kb stamp total=0 now max age rows candidate reason
  cache="$(legato_cache_dir)"
  [ -d "$cache" ] && [ ! -L "$cache" ] || return 0
  max="${LEGATO_CACHE_MAX_KB:-10485760}"
  age="${LEGATO_CACHE_MAX_AGE_SECONDS:-172800}"
  [[ "$max" =~ ^[0-9]+$ ]] && [[ "$age" =~ ^[0-9]+$ ]] || { echo 'Invalid cache limits' >&2; return 64; }
  now="$(date +%s)"
  rows=""
  for d in "$cache"/build-derived/* "$cache"/e2e-derived/* "$cache/SourcePackages"; do
    [ -d "$d" ] && [ ! -L "$d" ] || continue
    [ ! -L "$(dirname "$d")" ] || continue
    [ -f "$d/legato-managed" ] && [ ! -L "$d/legato-managed" ] || continue
    [ "$(cat "$d/legato-managed")" = v1 ] || continue
    [ -f "$d/legato-last-used" ] && [ ! -L "$d/legato-last-used" ] || continue
    kb="$(du -sk "$d" | awk '{print $1}')"
    stamp="$(stat -f %m "$d/legato-last-used" 2>/dev/null)" || return 1
    total=$((total + kb))
    rows="${rows}${stamp}"$'	'"${kb}"$'	'"${d}"$'
'
  done
  while IFS=$'	' read -r stamp kb d; do
    [ -n "$d" ] || continue
    reason=expired
    if [ "$((now - stamp))" -lt "$age" ]; then
      [ "$total" -gt "$max" ] || continue
      reason=cap
    fi
    # Pruning never steals a preexisting lock, even a stale or partially-written one.
    # Build entry points reclaim stale locks; ambiguous ownership always retains data here.
    if ! try_lock_dir "$d" 2>/dev/null; then
      echo "KEEP active: $d"
      continue
    fi
    if [ -L "$d" ] || [ -L "$(dirname "$d")" ] || [ -L "$d/legato-managed" ] ||
       [ -L "$d/legato-last-used" ] || [ "$(cat "$d/legato-managed" 2>/dev/null)" != v1 ]; then
      unlock_dir "$d"
      continue
    fi
    # A build may have finished since the inventory: re-read its explicit last-use stamp.
    candidate="$(stat -f %m "$d/legato-last-used" 2>/dev/null)" || { unlock_dir "$d"; continue; }
    if [ "$candidate" != "$stamp" ]; then
      echo "KEEP recently used: $d"
      unlock_dir "$d"
      continue
    fi
    # Retained estimate subtracts the same inventory contribution used above.
    if [ "$delete" = 1 ]; then
      if ! rm -rf "$d"; then unlock_dir "$d"; return 1; fi
    fi
    echo "${reason}: $kb KB $d"
    total=$((total - kb))
    unlock_dir "$d"
  done < <(printf '%s' "$rows" | sort -n)
  echo "Managed retained estimate: $total KB; cap $max KB (active entries can exceed cap; unmanaged paths excluded)."
}
if [ "$delete" = 1 ]; then echo DELETING; else echo "DRY RUN (pass --delete to remove)"; fi
prune_managed || exit $?
[ "$managed_only" = 0 ] || exit 0

DD="${LEGATO_DERIVED_DATA:-$HOME/Library/Developer/Xcode/DerivedData}"
total_kb=0

prune() { # prune <dir> <reason>
  local kb
  kb="$(du -sk "$1" 2> /dev/null | awk '{print $1}')"
  total_kb=$((total_kb + ${kb:-0}))
  printf '%6.0f MB  %s  (%s)\n' "$(echo "${kb:-0} / 1024" | bc)" "$1" "$2"
  if [ "$delete" = 1 ]; then rm -rf "$1"; fi
}


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
  d="${d%/}"; [ -d "$d" ] && [ ! -L "$d" ] || continue
  [ ! -f "$d/legato-managed" ] || continue
  try_lock_dir "$d" || continue
  co="$(cat "$d/legato-checkout" 2> /dev/null)"
  if [ -z "$co" ] || [ ! -e "$co" ]; then prune "$d" "checkout gone: ${co:-unknown}"; fi
  unlock_dir "$d"
done

# 3. Stale e2e work dirs.
if [ "$delete" = 1 ]; then sweep_stale_work_dirs "${TMPDIR:-/tmp}"; echo "swept stale ${TMPDIR:-/tmp}legato-e2e.* dirs"
else sweep_stale_work_dirs "${TMPDIR:-/tmp}" 1; fi

printf 'Total in DerivedData and e2e caches: %.1f GB\n' "$(echo "$total_kb / 1048576" | bc -l)"
