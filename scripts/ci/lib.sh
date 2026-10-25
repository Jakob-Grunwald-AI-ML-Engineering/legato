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
