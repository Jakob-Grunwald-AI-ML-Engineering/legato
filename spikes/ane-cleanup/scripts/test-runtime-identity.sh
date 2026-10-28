#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
root=.cache/runtime-identity-contract
mkdir -p "$root/Production.app/Contents/MacOS" "$root/Spike.app/Contents/MacOS"
swiftc -parse-as-library ../../Sources/LegatoKeyboardCore/Link/RuntimeIdentity.swift \
  ../../Sources/LegatoKeyboardCore/Link/LinkChannel.swift \
  Tests/ANECleanupCoreTests/RuntimeIdentityContractTests.swift \
  -o "$root/Production.app/Contents/MacOS/RuntimeIdentityContract"
cp "$root/Production.app/Contents/MacOS/RuntimeIdentityContract" "$root/Spike.app/Contents/MacOS/RuntimeIdentityContract"
for variant in Production Spike; do
  plist="$root/$variant.app/Contents/Info.plist"
  cat > "$plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>RuntimeIdentityContract</string>
<key>CFBundleIdentifier</key><string>de.gruenwald.legato.identity-contract</string>
<key>CFBundlePackageType</key><string>APPL</string>
</dict></plist>
PLIST
  expected=de.gruenwald.legato
  if [ "$variant" = Spike ]; then
    /usr/libexec/PlistBuddy -c 'Add :LegatoAppGroupID string group.de.gruenwald.legato.ane-spike' "$plist"
    /usr/libexec/PlistBuddy -c 'Add :LegatoURLScheme string anecleanup39' "$plist"
    /usr/libexec/PlistBuddy -c 'Add :LegatoNotificationNamespace string de.gruenwald.legato.ane-spike' "$plist"
    expected=de.gruenwald.legato.ane-spike
  fi
  "$root/$variant.app/Contents/MacOS/RuntimeIdentityContract" "$expected"
done
