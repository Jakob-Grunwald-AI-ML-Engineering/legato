#!/usr/bin/env bash
# Keyboard dictation stress test: generated Soniox-style takes through the real app + keyboard in the simulator,
# invariants checked on the field and the edit journal. Local only (never CI). See scripts/device/README.md.
#
# Usage: scripts/e2e/keyboard-stress.sh [options]
#   --seed N          reproducible run (default: random, printed)
#   --takes N         number of takes (default 20)
#   --only N          run only take index N (repeatable), e.g. to replay a failure with the same --seed
#   --kinds a,b       short,normal,resplit,joints,long (default: weighted mix)
#   --user MODE       auto (default, about half the takes) | none | mid | post | cursor | mid+post | cursor+post | mid+cursor
#   --speed S         replay speed (default 3)
#   --chunk-ms MS     offline stream cleaner pace (default 120; cleanup lands over len/6 chunks)
#   --app PATH        built Legato.app to install (default: <derived>/Build/Products/Debug-iphonesimulator/Legato.app)
#   --derived DIR     DerivedData dir (default ~/Library/Caches/legato/derived/ios-sim)
#   --build [DIR]     xcodegen + xcodebuild the worktree DIR (default: this checkout) into --derived first
#   --no-install      use what is installed; --no-launch: keep the running app
#   --udid UDID       simulator (default legato-e2e)
#   --dry-run         print the generated takes only
# Exit: 0 all pass, 1 an invariant failed, 2 tool/environment problem (or another driver on the simulator).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
UDID=92445A7A-9AF7-49BA-B61B-94C679A3F2E4
DERIVED="$HOME/Library/Caches/legato/derived/ios-sim"
APP="" BUILD="" INSTALL=1 PASS=() SEED="" DRY=0
die() { echo "keyboard-stress: $*" >&2; exit 2; }

while [ $# -gt 0 ]; do
  case "$1" in
    --seed) SEED="$2"; shift 2 ;;
    --udid) UDID="$2"; shift 2 ;;
    --app) APP="$2"; shift 2 ;;
    --derived) DERIVED="$2"; shift 2 ;;
    --build) if [ $# -ge 2 ] && [ "${2#--}" = "$2" ]; then BUILD="$2"; shift 2; else BUILD="$REPO"; shift; fi ;;
    --no-install) INSTALL=0; shift ;;
    --dry-run) DRY=1; PASS+=("$1"); shift ;;
    --takes|--only|--kinds|--user|--user-rate|--speed|--chunk-ms|--out) PASS+=("$1" "$2"); shift 2 ;;
    --no-launch|--strict-inserts|--verbose) PASS+=("$1"); shift ;;
    -h|--help) sed -n 2,22p "${BASH_SOURCE[0]}"; exit 0 ;;
    *) die "unknown option $1" ;;
  esac
done
SEED="${SEED:-$((RANDOM * 32768 + RANDOM))}"
[ -n "$APP" ] || APP="$DERIVED/Build/Products/Debug-iphonesimulator/Legato.app"
export LEGATO_SIMULATOR="$UDID"

if [ "$DRY" = 0 ]; then
  command -v axe >/dev/null || die "axe CLI missing (brew install cameroncooke/axe/axe)"
  xcrun simctl list devices | grep -qF "$UDID) (Booted)" || die "simulator $UDID is not booted"
  if [ -n "$BUILD" ]; then
    echo "keyboard-stress: building $BUILD (rev $(git -C "$BUILD" rev-parse --short HEAD)) into $DERIVED"
    (cd "$BUILD/Apps/iOS" && xcodegen generate >/dev/null &&
      xcodebuild build -project Legato.xcodeproj -scheme Legato -configuration Debug -destination "id=$UDID" \
        -derivedDataPath "$DERIVED" -clonedSourcePackagesDirPath "$HOME/Library/Caches/legato/SourcePackages" -quiet >"${TMPDIR:-/tmp}/keyboard-stress-build.log" 2>&1) ||
      die "build failed, see ${TMPDIR:-/tmp}/keyboard-stress-build.log"
  fi
  [ -d "$APP" ] || die "no app at $APP (build it, or pass --build / --app)"
  exe="$(/usr/libexec/PlistBuddy -c 'Print CFBundleExecutable' "$APP/Info.plist")"
  stamp() { echo "  $1: $(stat -f '%Sm' -t '%Y-%m-%d %H:%M:%S' "$2") sha256 $(shasum -a 256 "$2" | cut -c1-12)"; }
  echo "keyboard-stress: build under test $APP"
  stamp "app binary" "$APP/$exe"
  kb="$(ls -d "$APP"/PlugIns/*Keyboard*.appex | head -1)"; stamp "keyboard binary" "$kb/$(/usr/libexec/PlistBuddy -c 'Print CFBundleExecutable' "$kb/Info.plist")"
  if [ "$INSTALL" = 1 ]; then
    xcrun simctl install "$UDID" "$APP" || die "install failed"
    inst="$(xcrun simctl get_app_container "$UDID" de.gruenwald.legato app)"
    echo "keyboard-stress: installed"; stamp "installed app binary" "$inst/$exe"
  fi
fi

exec uv run --script "$HERE/keyboard-stress/stress.py" --udid "$UDID" --seed "$SEED" ${PASS[@]+"${PASS[@]}"}
