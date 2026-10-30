#!/usr/bin/env bash
# Usage: check-internal-exclusion.sh ios|mac APP_BUNDLE [SOURCE_ROOT]
# Scan every Mach-O, including extensions/frameworks, and fail closed on empty bundles or stale controls.
# Shared LLMSession and SessionProbeCoordinator APIs are intentionally allowed; app adapters are internal.
set -euo pipefail
platform="${1:?usage: check-internal-exclusion.sh ios|mac APP_BUNDLE [SOURCE_ROOT]}"
bundle="${2:?provide an ordinary Release app bundle}"
source_root="${3:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
case "$platform" in
  ios) app_sources="$source_root/Apps/iOS/App" ;;
  mac) app_sources="$source_root/Apps/macOS/App" ;;
  *) echo "FAIL unknown platform: $platform"; exit 2 ;;
esac
[ -d "$bundle" ] || { echo "FAIL missing app bundle: $bundle"; exit 1; }
needles=(DebugBridge DebugOverlayView session-probe debug-bridge 12SessionProbeO 'Session probe:')
controls=(DebugBridge DebugOverlayView session-probe debug-bridge 'enum SessionProbe' 'Session probe:')
files=(Debug/DebugBridge.swift Debug/DebugOverlay.swift Debug/DebugBridge.swift Debug/DebugBridge.swift Internal/SessionProbe.swift Internal/SessionProbe.swift)
if [ "$platform" = mac ]; then
  needles+=(LEGATO_MAC_ROOT)
  controls+=(LEGATO_MAC_ROOT)
  files+=(Debug/DebugBridge.swift)
fi
fail=0
for ((i=0; i<${#needles[@]}; i++)); do
  if ! grep -Fq -- "${controls[$i]}" "$app_sources/${files[$i]}"; then
    echo "FAIL stale source control: ${needles[$i]} (${files[$i]})"
    fail=1
  fi
done
scan_strings="$(mktemp "${TMPDIR:-/tmp}/legato-internal-exclusion.XXXXXX")"
scan_files="$(mktemp "${TMPDIR:-/tmp}/legato-internal-files.XXXXXX")"
trap 'rm -f "$scan_strings" "$scan_files"' EXIT
find "$bundle" -type f -print0 > "$scan_files" || { echo "FAIL unable to enumerate app bundle: $bundle"; exit 1; }
count=0
while IFS= read -r -d '' candidate; do
  kind="$(file -b -- "$candidate")"
  if [[ "$kind" == *Mach-O* ]]; then
    strings -a "$candidate" >> "$scan_strings"
    count=$((count + 1))
  fi
done < "$scan_files"
if [ "$count" -eq 0 ]; then
  echo "FAIL no Mach-O files in $bundle"
  fail=1
elif [ ! -s "$scan_strings" ]; then
  echo "FAIL no Mach-O strings in $bundle ($count files)"
  fail=1
fi
for needle in "${needles[@]}"; do
  if grep -Fq -- "$needle" "$scan_strings"; then
    echo "FAIL Release contains: $needle"
    fail=1
  fi
done
if [ "$fail" -eq 0 ]; then
  echo "PASS $platform Release: $count Mach-O files exclude internal endpoints, overlays and probe adapters; source controls valid"
fi
exit "$fail"
