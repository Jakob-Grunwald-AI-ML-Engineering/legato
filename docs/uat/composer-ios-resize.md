# iOS composer appearance and resize UAT

The composer now shares the native `UIInputView(.keyboard)` surface with iOS's rounded cap and bottom tray. The grabber adjusts the whole extension, leaving the tool strip visible. The empty legacy prediction row is removed. Height defaults to 420 pt, is remembered locally, and is bounded to 260–600 pt on this portrait phone; a short screen lowers the maximum to preserve host space.

Initial continuous-resize baseline (superseded by release-only refinement below), on the physical iPhone 17 (`00008150-000E60360245401C`), 2026-10-30:

| Check | Result |
| --- | --- |
| Native light appearance | PASS: continuous native gray material, native white key faces, no white composer sheet or QWERTY grid |
| Native downward handle drag | PASS: requested height 420 → 271 pt |
| Native upward handle drag | PASS: 271 → 512 pt, a meaningful 241 pt expansion across the old extension boundary |
| Persistence after full host app relaunch | PASS: 512 pt retained, grabber frame `{{0,286.7},{402,28}}` |
| Native dark appearance | PASS: dark material, legible text/grabber, native dark key faces, matching bottom tray |
| Resize/keyboard geometry checks | PASS: 12 checks in two suites |
| Signed generic iOS build and physical installation | PASS, including merged prompt resources from `0ea100a` |

The dedicated grabber has a nontransparent hit surface, updates a preview during movement, commits the actual keyboard height once on normal release, resets its drag anchor and preview after cancellation, and exposes an accessibility adjustable action. Unit checks cover bounded heights, reduced landscape space, and upward/downward movement. VoiceOver interaction itself was not exercised. The current UAT used an empty composer; this leg does not add new populated-document scrolling or native Insert proof.

During the expanded native capture, the app unexpectedly showed Email mode and a failed microphone start (`com.apple.coreaudio.avfaudio error 560226676`). No microphone tap was intended in the resize sequence. Cancel returned idle/dictating false but retained a microphone lease in debug state; a full app relaunch cleared the error and visual recording indicator. This incidental audio behavior is outside the resize change and is not counted as a passed microphone test. No debug transcript injection or intentional paid provider calls were used in this leg.

Screenshots cover the entire device screen and a synthetic native host form. [Before](artifacts/ios-resize/before.png), [native light](artifacts/ios-resize/native-light.png), [compact](artifacts/ios-resize/compact.png), [expanded dark after relaunch](artifacts/ios-resize/dark-expanded.png). Native accessibility evidence: [compact](artifacts/ios-resize/compact-tree.txt), [expanded](artifacts/ios-resize/expanded-tree.txt), [reopened](artifacts/ios-resize/reopened-tree.txt).

Final bridge state after relaunch: `status: idle`, `mode: message`, `busy: false`, `dictating: false`, `microphoneLeaseActive: false`, `pendingLineIDs: []`, `error: ""`. The device was left in the light native host harness with the remembered 512 pt composer height.


## Final release-only refinement

The visible pill now sits 2 pt below the extension's owned top, 10 pt higher than the first implementation. iOS owns the rounded cap above this view, so the extension does not draw there. While dragging, only a translucent guide and height label update inside the existing keyboard bounds; the host keyboard height remains unchanged until one resize call on normal release. Cancellation clears the preview without committing. No oversized transparent extension reserves host touch space. Tap toggles compact/expanded as another route; accessibility height adjustment remains available.

Native physical results on the refined build (`54872f6`): downward drag **512 → 352 pt**, upward drag **352 → 502 pt**. Both ordinary native releases completed. Upward boundary cancellation was not reproduced with this large pane. The source has a single resize callback in `onEnded`; `onChanged` changes only local preview state. Motion smoothness was not independently quantified: Apple's recording capability returned CoreDevice error1001 (unsupported on this device), while full-device screenshots worked. The 12 affected checks and signed iOS build passed again after this refinement; no second full suite or Mac build was run.

Final screenshots: [higher handle](artifacts/ios-resize/higher-handle.png), [released compact](artifacts/ios-resize/release-compact.png), [released expanded](artifacts/ios-resize/release-expanded.png). Exact native geometry: [352 pt](artifacts/ios-resize/release-compact-tree.txt), [502 pt](artifacts/ios-resize/release-expanded-tree.txt). These supersede the earlier continuous-drag geometry as current gesture proof.

The final grabber tap changed **502 → 260 pt**, and a full app relaunch retained **260 pt**. [Tap tree](artifacts/ios-resize/release-tap-tree.txt), [reopened tree](artifacts/ios-resize/release-reopened-tree.txt), [final full screen](artifacts/ios-resize/release-final.png). Final refined-build bridge state again confirmed idle Message, busy/dictating false, microphone lease false, empty error and no pending lines. Device released in the light native field harness, ready for hands-on use at compact height.
