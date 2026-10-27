#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
configuration=${1:-Debug}
case "$configuration" in Debug|Release) ;; *) echo 'Usage: build.sh [Debug|Release] [device-udid]' >&2; exit 64;; esac
[ "$(xcodegen --version | awk '{print $NF}')" = 2.46.0 ] || { echo 'XcodeGen 2.46.0 required.' >&2; exit 1; }
[ -d .cache/Anemll-Anemll-f4ad26d ] || { echo 'Run scripts/setup.sh --prepare first.' >&2; exit 1; }
free_kib=$(df -Pk . | awk 'NR==2 {print $4}')
[ "$free_kib" -gt 3670016 ] || { echo 'Build refused: 3 GiB reserve plus 512 MiB incremental allowance required.' >&2; exit 1; }
xcodegen generate
mkdir -p ANECleanupSpike.xcodeproj/project.xcworkspace/xcshareddata/swiftpm
if [ -f Package.resolved ]; then cp Package.resolved ANECleanupSpike.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved; fi
source_hash=$( { rg --files App Shared Keyboard Widgets Sources patches; printf '%s\n' project.yml Package.swift Package.resolved; } | LC_ALL=C sort | while IFS= read -r file; do shasum -a 256 "$file"; done | shasum -a 256 | awk '{print $1}')
printf 'source_build_id=%s\n' "$source_hash" > ".cache/build-$configuration-provenance.txt"
shasum -a 256 patches/*.patch >> ".cache/build-$configuration-provenance.txt"
args=(-project ANECleanupSpike.xcodeproj -scheme ANECleanupSpike -configuration "$configuration"
  -skipPackageUpdates -onlyUsePackageVersionsFromResolvedFile
  -derivedDataPath .cache/DerivedData
  -clonedSourcePackagesDirPath "${LEGATO_SOURCE_PACKAGES:-$HOME/Library/Caches/legato/SourcePackages}")
if [ -n "${2:-}" ]; then
  args+=(-destination "id=$2" -allowProvisioningUpdates)
else
  args+=(-destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO)
fi
# Timing runs use a signed Release app launched without a debugger; this command only builds.
xcodebuild build "${args[@]}" "SPIKE_BUILD_ID=$source_hash" > ".cache/build-$configuration.log" 2>&1 || {
  rg 'error:|BUILD FAILED' ".cache/build-$configuration.log" >&2
  exit 1
}
tail -3 ".cache/build-$configuration.log"
