#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .cache
swiftc -parse-as-library Sources/ANECleanupCore/Contracts.swift Tests/ANECleanupCoreTests/ContractsTests.swift -o .cache/contract-tests
.cache/contract-tests
