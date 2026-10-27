#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
: "${1:?Usage: device-run.sh device-udid install|launch|profile}"
case "${2:-}" in
  install) xcrun devicectl device install app --device "$1" .cache/DerivedData/Build/Products/Release-iphoneos/ANECleanupSpike.app ;;
  launch) xcrun devicectl device process launch --device "$1" de.gruenwald.legato.ane-spike ;;
  profile)
    mkdir -p private-results
    xcrun xctrace record --device "$1" --instrument 'Core ML' --instrument 'Neural Engine' --instrument 'Points of Interest' --attach ANECleanupSpike --time-limit 60s --output "private-results/ane-$(date -u +%Y%m%dT%H%M%SZ).trace"
    ;;
  *) echo 'Usage: device-run.sh device-udid install|launch|profile' >&2; exit 64 ;;
esac
