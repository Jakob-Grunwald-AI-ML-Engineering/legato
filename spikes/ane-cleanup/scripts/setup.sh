#!/usr/bin/env bash
# Sources only: never downloads model weights or deletes an existing cache.
set -euo pipefail
cd "$(dirname "$0")/.."
revision=f4ad26d061dc2e426faa19f81c367343bdeb9f0d
checkout=.cache/Anemll-Anemll-f4ad26d
archive_sha=155c3cb7fcbbae062f32e9e19d97a3c6209e78534ae7332836921e8270161759
reserve_kib=3145728
build_estimate_kib=2097152
[ ! -d .cache/DerivedData/Build ] || build_estimate_kib=524288
free_kib=$(df -Pk . | awk 'NR==2 {print $4}')
printf 'ANEMLL %s; swift-transformers exact 1.3.5\n' "$revision"
printf 'Available: %s KiB; source+build allowance: %s KiB; reserve: %s KiB\n' "$free_kib" "$build_estimate_kib" "$reserve_kib"
printf 'Shared packages: %s\n' "${LEGATO_SOURCE_PACKAGES:-$HOME/Library/Caches/legato/SourcePackages}"
printf 'No weights. Conversion/device storage need separate preflight.\n'
shasum -a 256 patches/*.patch
if [ "${1:---dry-run}" = --dry-run ]; then exit 0; fi
[ "${1:-}" = --prepare ] || { echo 'Usage: setup.sh [--dry-run|--prepare]' >&2; exit 64; }
[ "$free_kib" -gt $((reserve_kib + build_estimate_kib)) ] || { echo 'Insufficient disk for build allowance plus reserve.' >&2; exit 1; }
mkdir -p .cache
if [ ! -f .cache/anemll.tar.gz ]; then
  curl --fail --location --silent --show-error "https://api.github.com/repos/Anemll/Anemll/tarball/$revision" -o .cache/anemll.tar.gz
fi
printf '%s  %s\n' "$archive_sha" .cache/anemll.tar.gz | shasum -a 256 -c -
if [ ! -d "$checkout" ]; then tar -xzf .cache/anemll.tar.gz -C .cache; fi
for patch_file in patches/*.patch; do
  if patch --forward --batch --dry-run --silent -d "$checkout" -p1 < "$patch_file"; then
    patch --forward --batch -d "$checkout" -p1 < "$patch_file"
  elif patch --batch --dry-run --silent --reverse -d "$checkout" -p1 < "$patch_file"; then
    printf 'Already applied: %s\n' "$patch_file"
  else
    printf 'Unexpected upstream source state for %s; refusing overwrite.\n' "$patch_file" >&2
    exit 1
  fi
done
{
  printf 'upstream_revision=%s\narchive_sha256=%s\n' "$revision" "$archive_sha"
  shasum -a 256 patches/*.patch
  xcodebuild -version
  swift --version
  xcodegen --version
} > .cache/build-provenance.txt
