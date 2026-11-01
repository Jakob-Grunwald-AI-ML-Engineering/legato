#!/usr/bin/env bash
# Remove every Legato build output except the fixed per-target DerivedData. DRY RUN unless --delete is given.
#
# Usage: prune-build-caches.sh [--delete] | --report
#
# Kept (never removed):  <cache>/derived/{ios-device,ios-sim,mac,gate}  and  <cache>/SourcePackages
#   (<cache> = ${LEGATO_CACHE_DIR:-~/Library/Caches/legato}), plus their .lock/.guard lock files.
# Removed:
#   - everything else in <cache> (old build-derived/, e2e-derived/, device-derived/, unknown entries) and
#     everything else in <cache>/derived/
#   - stale $TMPDIR/legato-* dirs (CI-style gate/mac work dirs) and dead $TMPDIR/legato-e2e.* work dirs;
#     the legato-xcodegen-* tool cache is kept
#   - ~/Library/Developer/Xcode/DerivedData/Legato* (the IDE's per-checkout copies)
# Skipped, with a KEEP line: anything locked (.lock owner dir or kernel-held .guard claim), anything
# modified within the last LEGATO_PRUNE_GRACE_SECONDS (default 3600), and symlinks (never followed).
# Never touched: installed/delivered apps, ~/Library/Caches/LegatoTests (downloaded models), agent scratchpads.
#
# --report prints disk use per fixed directory and per prunable item, deleting nothing.
set -uo pipefail
# shellcheck source-path=SCRIPTDIR source=../e2e/work-dir.sh
source "$(dirname "${BASH_SOURCE[0]}")/../e2e/work-dir.sh"

delete=0
report=0
for arg in "$@"; do
  case "$arg" in
    --delete) delete=1 ;;
    --report) report=1 ;;
    *) echo "usage: $0 [--delete] | --report" >&2; exit 64 ;;
  esac
done
if [ "$report" = 1 ] && [ "$delete" = 1 ]; then echo "usage: --report takes no other flag" >&2; exit 64; fi

grace="${LEGATO_PRUNE_GRACE_SECONDS:-3600}"
[[ "$grace" =~ ^[0-9]+$ ]] || { echo 'Invalid LEGATO_PRUNE_GRACE_SECONDS' >&2; exit 64; }
cache="$(legato_cache_dir)"
xcode_dd="${LEGATO_DERIVED_DATA:-$HOME/Library/Developer/Xcode/DerivedData}"
tests_cache="${LEGATO_TESTS_CACHE:-$HOME/Library/Caches/LegatoTests}"

kb_of() { du -sk "$1" 2> /dev/null | awk '{s += $1} END {print s + 0}'; }
# True while anything under $1 changed within the last $2 seconds.
recent_in_tree() { [ -n "$(find "$1" -mmin "-$((($2 + 59) / 60))" -print -quit 2> /dev/null)" ]; }
is_fixed() { # is_fixed <name under derived/>
  local t
  for t in "${LEGATO_BUILD_TARGETS[@]}"; do [ "$t" != "$1" ] || return 0; done
  return 1
}
# Lock-protocol files that sit beside a directory; kept for the lifetime of the cache (see build-caches.md).
is_lock_file() { case "$1" in *.guard | *.lock) return 0 ;; *) return 1 ;; esac; }

# Prunable top-level items: in <cache> everything but derived/SourcePackages/lock files, and in
# <cache>/derived everything but the fixed targets and lock files. Symlinks are listed too (and skipped).
cache_extras() {
  local d n
  [ -d "$cache" ] && [ ! -L "$cache" ] || return 0
  for d in "$cache"/* "$cache"/.[!.]*; do
    [ -e "$d" ] || [ -L "$d" ] || continue
    n="$(basename "$d")"
    is_lock_file "$n" && continue
    case "$n" in derived | SourcePackages) continue ;; esac
    echo "$d"
  done
  [ -d "$cache/derived" ] && [ ! -L "$cache/derived" ] || return 0
  for d in "$cache"/derived/* "$cache"/derived/.[!.]*; do
    [ -e "$d" ] || [ -L "$d" ] || continue
    n="$(basename "$d")"
    is_lock_file "$n" && continue
    is_fixed "$n" || echo "$d"
  done
}
tmp_legato_dirs() { # legato-e2e.* has its own owner-based sweep; legato-xcodegen-* is a tool cache
  local d
  for d in "${TMPDIR:-/tmp}"/legato-*; do
    [ -d "$d" ] || [ -L "$d" ] || continue
    case "$(basename "$d")" in legato-e2e.* | legato-xcodegen-*) continue ;; esac
    echo "$d"
  done
}
xcode_legato_dirs() {
  local d
  for d in "$xcode_dd"/Legato*; do
    [ -d "$d" ] || [ -L "$d" ] || continue
    echo "$d"
  done
}
scratchpad_build_kb() { # informational only: agent scratchpad content is never pruned here
  local root glob p sp kb=0
  root="${LEGATO_SCRATCH_ROOT:-/private/tmp/claude-$(id -u)}"
  glob="${LEGATO_SCRATCH_PROJECT_GLOB:-${HOME//\//-}-Documents-legato*}"
  [ -d "$root" ] && [ ! -L "$root" ] || { echo 0; return; }
  for p in "$root"/$glob; do   # unquoted on purpose: the glob selects the legato project dirs
    [ -d "$p" ] && [ ! -L "$p" ] || continue
    for sp in "$p"/*/scratchpad; do
      if [ -d "$sp" ] && [ ! -L "$sp" ] && [ ! -L "${sp%/scratchpad}" ]; then kb=$((kb + $(kb_of "$sp"))); fi
    done
  done
  echo "$kb"
}

row() { printf '%12d KB  %s\n' "$2" "$1"; }

if [ "$report" = 1 ]; then
  keep=0 extra=0 kb=0
  echo "Legato disk usage (du, allocated KB); cache $cache"
  echo 'Kept: one DerivedData per build target, one SourcePackages'
  for t in "${LEGATO_BUILD_TARGETS[@]}"; do
    kb="$(kb_of "$(derived_dir "$t")")"; row "derived/$t" "$kb"; keep=$((keep + kb))
  done
  kb="$(kb_of "$(packages_dir)")"; row 'SourcePackages' "$kb"; keep=$((keep + kb))
  row 'Kept total' "$keep"
  echo 'Prunable (--delete removes unless locked or recently used):'
  while IFS= read -r d; do
    [ -n "$d" ] || continue
    kb="$(kb_of "$d")"; row "$d" "$kb"; extra=$((extra + kb))
  done < <({ cache_extras; tmp_legato_dirs; xcode_legato_dirs; } | sort -u)
  row 'Prunable total' "$extra"
  echo 'Not pruned (informational):'
  row "LegatoTests caches $tests_cache" "$(kb_of "$tests_cache")"
  row 'agent scratchpad content of legato projects' "$(scratchpad_build_kb)"
  printf '%12d KB  Total kept + prunable (%.1f GB)\n' "$((keep + extra))" "$(echo "($keep + $extra) / 1048576" | bc -l)"
  exit 0
fi

if [ "$delete" = 1 ]; then echo DELETING; else echo "DRY RUN (pass --delete to remove)"; fi
removed_kb=0

# reap <path> <reason>: remove one prunable item unless it is a symlink, locked, or recently used.
reap() {
  local d="$1" why="$2" kb locked=0
  if [ -L "$d" ]; then echo "KEEP symlink: $d"; return 0; fi
  [ -e "$d" ] || return 0
  if [ -e "$d.lock" ]; then echo "KEEP active: $d"; return 0; fi
  if [ -e "$d.guard" ]; then
    if ! try_lock_dir "$d" 2> /dev/null; then echo "KEEP active: $d"; return 0; fi
    locked=1
  fi
  if [ -d "$d" ] && recent_in_tree "$d" "$grace"; then
    [ "$locked" = 0 ] || unlock_dir "$d"
    echo "KEEP recently used: $d"; return 0
  fi
  kb="$(kb_of "$d")"
  if [ "$delete" = 1 ] && ! rm -rf "$d"; then
    [ "$locked" = 0 ] || unlock_dir "$d"
    echo "FAILED to remove: $d" >&2; return 1
  fi
  echo "$why: $kb KB $d"
  removed_kb=$((removed_kb + kb))
  [ "$locked" = 0 ] || unlock_dir "$d"
  return 0
}

status=0
# Old multi-entry cache roots: judge each child on its own, then drop the root once nothing is kept in it.
for root in build-derived e2e-derived device-derived; do
  d="$cache/$root"
  if [ -L "$d" ]; then echo "KEEP symlink: $d"; continue; fi
  [ -d "$d" ] || continue
  all_gone=1
  for c in "$d"/* "$d"/.[!.]*; do
    [ -e "$c" ] || [ -L "$c" ] || continue
    is_lock_file "$(basename "$c")" && continue
    reap "$c" 'obsolete' || status=1
    if [ "$delete" = 1 ]; then if [ -e "$c" ] || [ -L "$c" ]; then all_gone=0; fi; else all_gone=0; fi
  done
  if [ "$all_gone" = 1 ]; then rm -rf "$d"; fi
done
while IFS= read -r d; do
  [ -n "$d" ] || continue
  case "$(basename "$d")" in build-derived | e2e-derived | device-derived) [ "$(dirname "$d")" != "$cache" ] || continue ;; esac
  case "$d" in "$cache"/derived/*) why='not a current target' ;; *) why='obsolete' ;; esac
  reap "$d" "$why" || status=1
done < <(cache_extras | sort -u)
while IFS= read -r d; do if [ -n "$d" ]; then reap "$d" 'stale temp' || status=1; fi; done < <(tmp_legato_dirs)
while IFS= read -r d; do if [ -n "$d" ]; then reap "$d" 'Xcode IDE copy' || status=1; fi; done < <(xcode_legato_dirs)

# Dead-owner simulator work dirs: the same sweep ios-sim.sh runs at start.
if [ "$delete" = 1 ]; then sweep_stale_work_dirs "${TMPDIR:-/tmp}"; else sweep_stale_work_dirs "${TMPDIR:-/tmp}" 1; fi

printf '%s %.1f GB\n' "$([ "$delete" = 1 ] && echo Removed || echo 'Would remove')" "$(echo "$removed_kb / 1048576" | bc -l)"
exit "$status"
