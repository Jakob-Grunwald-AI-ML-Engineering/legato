#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .cache
swiftc -swift-version 6 -parse-as-library Sources/ANECleanupCore/RecordingStartPolicy.swift Tests/ANECleanupCoreTests/RecordingStartPolicyTests.swift -o .cache/recording-start-policy-tests
.cache/recording-start-policy-tests
