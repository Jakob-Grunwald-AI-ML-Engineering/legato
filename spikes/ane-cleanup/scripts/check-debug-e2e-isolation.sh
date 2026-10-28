#!/usr/bin/env bash
# Run: bash scripts/check-debug-e2e-isolation.sh
# Expected: PASS, exit 0. Hardcoded production Debug command routes must fail.
set -euo pipefail
cd "$(dirname "$0")/.."
source_file=../../Apps/iOS/App/Debug/E2E.swift
# Ignore documentation; inspect the URL guard and actual Darwin observer argument.
source_code=$(sed '/^[[:space:]]*\/\//d' "$source_file")
failed=0
if printf '%s\n' "$source_code" | rg -q 'url\.scheme[[:space:]]*==[[:space:]]*"legato"|"de\.gruenwald\.legato\.e2e\.'; then
  echo 'FAIL: Debug E2E command routes contain a literal production URL scheme or Darwin namespace.' >&2
  failed=1
fi
if ! printf '%s\n' "$source_code" | rg -q 'url\.scheme[[:space:]]*==[[:space:]]*RuntimeIdentity[[:space:]]*\.[[:space:]]*current[[:space:]]*\.[[:space:]]*urlScheme'; then
  echo 'FAIL: Debug E2E URL admission must use the current runtime URL scheme.' >&2
  failed=1
fi
if ! printf '%s\n' "$source_code" | rg -U -q 'CFNotificationCenterAddObserver\([\s\S]*"\\\(RuntimeIdentity[[:space:]]*\.[[:space:]]*current[[:space:]]*\.[[:space:]]*notificationNamespace\)\.e2e\.\\\(command\)"[[:space:]]+as[[:space:]]+CFString'; then
  echo 'FAIL: Debug E2E Darwin listeners must use the current runtime notification namespace.' >&2
  failed=1
fi
[ "$failed" = 0 ] || exit 1
echo 'PASS: Debug E2E URL admission and Darwin listeners use the current runtime identity; no literal production command routes.'
