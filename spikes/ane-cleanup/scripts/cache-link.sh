#!/usr/bin/env bash
# Point this checkout's .cache and models at the shared spike cache, so worktrees reuse one download.
# Shared root: ${LEGATO_CACHE_DIR:-~/Library/Caches/legato}/spikes/ane-cleanup/{cache,models}.
# Idempotent. A real .cache/ or models/ here is migrated into the shared dir (entries already there are never
# overwritten; a name clash aborts and leaves the local dir as is). Run from the spike dir, or source and call.
set -uo pipefail

link_shared_cache() {
  local spike root name shared entry
  spike="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  root="${LEGATO_CACHE_DIR:-${XDG_CACHE_HOME:-$HOME/Library/Caches}/legato}/spikes/ane-cleanup"
  for pair in .cache:cache models:models; do
    name="${pair%%:*}"; shared="$root/${pair##*:}"
    mkdir -p "$shared" || return 1
    if [ -L "$spike/$name" ]; then
      [ "$(readlink "$spike/$name")" = "$shared" ] || ln -sfn "$shared" "$spike/$name" || return 1
    elif [ -d "$spike/$name" ]; then
      for entry in "$spike/$name"/* "$spike/$name"/.[!.]*; do   # migrate, never clobber
        [ -e "$entry" ] || [ -L "$entry" ] || continue
        if [ -e "$shared/$(basename "$entry")" ] || [ -L "$shared/$(basename "$entry")" ]; then
          echo "Shared cache already has $(basename "$entry"); keeping $spike/$name as a real dir." >&2
          return 1
        fi
      done
      for entry in "$spike/$name"/* "$spike/$name"/.[!.]*; do
        [ -e "$entry" ] || [ -L "$entry" ] || continue
        mv "$entry" "$shared/" || return 1
      done
      rmdir "$spike/$name" && ln -s "$shared" "$spike/$name" || return 1
      echo "Migrated $spike/$name into $shared"
    elif [ -e "$spike/$name" ]; then
      echo "$spike/$name exists and is not a directory." >&2; return 1
    else
      ln -s "$shared" "$spike/$name" || return 1
    fi
  done
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then link_shared_cache; fi
