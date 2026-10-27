#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
if rg -n 'group\.de\.gruenwald\.legato["\]]|legato://|de\.gruenwald\.legato\.link\.' project.yml App Keyboard Shared Widgets Sources; then
  echo 'FAIL: production identifier in spike runtime source.' >&2; exit 1
fi
for target in App Keyboard Widgets; do
  [ -f "Gen/$target.entitlements" ] || continue
  group=$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.application-groups:0' "Gen/$target.entitlements")
  [ "$group" = group.de.gruenwald.legato.ane-spike ] || { echo "FAIL: $target app group" >&2; exit 1; }
done
echo 'PASS: spike runtime identifiers and generated App Group entitlements are isolated.'
