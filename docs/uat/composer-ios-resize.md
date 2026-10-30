# iOS composer appearance and resize UAT

The composer now shares the native `UIInputView(.keyboard)` surface with iOS's rounded cap and bottom tray. The grabber adjusts the whole extension, leaving the tool strip visible. The empty legacy prediction row is removed. Height defaults to 420 pt, is remembered locally, and is bounded to 260–600 pt on this portrait phone; a short screen lowers the maximum to preserve host space.

Validation on the physical iPhone 17 (`00008150-000E60360245401C`), 2026-10-30:

| Check | Result |
| --- | --- |
| Native light appearance | PASS: continuous native gray material, native white key faces, no white composer sheet or QWERTY grid |
| Native downward handle drag | PASS: requested height 420 → 271 pt |
| Native upward handle drag | PASS: 271 → 512 pt, a meaningful 241 pt expansion across the old extension boundary |
| Persistence after full host app relaunch | PASS: 512 pt retained, grabber frame `{{0,286.7},{402,28}}` |
| Native dark appearance | PASS: dark material, legible text/grabber, native dark key faces, matching bottom tray |
| Resize/keyboard geometry checks | PASS: 12 checks in two suites |
| Signed generic iOS build and physical installation | PASS, including merged prompt resources from `0ea100a` |

The dedicated grabber has a nontransparent hit surface, updates during movement rather than waiting for touch completion, resets its drag anchor after cancellation, and exposes an accessibility adjustable action. Unit checks cover bounded heights, reduced landscape space, and upward/downward movement. VoiceOver interaction itself was not exercised. The current UAT used an empty composer; this leg does not add new populated-document scrolling or native Insert proof.

During the expanded native capture, the app unexpectedly showed Email mode and a failed microphone start (`com.apple.coreaudio.avfaudio error 560226676`). No microphone tap was intended in the resize sequence. Cancel returned idle/dictating false but retained a microphone lease in debug state; a full app relaunch cleared the error and visual recording indicator. This incidental audio behavior is outside the resize change and is not counted as a passed microphone test. No debug transcript injection or intentional paid provider calls were used in this leg.

Screenshots cover the entire device screen and a synthetic native host form. [Before](artifacts/ios-resize/before.png), [native light](artifacts/ios-resize/native-light.png), [compact](artifacts/ios-resize/compact.png), [expanded dark after relaunch](artifacts/ios-resize/dark-expanded.png). Native accessibility evidence: [compact](artifacts/ios-resize/compact-tree.txt), [expanded](artifacts/ios-resize/expanded-tree.txt), [reopened](artifacts/ios-resize/reopened-tree.txt).
