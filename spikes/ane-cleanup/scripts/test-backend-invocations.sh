#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .cache
swiftc -swift-version 6 -parse-as-library Sources/ANECleanupCore/Contracts.swift Sources/ANECleanupCore/BackendInvocationLedger.swift Tests/ANECleanupCoreTests/BackendInvocationLedgerTests.swift -o .cache/backend-invocation-tests
.cache/backend-invocation-tests
