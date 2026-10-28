#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .cache
clang -fobjc-arc -c Tests/ANECleanupCoreTests/PermissionCallbackShim.m -o .cache/permission-shim.o
if [ "${1:-}" = --reproduce-unsafe ]; then
  # Expected SIGTRAP/exit 133 on Swift 6: exact old setup pattern through an Objective-C callback.
  swiftc -swift-version 6 -parse-as-library -import-objc-header Tests/ANECleanupCoreTests/PermissionCallbackShim.h Tests/ANECleanupCoreTests/PermissionCallbackRepro.swift .cache/permission-shim.o -o .cache/permission-native-repro
  .cache/permission-native-repro
else
  swiftc -swift-version 6 -parse-as-library -import-objc-header Tests/ANECleanupCoreTests/PermissionCallbackShim.h Sources/ANECleanupCore/PermissionBridge.swift Tests/ANECleanupCoreTests/PermissionCallbackTests.swift .cache/permission-shim.o -o .cache/permission-callback-tests
  .cache/permission-callback-tests
fi
