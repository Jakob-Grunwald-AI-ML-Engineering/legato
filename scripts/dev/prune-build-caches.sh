#!/usr/bin/env bash
# Remove build output that no live checkout owns. DRY RUN unless --delete is given.
#
# Usage: prune-build-caches.sh [--managed-only] [--delete] | --report
#
# --report prints legato temp + cache disk use per category against the 10 GiB budget, then exits.
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
#
# Unmanaged pass (default run only; joins the managed list, so the same TTL and cap apply, oldest first):
#   - build output (DerivedData roots, SourcePackages, .build) in agent scratchpads
#     $LEGATO_SCRATCH_ROOT/$LEGATO_SCRATCH_PROJECT_GLOB/*/scratchpad
#     (defaults: /private/tmp/claude-<uid>, -<home path with dashes>-Documents-legato*)
#   - $TMPDIR/legato-* dirs, except legato-e2e.* (own sweep) and legato-xcodegen-* (tool cache)
#   - unmarked top-level dirs of the legato cache dir and non-Models children of $LEGATO_TESTS_CACHE
#     (default ~/Library/Caches/LegatoTests); downloaded Models are never pruned.
# In use = a .lock dir, a kernel-held .guard claim, or any file modified inside the window: the TTL
# (LEGATO_UNMANAGED_MAX_AGE_SECONDS, default = managed TTL) for expiry, LEGATO_UNMANAGED_GRACE_SECONDS
# (default 3600) for cap eviction.
set -uo pipefail
# shellcheck source-path=SCRIPTDIR source=../e2e/work-dir.sh
source "$(dirname "${BASH_SOURCE[0]}")/../e2e/work-dir.sh"

delete=0
managed_only=0
report=0
for arg in "$@"; do
  case "$arg" in
    --delete) delete=1 ;;
    --managed-only) managed_only=1 ;;
    --report) report=1 ;;
    *) echo "usage: $0 [--managed-only] [--delete] | --report" >&2; exit 64 ;;
  esac
done
if [ "$report" = 1 ] && [ "$delete$managed_only" != 00 ]; then echo "usage: --report takes no other flag" >&2; exit 64; fi

# Agent scratchpads of legato projects only: <root>/<project glob>/<session>/scratchpad.
scratchpad_roots() {
  local root glob p sp
  root="${LEGATO_SCRATCH_ROOT:-/private/tmp/claude-$(id -u)}"
  glob="${LEGATO_SCRATCH_PROJECT_GLOB:-${HOME//\//-}-Documents-legato*}"
  [ -d "$root" ] && [ ! -L "$root" ] || return 0
  for p in "$root"/$glob; do   # unquoted on purpose: the glob selects the legato project dirs
    [ -d "$p" ] && [ ! -L "$p" ] || continue
    for sp in "$p"/*/scratchpad; do
      if [ -d "$sp" ] && [ ! -L "$sp" ]; then echo "$sp"; fi
    done
  done
}
# Build output inside scratchpads: SourcePackages, DerivedData, .build and the parent of any
# ModuleCache.noindex (a DerivedData root). Never a scratchpad itself, never through symlinks.
scratch_build_dirs() {
  local sp
  while IFS= read -r sp; do
    find "$sp" -mindepth 1 -maxdepth 8 -type d \( -name DerivedData -o -name SourcePackages -o -name .build \) -prune -print 2> /dev/null
    find "$sp" -mindepth 2 -maxdepth 8 -type d -name ModuleCache.noindex -prune -exec dirname {} \; 2> /dev/null
  done < <(scratchpad_roots) | sort -u | awk 'last != "" && index($0, last "/") == 1 { next } { print; last = $0 }'
}
tmp_legato_dirs() {
  local d
  for d in "${TMPDIR:-/tmp}"/legato-*; do
    [ -d "$d" ] && [ ! -L "$d" ] || continue
    case "$(basename "$d")" in legato-e2e.* | legato-xcodegen-*) continue ;; esac
    echo "$d"
  done
}
cache_unmarked_dirs() {
  local cache d
  cache="$(legato_cache_dir)"
  [ -d "$cache" ] && [ ! -L "$cache" ] || return 0
  for d in "$cache"/*; do
    [ -d "$d" ] && [ ! -L "$d" ] || continue
    case "$(basename "$d")" in build-derived | e2e-derived) continue ;; esac
    [ ! -f "$d/legato-managed" ] && echo "$d"
  done
}
tests_cache() { echo "${LEGATO_TESTS_CACHE:-$HOME/Library/Caches/LegatoTests}"; }
tests_leftover_dirs() {
  local d tc
  tc="$(tests_cache)"
  [ -d "$tc" ] && [ ! -L "$tc" ] || return 0
  for d in "$tc"/*; do
    [ -d "$d" ] && [ ! -L "$d" ] || continue
    [ "$(basename "$d")" = Models ] || echo "$d"
  done
}
kb_of() { du -sk "$1" 2> /dev/null | awk '{s += $1} END {print s + 0}'; }
sum_kb() { local d kb=0; while IFS= read -r d; do [ -n "$d" ] && kb=$((kb + $(kb_of "$d"))); done; echo "$kb"; }
# True while anything under $1 changed within the last $2 seconds.
recent_in_tree() { [ -n "$(find "$1" -mmin "-$((($2 + 59) / 60))" -print -quit 2> /dev/null)" ]; }

report_usage() {
  local budget sum=0 kb d
  budget="${LEGATO_CACHE_MAX_KB:-10485760}"
  row() { printf '%12d KB  %s\n' "$2" "$1"; }
  tally() { row "$1" "$2"; sum=$((sum + $2)); }
  echo 'Legato disk usage (du, allocated KB)'
  row 'scratchpad build output (part of the next line, not added again)' "$(scratch_build_dirs | sum_kb)"
  tally 'agent scratchpads (legato projects, all content)' "$(scratchpad_roots | sum_kb)"
  tally 'TMPDIR legato-* dirs' "$(for d in "${TMPDIR:-/tmp}"/legato-*; do [ -d "$d" ] && [ ! -L "$d" ] && echo "$d"; done | sum_kb)"
  tally "legato cache $(legato_cache_dir)" "$(kb_of "$(legato_cache_dir)")"
  tally "LegatoTests caches $(tests_cache) (incl. Models)" "$(kb_of "$(tests_cache)")"
  kb=0
  for d in "${LEGATO_DERIVED_DATA:-$HOME/Library/Developer/Xcode/DerivedData}"/{Legato,LegatoMac,LegatoKit}-*; do
    [ -d "$d" ] && kb=$((kb + $(kb_of "$d")))
  done
  tally 'Xcode DerivedData Legato*' "$kb"
  printf '%12d KB  Total (%.1f GB)\n' "$sum" "$(echo "$sum / 1048576" | bc -l)"
  printf '%12d KB  Budget (%.1f GB): %s\n' "$budget" "$(echo "$budget / 1048576" | bc -l)" \
    "$([ "$sum" -le "$budget" ] && echo within || echo OVER)"
}
if [ "$report" = 1 ]; then report_usage; exit 0; fi

# Managed entries use a last-use stamp, never nested build-file mtimes. Lock before checking or
# removing: builders acquire this same lock before creating or touching their directory.
# Unmanaged candidates (see header) share the list, TTL and cap but are judged by tree activity.
prune_managed() {
  local cache d kb stamp kind total=0 now max age uage grace rows candidate reason locked
  cache="$(legato_cache_dir)"
  max="${LEGATO_CACHE_MAX_KB:-10485760}"
  age="${LEGATO_CACHE_MAX_AGE_SECONDS:-172800}"
  uage="${LEGATO_UNMANAGED_MAX_AGE_SECONDS:-$age}"
  grace="${LEGATO_UNMANAGED_GRACE_SECONDS:-3600}"
  [[ "$max" =~ ^[0-9]+$ ]] && [[ "$age" =~ ^[0-9]+$ ]] && [[ "$uage" =~ ^[0-9]+$ ]] && [[ "$grace" =~ ^[0-9]+$ ]] ||
    { echo 'Invalid cache limits' >&2; return 64; }
  now="$(date +%s)"
  rows=""
  if [ -d "$cache" ] && [ ! -L "$cache" ]; then
    for d in "$cache"/build-derived/* "$cache"/e2e-derived/* "$cache/SourcePackages"; do
      [ -d "$d" ] && [ ! -L "$d" ] || continue
      [ ! -L "$(dirname "$d")" ] || continue
      [ -f "$d/legato-managed" ] && [ ! -L "$d/legato-managed" ] || continue
      [ "$(cat "$d/legato-managed")" = v1 ] || continue
      [ -f "$d/legato-last-used" ] && [ ! -L "$d/legato-last-used" ] || continue
      kb="$(du -sk "$d" | awk '{print $1}')"
      stamp="$(stat -f %m "$d/legato-last-used" 2>/dev/null)" || return 1
      total=$((total + kb))
      rows="${rows}${stamp}"$'\tM\t'"${kb}"$'\t'"${d}"$'\n'
    done
  fi
  if [ "$managed_only" = 0 ]; then
    while IFS= read -r d; do
      [ -n "$d" ] || continue
      stamp="$(stat -f %m "$d" 2>/dev/null)" || continue
      kb="$(kb_of "$d")"
      total=$((total + kb))
      rows="${rows}${stamp}"$'\tU\t'"${kb}"$'\t'"${d}"$'\n'
    done < <({ scratch_build_dirs; tmp_legato_dirs; cache_unmarked_dirs; tests_leftover_dirs; } | sort -u)
  fi
  while IFS=$'\t' read -r stamp kind kb d; do
    [ -n "$d" ] || continue
    if [ "$kind" = U ]; then
      if ! recent_in_tree "$d" "$uage"; then reason=expired
      elif [ "$total" -gt "$max" ] && ! recent_in_tree "$d" "$grace"; then reason=cap
      else continue; fi
      # Claimed = a .lock marker, or a kernel-held claim (a .guard file exists only where something locked).
      locked=0
      if [ -e "$d.lock" ]; then echo "KEEP active: $d"; continue; fi
      if [ -e "$d.guard" ]; then
        if ! try_lock_dir "$d" 2> /dev/null; then echo "KEEP active: $d"; continue; fi
        locked=1
      fi
      if [ -L "$d" ] || recent_in_tree "$d" "$grace"; then
        [ "$locked" = 0 ] || unlock_dir "$d"
        echo "KEEP recently used: $d"; continue
      fi
      if [ "$delete" = 1 ] && ! rm -rf "$d"; then
        [ "$locked" = 0 ] || unlock_dir "$d"
        return 1
      fi
      echo "${reason}: $kb KB $d"
      total=$((total - kb))
      [ "$locked" = 0 ] || unlock_dir "$d"
      continue
    fi
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
  echo "Retained estimate: $total KB; cap $max KB (active entries can exceed cap)."
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
