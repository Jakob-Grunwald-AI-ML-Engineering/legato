#!/usr/bin/env bash
# Exercise the real file/strings boundary using small native Mach-O objects.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
scanner="${1:-$root/scripts/ci/check-internal-exclusion.sh}"
work="$(mktemp -d "${TMPDIR:-/tmp}/legato-release-scan.XXXXXX")"
# Keep fixtures on failure for diagnosis; no build caches or app bundles are touched.
echo "Fixtures: $work"
mkdir -p "$work/sources/Apps/iOS/App/Debug" "$work/sources/Apps/iOS/App/Internal" \
  "$work/sources/Apps/macOS/App/Debug" "$work/sources/Apps/macOS/App/Internal"
for platform in iOS macOS; do
  printf '%s\n' 'enum DebugBridge' 'session-probe' 'debug-bridge' 'LEGATO_MAC_ROOT' > "$work/sources/Apps/$platform/App/Debug/DebugBridge.swift"
  printf '%s\n' 'struct DebugOverlayView' > "$work/sources/Apps/$platform/App/Debug/DebugOverlay.swift"
  printf '%s\n' 'enum SessionProbe' 'Session probe:' > "$work/sources/Apps/$platform/App/Internal/SessionProbe.swift"
done
make_object() {
  local destination="$1" literal="$2"
  mkdir -p "$(dirname "$destination")"
  printf 'const char *fixture = "%s";\n' "$literal" > "$work/input.c"
  cc -c "$work/input.c" -o "$destination"
}
expect_failure() {
  local name="$1" diagnostic="$2" bundle="$3" sources="${4:-$work/sources}"
  if "$BASH" "$scanner" ios "$bundle" "$sources" > "$work/output" 2>&1; then
    echo "FAIL $name: scanner accepted fixture"; exit 1
  fi
  if ! grep -Fq "$diagnostic" "$work/output"; then
    cat "$work/output"; echo "FAIL $name: missing diagnostic '$diagnostic'"; exit 1
  fi
  echo "PASS $name"
}
make_object "$work/clean app/Legato" 'ordinary application LLMSession SessionProbeCoordinator'
if ! "$BASH" "$scanner" ios "$work/clean app" "$work/sources" > "$work/output" 2>&1; then
  cat "$work/output"; echo 'FAIL clean bundle'; exit 1
fi
echo 'PASS clean Mach-O bundle'
# A leaked endpoint in an embedded executable must fail even when the main executable is clean.
make_object "$work/clean app/PlugIns/Widget.appex/Widget" 'session-probe'
expect_failure 'embedded endpoint leak' 'Release contains: session-probe' "$work/clean app"
make_object "$work/clean app/PlugIns/Widget.appex/Widget" 'ordinary widget'
for needle in DebugBridge DebugOverlayView 12SessionProbeO 'Session probe:'; do
  make_object "$work/leaked/Legato" "$needle"
  expect_failure "internal entry point $needle" "Release contains: $needle" "$work/leaked"
done
printf '%s\n' 'session-probe' 'debug-bridge' > "$work/sources/Apps/iOS/App/Debug/DebugBridge.swift"
expect_failure 'stale source control' 'stale source control: DebugBridge' "$work/clean app"
mkdir -p "$work/empty"
expect_failure 'empty bundle' 'no Mach-O files' "$work/empty"
printf '%s\n' 'session-probe' > "$work/empty/resource.txt"
expect_failure 'resource-only bundle' 'no Mach-O files' "$work/empty"
if ! "$BASH" "$scanner" mac "$work/clean app" "$work/sources" > "$work/output" 2>&1; then
  cat "$work/output"; echo 'FAIL clean Mac bundle'; exit 1
fi
echo 'PASS clean Mac bundle'
make_object "$work/mac-leak/Legato" 'LEGATO_MAC_ROOT'
if "$BASH" "$scanner" mac "$work/mac-leak" "$work/sources" > "$work/output" 2>&1; then
  echo 'FAIL Mac endpoint leak'; exit 1
fi
grep -Fq 'Release contains: LEGATO_MAC_ROOT' "$work/output"
echo 'PASS Mac endpoint leak'
