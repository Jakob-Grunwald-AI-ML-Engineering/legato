#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
: "${1:?Usage: pull-results.sh device-udid}"
destination="private-results/$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$destination"
xcrun devicectl device copy from --device "$1" --domain-type appDataContainer --domain-identifier de.gruenwald.legato.ane-spike --source Documents/Results --destination "$destination/Results"
printf 'Private artifacts: %s\n' "$destination"
