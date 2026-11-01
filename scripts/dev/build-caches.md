# Local build caches

Legato keeps the latest build output of each build target and nothing else. Under `${LEGATO_CACHE_DIR:-~/Library/Caches/legato}`:

| Path | Used by |
| --- | --- |
| `derived/gate` | `scripts/ci/test.sh` (iOS and macOS app builds) |
| `derived/mac` | `scripts/ci/release.sh mac-build\|mac-release`, `scripts/device/ctl.sh --target mac build` |
| `derived/ios-sim` | `scripts/e2e/ios-sim.sh` (including `release-check`), `ctl.sh --target sim build` |
| `derived/ios-device` | `ctl.sh build` for the phone, and the XCTest runner of `scripts/device/native-control.sh` |
| `SourcePackages` | the single SwiftPM clone set, shared by all of the above |

Every checkout and worktree uses the same directories, so a build overwrites the previous one in place and Xcode rebuilds incrementally from it. Debug and Release share a target directory: Xcode separates configurations inside `Build/Products` and `Build/Intermediates.noindex`. `native-control.sh` reuses `ios-device` because it builds the same project for the same device SDK; a separate tree would only duplicate gigabytes. `LEGATO_E2E_DERIVED` (ios-sim) and `LEGATO_NATIVE_BUILD` (native-control) override the directory; overrides are never pruned.

## Locking

Builds of one target serialize on that directory's lock, and every build also holds the `SourcePackages` lock. Both are a macOS `lockf` descriptor lock on a persistent sibling `.guard` file, plus a `.lock` owner directory for older scripts. A waiting build blocks up to `LEGATO_LOCK_WAIT` seconds (default 3600). Dead owners are recovered under the same OS lock. Never remove `.guard` files while builds may be running. CI builds use unique disposable directories under `RUNNER_TEMP` and never touch this cache.

## Pruning

`scripts/dev/prune-build-caches.sh` (dry run) and `... --delete` remove all other Legato build output: old `build-derived/`, `e2e-derived/`, `device-derived/` and unknown entries in the cache dir or `derived/`, stale `$TMPDIR/legato-*` and dead `legato-e2e.*` work dirs, and Xcode's `~/Library/Developer/Xcode/DerivedData/Legato*`. It keeps the fixed directories, `SourcePackages`, the `legato-xcodegen-*` tool cache, `~/Library/Caches/LegatoTests` (downloaded models) and agent scratchpads. It skips anything locked, anything modified within `LEGATO_PRUNE_GRACE_SECONDS` (default 3600) and symlinks (never followed). It does not touch installed apps. There is no age limit or size budget; run it at session start and at wrap-up.

`scripts/dev/prune-build-caches.sh --report` prints the size of each fixed directory and each prunable item and deletes nothing.

## Tests

`scripts/e2e/tests/build-cache-test.sh` drives the pruner on private fixtures and the real `mac-build`, gate and simulator entry points with fake Xcode tools. `cache-lock-race-test.sh` covers lock interleavings; `cleanup-test.sh` covers simulator work-directory signal cleanup.
