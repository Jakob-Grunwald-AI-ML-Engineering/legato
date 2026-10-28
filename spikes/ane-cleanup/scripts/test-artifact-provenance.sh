#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .cache
swiftc -parse-as-library Sources/ANECleanupCore/ArtifactProvenance.swift Tests/ANECleanupCoreTests/ArtifactProvenanceTests.swift -o .cache/artifact-provenance-tests-runner
lut6_hash=$(/usr/bin/shasum -a 256 conversion/results/qwen3-06b-lut6-artifact-manifest.json | awk '{print $1}')
fp16_hash=$(/usr/bin/shasum -a 256 conversion/results/qwen3-06b-fp16-artifact-manifest.json | awk '{print $1}')
.cache/artifact-provenance-tests-runner "$lut6_hash" "$fp16_hash"
