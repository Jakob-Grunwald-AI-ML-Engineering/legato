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

# Mark only directories created/used by participating build scripts. Custom paths are never adopted.
mark_build_cache() {
  printf 'v1\n' > "$1/legato-managed"
  touch "$1/legato-last-used"
}

# Shared local gate/release paths. CI remains cold under RUNNER_TEMP.
prepare_build_cache() { # <gate|mac>
  if [ -n "${CI:-}" ]; then
    BUILD_WORK="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/legato-$1.XXXXXX")"
    BUILD_PACKAGES="$BUILD_WORK/packages"
    return
  fi
  local cache
  cache="$(legato_cache_dir)"
  bash scripts/dev/prune-build-caches.sh --managed-only --delete
  BUILD_WORK="$cache/build-derived/$1-$(pwd -P | shasum | cut -c1-12)"
  BUILD_PACKAGES="$cache/SourcePackages"
  mkdir -p "$(dirname "$BUILD_WORK")" "$cache"
  lock_dir "$BUILD_WORK"
  BUILD_CACHE_LOCKED=1
  mkdir -p "$BUILD_WORK"
  mark_build_cache "$BUILD_WORK"
  lock_dir "$BUILD_PACKAGES"
  BUILD_PACKAGES_LOCKED=1
  mkdir -p "$BUILD_PACKAGES"
  mark_build_cache "$BUILD_PACKAGES"
}
finish_build_cache() {
  if [ -n "${BUILD_PACKAGES_LOCKED:-}" ]; then
    touch "$BUILD_PACKAGES/legato-last-used"
    unlock_dir "$BUILD_PACKAGES"
  fi
  if [ -n "${BUILD_CACHE_LOCKED:-}" ]; then
    touch "$BUILD_WORK/legato-last-used"
    unlock_dir "$BUILD_WORK"
    bash scripts/dev/prune-build-caches.sh --managed-only --delete
  elif [ -n "${CI:-}" ] && [ -n "${BUILD_WORK:-}" ]; then
    rm -rf "$BUILD_WORK"
  fi
}

# Keep the build lease until the captured child process group has stopped and been reaped.
stop_build_command() {
  local i
  [ -n "${BUILD_CHILD_PID:-}" ] || return 0
  trap '' INT TERM
  kill -TERM -- "-$BUILD_CHILD_PID" 2>/dev/null || true
  for ((i=0; i<50; i++)); do
    kill -0 "$BUILD_CHILD_PID" 2>/dev/null || break
    sleep 0.1
  done
  kill -KILL -- "-$BUILD_CHILD_PID" 2>/dev/null || true
  wait "$BUILD_CHILD_PID" 2>/dev/null || true
  BUILD_CHILD_PID=""
}
run_build_command() {
  local status=0
  trap 'stop_build_command; exit 130' INT
  trap 'stop_build_command; exit 143' TERM
  set -m
  "$@" &
  BUILD_CHILD_PID=$!
  set +m
  wait "$BUILD_CHILD_PID" || status=$?
  BUILD_CHILD_PID=""
  return "$status"
}
