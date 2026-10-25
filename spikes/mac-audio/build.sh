#!/bin/bash
# Generate the Xcode project and build. Usage: ./build.sh [adhoc]
#   default : automatic signing with team XWSGN23W75 (needs a Mac Development cert + accepted PLA)
#   adhoc   : ad-hoc signed ("-"), for machines without a usable signing identity
set -euo pipefail
cd "$(dirname "$0")"
xcodegen generate --spec project.yml
EXTRA=(-allowProvisioningUpdates)
if [[ "${1:-}" == "adhoc" ]]; then
  EXTRA=(CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM=)
fi
xcodebuild -project LegatoSpike.xcodeproj -scheme LegatoSpike -configuration Debug \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath build "${EXTRA[@]}" build
echo "app: $(pwd)/build/Build/Products/Debug/LegatoSpike.app"
