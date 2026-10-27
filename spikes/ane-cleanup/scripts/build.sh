#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
configuration=${1:-Debug}
case "$configuration" in Debug|Release) ;; *) echo 'Usage: build.sh [Debug|Release] [device-udid]' >&2; exit 64;; esac
[ "$(xcodegen --version | awk '{print $NF}')" = 2.46.0 ] || { echo 'XcodeGen 2.46.0 required.' >&2; exit 1; }
[ -d .cache/Anemll-Anemll-f4ad26d ] || { echo 'Run scripts/setup.sh --prepare first.' >&2; exit 1; }
free_kib=$(df -Pk . | awk 'NR==2 {print $4}')
[ "$free_kib" -gt 3670016 ] || { echo 'Build refused: 3 GiB reserve plus 512 MiB incremental allowance required.' >&2; exit 1; }
project=ANECleanupSpike
spec=project.yml
derived=.cache/DerivedData
if [ "${LEGATO_SPIKE_FIXTURE:-0}" = 1 ]; then
  project=ANECleanupFixture
  spec=fixture-project.yml
  derived=.cache/FixtureDerivedData
fi
xcodegen generate --spec "$spec"
mkdir -p "$project.xcodeproj/project.xcworkspace/xcshareddata/swiftpm"
cp Package.resolved "$project.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
# Every referenced source/resource and both package manifests/locks participate, including production code.
source_hash=$( { rg --files ../../Apps/iOS ../../Sources App Shared Keyboard Widgets Parity Sources patches; printf '%s\n' project.yml fixture-project.yml Package.swift Package.resolved ../../Package.swift ../../Package.resolved scripts/build.sh scripts/check-isolation.sh; } | LC_ALL=C sort -u | while IFS= read -r file; do shasum -a 256 "$file"; done | shasum -a 256 | awk '{print $1}')
printf 'source_build_id=%s\ncomposition=%s\n' "$source_hash" "$project" > ".cache/build-$project-$configuration-provenance.txt"
shasum -a 256 patches/*.patch >> ".cache/build-$project-$configuration-provenance.txt"
args=(-project "$project.xcodeproj" -scheme ANECleanupSpike -configuration "$configuration"
  -skipPackageUpdates -onlyUsePackageVersionsFromResolvedFile
  -derivedDataPath "$derived"
  -clonedSourcePackagesDirPath "${LEGATO_SOURCE_PACKAGES:-$HOME/Library/Caches/legato/SourcePackages}")
if [ -n "${2:-}" ]; then
  args+=(-destination "id=$2" -allowProvisioningUpdates)
else
  args+=(-destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO)
fi
# Builds only; installation and physical tests are separate prepared checkpoints.
xcodebuild build "${args[@]}" "SPIKE_BUILD_ID=$source_hash" > ".cache/build-$project-$configuration.log" 2>&1 || {
  rg 'error:|BUILD FAILED' ".cache/build-$project-$configuration.log" >&2
  exit 1
}
tail -3 ".cache/build-$project-$configuration.log"
if [ "$project" = ANECleanupSpike ]; then
  if [ -n "${2:-}" ]; then
    scripts/check-isolation.sh "$derived/Build/Products/$configuration-iphoneos/ANECleanupSpike.app"
  else
    scripts/check-isolation.sh
  fi
fi
