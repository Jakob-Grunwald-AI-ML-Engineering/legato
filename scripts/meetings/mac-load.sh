#!/bin/bash
# Samples Legato's CPU once a second for N seconds and prints the average and the peak (percent of one core,
# of one core: 100 is one full core). Run it during a meeting: the target is an average below 60.
#
# Read-only: it finds the app's process and reads its CPU; it never signals or quits anything.
# The process is found by bundle path (~/Applications/Legato.app, or LEGATO_APP=/path/Legato.app), else by
# the bundle id's executable (`Legato`) running from a Legato.app. LEGATO_PID=<pid> names it directly.
#
# Usage: scripts/meetings/mac-load.sh <seconds>
set -euo pipefail
seconds="${1:?usage: mac-load.sh <seconds>}"
case "$seconds" in '' | *[!0-9]*) echo "seconds must be a whole number" >&2; exit 64 ;; esac
app="${LEGATO_APP:-$HOME/Applications/Legato.app}"

find_pid() {
  if [ -n "${LEGATO_PID:-}" ]; then echo "$LEGATO_PID"; return; fi
  # The newest process whose executable lives in the bundle.
  ps -axo pid=,command= | awk -v exe="$app/Contents/MacOS/Legato" 'index($0, exe) { print $1 }' | tail -1
}

pid="$(find_pid)"
if [ -z "$pid" ] || ! kill -0 "$pid" 2>/dev/null; then
  echo "Legato is not running ($app). Start the app and a meeting, then run this again." >&2
  exit 1
fi

# CPU seconds the process has used so far ("m:ss.cc" from ps), and the wall clock; a sample is the change
# over the last second, so it is what the process used then (`ps %cpu` is a decayed average, not that).
cpu_seconds() { ps -o cputime= -p "$1" 2>/dev/null | tr -d ' ' | awk -F: 'NF { s = 0; for (i = 1; i <= NF; i++) s = s * 60 + $i; print s }'; }
now() { perl -MTime::HiRes=time -e 'printf "%.3f\n", time'; }

echo "Sampling Legato (pid $pid) for $seconds s…"
samples=()
prev_cpu="$(cpu_seconds "$pid")"
prev_t="$(now)"
for ((i = 0; i < seconds; i++)); do
  sleep 1
  cpu="$(cpu_seconds "$pid")"
  t="$(now)"
  if [ -z "$cpu" ]; then echo "Legato (pid $pid) exited after $i s." >&2; break; fi
  samples+=("$(awk -v c="$cpu" -v pc="$prev_cpu" -v t="$t" -v pt="$prev_t" 'BEGIN { printf "%.1f", (c - pc) / (t - pt) * 100 }')")
  prev_cpu="$cpu"
  prev_t="$t"
done

if [ "${#samples[@]}" -eq 0 ]; then exit 1; fi
printf '%s\n' "${samples[@]}" | awk '
  { sum += $1; if ($1 > peak) peak = $1; n++ }
  END { printf "samples: %d\naverage CPU: %.1f %%\npeak CPU:    %.1f %%\n", n, sum / n, peak }'
