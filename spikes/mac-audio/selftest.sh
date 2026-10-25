#!/bin/bash
# Headless check: capture N seconds (default 15) from mic + system audio, write selftest.json, exit.
# Launched through `open` so LegatoSpike.app is its own TCC "responsible process" (running the binary from a
# terminal would attribute the permission to the terminal instead). Play speech while it runs, e.g.
#   (for i in $(seq 8); do say -v Anna "Das ist ein Test des Systemaudios"; done) &
# Usage: ./selftest.sh [seconds] [lang: auto|de-DE|en-US]
set -euo pipefail
cd "$(dirname "$0")"
APP="$(pwd)/build/Build/Products/Debug/LegatoSpike.app"
rm -f selftest.json selftest.log
open -W -n --stdout "$(pwd)/selftest.log" --stderr "$(pwd)/selftest.log" "$APP" \
  --args --selftest --out="$(pwd)/selftest.json" --seconds="${1:-15}" --lang="${2:-auto}"
cat selftest.json
