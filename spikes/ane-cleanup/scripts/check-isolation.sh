#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
expected_group=group.de.gruenwald.legato.ane-spike
expected_namespace=de.gruenwald.legato.ane-spike
# Production defaults may exist in shared source; effective configuration and target membership must be isolated.
if rg -n 'SpikeHost.swift|SpikeApp.swift|SpikeLink.swift|SpikeIntent.swift|ToggleSpike' ANECleanupSpike.xcodeproj/project.pbxproj; then
  echo 'FAIL: bespoke fixture source in parity target.' >&2; exit 1
fi
for target in App Keyboard Widgets; do
  plist="Gen/$target-Info.plist"
  [ "$(/usr/libexec/PlistBuddy -c 'Print :LegatoAppGroupID' "$plist")" = "$expected_group" ]
  [ "$(/usr/libexec/PlistBuddy -c 'Print :LegatoURLScheme' "$plist")" = anecleanup39 ]
  [ "$(/usr/libexec/PlistBuddy -c 'Print :LegatoNotificationNamespace' "$plist")" = "$expected_namespace" ]
  [ "$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.application-groups:0' "Gen/$target.entitlements")" = "$expected_group" ]
done
[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleURLTypes:0:CFBundleURLSchemes:0' Gen/App-Info.plist)" = anecleanup39 ]
if [ -n "${1:-}" ]; then
  app=$1
  for entry in 'ANECleanupSpike.app' 'PlugIns/ANESpikeKeyboard.appex' 'PlugIns/ANESpikeWidgets.appex'; do
    case "$entry" in ANECleanupSpike.app) bundle="$app"; suffix='' ;; *Keyboard*) bundle="$app/$entry"; suffix='.keyboard' ;; *) bundle="$app/$entry"; suffix='.widgets' ;; esac
    plist="$bundle/Info.plist"
    [ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$plist")" = "$expected_namespace$suffix" ]
    [ "$(/usr/libexec/PlistBuddy -c 'Print :LegatoAppGroupID' "$plist")" = "$expected_group" ]
    [ "$(/usr/libexec/PlistBuddy -c 'Print :LegatoURLScheme' "$plist")" = anecleanup39 ]
    [ "$(/usr/libexec/PlistBuddy -c 'Print :LegatoNotificationNamespace' "$plist")" = "$expected_namespace" ]
    codesign --verify --strict "$bundle"
    codesign -d --entitlements :- "$bundle" > ".cache/verified${suffix:-.app}-entitlements.plist" 2>/dev/null
    [ "$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.application-groups:0' ".cache/verified${suffix:-.app}-entitlements.plist")" = "$expected_group" ]
  done
  echo 'PASS: signed app/keyboard/widget identifiers and entitlements are isolated.'
fi
echo 'PASS: production source membership and effective app/keyboard/widget identity are isolated.'
