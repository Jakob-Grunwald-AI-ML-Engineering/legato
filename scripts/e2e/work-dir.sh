#!/usr/bin/env bash
# Sourced by ios-sim.sh and scripts/dev/prune-build-caches.sh: owner-tagged work dirs, the stale sweep,
# the shared build-cache locations and a small mkdir lock.

# Directories that hold build output (see ios-sim.sh). Override with LEGATO_CACHE_DIR.
legato_cache_dir() { echo "${LEGATO_CACHE_DIR:-${XDG_CACHE_HOME:-$HOME/Library/Caches}/legato}"; }

# "<pid> <start time>" of a process; the start time guards against PID reuse.
proc_stamp() { echo "$1 $(ps -o lstart= -p "$1" 2> /dev/null | sed 's/^ *//')"; }

# 0 if the process recorded in an owner file is still the same live process.
owner_alive() { # owner_alive <owner file>
  local pid
  [ -f "$1" ] || return 1
  pid="$(awk '{print $1}' "$1")"
  [ -n "$pid" ] && kill -0 "$pid" 2> /dev/null && [ "$(proc_stamp "$pid")" = "$(cat "$1")" ]
}

# Tag a fresh work dir with its owner (this shell).
tag_work_dir() { proc_stamp "$$" > "$1/owner"; }

# Remove legato-e2e.* dirs under <tmp> whose run is dead (killed with SIGKILL, so no trap ran). Never touches
# a dir whose owner is alive, nor a dir kept with LEGATO_E2E_KEEP=1 (marked `keep`) until it is older than
# LEGATO_E2E_KEEP_DAYS (default 7). Dirs without an owner file are older than this tagging: swept after 1 day.
# With dry=1 only prints "<size> <dir>".
sweep_stale_work_dirs() { # sweep_stale_work_dirs <tmp> [dry]
  local tmp="${1:-${TMPDIR:-/tmp}}" dry="${2:-0}" d
  for d in "$tmp"/legato-e2e.*; do
    [ -d "$d" ] || continue
    owner_alive "$d/owner" && continue
    if [ -f "$d/keep" ]; then
      [ -n "$(find "$d/keep" -mtime "+${LEGATO_E2E_KEEP_DAYS:-7}" 2> /dev/null)" ] || continue
    elif [ ! -f "$d/owner" ]; then
      [ -n "$(find "$d" -maxdepth 0 -mtime +1 2> /dev/null)" ] || continue
    fi
    if [ "$dry" = 1 ]; then du -sk "$d" | awk '{printf "%.0f MB  %s\n", $1/1024, $2}'; else rm -rf "$d"; fi
  done
}

# Exclusive lock on a directory path (macOS has no flock(1)): mkdir is atomic. A lock whose owner died is
# taken over. Wait up to LEGATO_LOCK_WAIT seconds (default 3600), then fail.
lock_dir() { # lock_dir <path>
  local lock="$1.lock" waited=0
  until mkdir "$lock" 2> /dev/null; do
    if ! owner_alive "$lock/owner"; then
      # Owner gone (or lock mid-creation for under 2 s): take over only if the owner file is old/missing.
      if [ -f "$lock/owner" ] || [ -n "$(find "$lock" -maxdepth 0 -mmin +0.05 2> /dev/null)" ]; then
        mv "$lock" "$lock.stale.$$" 2> /dev/null; rm -rf "$lock.stale.$$"; continue
      fi
    fi
    sleep 2; waited=$((waited + 2))
    [ "$waited" -lt "${LEGATO_LOCK_WAIT:-3600}" ] || { echo "Timed out waiting for lock $lock" >&2; return 1; }
  done
  proc_stamp "$$" > "$lock/owner"
}
unlock_dir() { rm -rf "$1.lock"; }
