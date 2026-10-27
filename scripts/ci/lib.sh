#!/usr/bin/env bash
# Sourced by the CI scripts.

cd "$(git rev-parse --show-toplevel)" || exit 1

# 0 if the repo root holds a Swift package or Xcode project definition.
has_swift_targets() {
  [ -e Package.swift ] || [ -e project.yml ] || compgen -G "*.xcodeproj" > /dev/null
}

# 0 if the repo holds an app definition (XcodeGen spec or Xcode project).
has_app_targets() {
  [ -e project.yml ] || compgen -G "*.xcodeproj" > /dev/null
}

# 0 if the repo holds the iOS app's XcodeGen spec.
has_ios_app() {
  [ -e Apps/iOS/project.yml ]
}

# 0 if the repo holds the macOS app's XcodeGen spec.
has_mac_app() {
  [ -e Apps/macOS/project.yml ]
}

# SHA256 of the XcodeGen release zip for the version pinned in .xcodegen-version.
# Bump both together: curl -fsSL -o x.zip \
#   https://github.com/yonaskolb/XcodeGen/releases/download/<version>/xcodegen.zip && shasum -a 256 x.zip
XCODEGEN_ZIP_SHA256="4d9e34b62172d645eed6457cac13fc222569974098ef4ee9c3368bedf0196806"

# Set XCODEGEN to an executable of the pinned XcodeGen version. Uses the installed one when its
# version matches; otherwise downloads the release zip, verifies its SHA256 and runs it from the
# extracted tree (the binary needs the sibling share/ directory, so it is never copied out alone).
ensure_xcodegen() {
  local version dir zip tmp
  version="$(tr -d '[:space:]' < .xcodegen-version)"
  if command -v xcodegen > /dev/null 2>&1 \
    && [ "$(xcodegen --version 2> /dev/null | awk '{print $NF}')" = "$version" ]; then
    XCODEGEN="$(command -v xcodegen)"
    return 0
  fi

  dir="${XDG_CACHE_HOME:-${RUNNER_TEMP:-${TMPDIR:-/tmp}}}/legato-xcodegen-$version"
  if [ ! -x "$dir/xcodegen/bin/xcodegen" ]; then
    echo "::notice::Installed xcodegen is not $version; downloading the pinned release."
    tmp="$(mktemp -d)"
    zip="$tmp/xcodegen.zip"
    curl -fsSL --retry 3 -o "$zip" \
      "https://github.com/yonaskolb/XcodeGen/releases/download/$version/xcodegen.zip" || return 1
    if [ "$(shasum -a 256 "$zip" | awk '{print $1}')" != "$XCODEGEN_ZIP_SHA256" ]; then
      echo "::error::XcodeGen $version zip does not match the pinned SHA256."
      rm -rf "$tmp"
      return 1
    fi
    unzip -q "$zip" -d "$tmp/extracted" || return 1
    rm -rf "$dir"
    mkdir -p "$(dirname "$dir")"
    mv "$tmp/extracted" "$dir"
    rm -rf "$tmp"
  fi
  XCODEGEN="$dir/xcodegen/bin/xcodegen"
}

# Pin Xcode from .xcode-version. Missing on CI is an error; locally the default is used.
select_xcode() {
  local version app
  version="$(tr -d '[:space:]' < .xcode-version)"
  app="/Applications/Xcode_${version}.app"
  if [ -d "$app" ]; then
    export DEVELOPER_DIR="$app/Contents/Developer"
  elif [ -n "${CI:-}" ]; then
    echo "::error::Pinned Xcode $version not found at $app."
    return 1
  else
    echo "::notice::Pinned Xcode $version not installed; using local default ($(xcodebuild -version | head -n 1))."
  fi
  ensure_metal_toolchain
}

# MLX compiles Metal shaders; since Xcode 26 the Metal toolchain is a separate download. Idempotent: an
# installed toolchain is left alone. Only CI downloads it (about a gigabyte); locally it prints how.
ensure_metal_toolchain() {
  [ "${LEGATO_STUB_DEPS:-}" != 1 ] || return 0   # the stubs compile no Metal
  if xcodebuild -showComponent MetalToolchain 2>/dev/null | grep -q "Status: installed"; then
    return 0
  fi
  if [ -z "${CI:-}" ]; then
    echo "::notice::Metal toolchain not installed; MLX will not build. Install it with: xcodebuild -downloadComponent MetalToolchain"
    return 0
  fi
  local started=$SECONDS
  echo "::notice::Metal toolchain not installed; downloading it."
  xcodebuild -downloadComponent MetalToolchain
  echo "::notice::Metal toolchain downloaded in $((SECONDS - started)) s."
}

# Print the UDID of an available iPhone simulator on the newest iOS >= 26 runtime.
pick_iphone_udid() {
  xcrun simctl list devices available -j | python3 -c '
import json, re, sys
best = None
for rt, devs in json.load(sys.stdin)["devices"].items():
    m = re.search(r"iOS-(\d+)-(\d+)", rt)
    if not m or int(m[1]) < 26:
        continue
    for d in devs:
        if d["name"].startswith("iPhone") and (best is None or (int(m[1]), int(m[2])) > best[0]):
            best = ((int(m[1]), int(m[2])), d["udid"])
if best:
    print(best[1])
'
}
