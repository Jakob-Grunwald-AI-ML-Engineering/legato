#!/bin/bash
# Probes for docs/research/scheduler-load-61.md. Usage: run.sh [load]
# "load" starts ten owned `yes` workers and stops exactly those PIDs afterwards.
set -u
src="$(cd "$(dirname "$0")" && pwd)"
bin="$(mktemp -d)"
for p in io tk dq; do swiftc -O "$src/$p.swift" -o "$bin/$p" || exit 1; done
PIDS=()
if [ "${1:-}" = load ]; then for i in $(seq 10); do yes > /dev/null & PIDS+=($!); done; fi
echo "mode=${1:-unloaded} workers=${PIDS[*]:-}"
for p in ui util bg; do timeout 60 "$bin/io" $p 4 100; done
for m in bg-await bg-cont; do timeout 60 "$bin/tk" $m; done
for q in ui bg; do timeout 60 "$bin/dq" $q; done
for m in "-b" "-d throttle"; do timeout 60 taskpolicy $m "$bin/io" ui 4 100 | sed "s/^/taskpolicy $m /"; done
for p in "${PIDS[@]:-}"; do [ -n "$p" ] && kill "$p" && wait "$p" 2>/dev/null; done
for p in "${PIDS[@]:-}"; do [ -n "$p" ] && kill -0 "$p" 2>/dev/null && echo "ALIVE $p"; done
rm -rf "$bin"
