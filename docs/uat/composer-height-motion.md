# Composer height motion: unresolved

Physical iPhone 17, 2026-10-30, Debug build from `5e51d4e` plus the diagnostic below. The user's report that the height transition looks like a jump remains unresolved. No animation fix is claimed by this PR.

A passive `CADisplayLink` sampled the keyboard extension view's presentation bounds in its own UIWindow for 0.7 seconds. It never changed a constraint or requested layout. Low to Medium produced 44 samples containing only 82 and 243 pt heights: 82 pt at 31.8 ms, then 243 pt at 47.3 ms, with no intermediate heights. The extension UIWindow also switched directly between those heights. Native full-screen captures and touch controls worked; the real composer handle was tapped through XCTest.

A candidate flushed the entire owned UIWindow before changing the constraint, prevented `viewWillLayoutSubviews` from rewriting it during the transition, and used a 0.3-second UIKit animation with `beginFromCurrentState`. Medium to Full still produced only 243 and 651 pt presentation heights across 44 samples. The candidate was discarded. The current UIKit and SwiftUI animation declarations alone are not evidence of a smooth visible resize.

These traces observe the extension's own presentation geometry, not a video of WindowServer or the external host application. They corroborate the reported jump but do not establish that every possible public-API approach is exhausted. A local fade or content transform would not prove that the actual keyboard boundary and host field resize smoothly. No display-link-driven height updates or transparent oversized touch area were added.

The original resize implementation remains. The audio repair from #148 is retained. Geometry-only traces are in [artifacts/composer-height-motion](artifacts/composer-height-motion); they contain no document text or credentials. The baseline Low trace records the three-preset UI that existed during this investigation, before the subsequent two-preset UI change.

## Repeat the diagnostic

Debug builds only, disabled by default. Write `1` to an ordinary local file, then copy it into the App Group:

```sh
printf '1' > /tmp/legato-keyboard-motion.enabled
xcrun devicectl device copy to --device 00008150-000E60360245401C --domain-type appGroupDataContainer --domain-identifier group.de.gruenwald.legato --source /tmp/legato-keyboard-motion.enabled --destination Library/Caches/keyboard-motion.enabled
```

Change the height using the real keyboard. After 0.7 seconds:

```sh
bash scripts/device/ctl.sh --target device pull --group Library/Caches/keyboard-motion.json
```

The latest six traces are retained, with monotonic elapsed seconds, presentation height/top, model height and window height. Write `0` to the local marker and repeat the copy command to disable observation. The probe is absent in Release builds and performs no work in Debug without the opt-in marker.

Validation: signed physical-device Debug build passed; native handle tap and geometry capture passed. Full suites were not rerun for this diagnostic-only change. Smooth height animation acceptance remains open.
