# iOS composer presets and native strip

The keyboard has three remembered sizes: **Low** is the grabber and one native tool row (82 pt); **Medium** matches the native keyboard's measured content height (243 pt portrait); **Full** covers approximately 85% of the screen including iOS's cap and bottom tray (651 pt owned content on this 874 pt iPhone). A vertical swipe on the grabber, strip buttons, or gaps advances exactly one preset on release. The document viewport retains scrolling. Tapping the grabber cycles sizes; accessibility adjustment steps up/down.

The single row contains Mode, Undo, Redo, Insert, Cancel, Mute, and the existing start/stop mic. All use native key faces; Mode shows the current icon. Tap Mode to cycle, hold for the native icon/name list. Bottom Undo routes to Composer when it owns the document; Composer has no Redo contract, so Redo is disabled during those sessions. Mute uses the merged backend's same-session transcription gate while agents remain active.

Native validation on the physical iPhone 17, 2026-10-30:

| Check | Result |
| --- | --- |
| Low / Medium / Full geometry | PASS: owned heights 82 / 243 / approximately 651 pt; Full cap starts at 131 pt, leaving approximately 15% host space |
| Swipe across the right mic button | PASS: Low → Medium, exactly one preset; mic remained labelled Start dictation |
| Mode hold | PASS: native four-row icon/name picker visible without clipping in Medium |
| Native palette / one row | PASS: matching system material and key faces; no duplicate upper controls or QWERTY |
| Preset contracts and existing geometry | PASS: 13 focused checks, including screen bounds, thresholds, one-step swipes and stored enum values |
| Final signed iOS build and physical installation | PASS, including merged mute backend and final mode icon |

The final transition restores the original Legato mechanism: a 0.2-second UIKit layout animation coordinated with SwiftUI ease-in-out on the selected preset and composer opacity. The manual display-link resize was removed after poor hands-on feedback. **Final animation feel has not been confirmed by the user.** A successful build is not smoothness proof; physical screen recording is unsupported on this device.

Mode selection across separate native-test launches was not confirmed, because reactivation can dismiss the popup; no passed selection claim is made. Native Mute/Unmute button UAT and real microphone startup were handed to the voice-repair leg. The backend has separate focused mute tests. This UI leg did not add new paid provider calls, populated-document scroll proof, or a native Composer Redo feature.

[Final mode-icon strip](artifacts/ios-presets/final-icon-strip.png). Preset geometry captures taken before the final icon-only tweak: [Full](artifacts/ios-presets/full-geometry.png), [Low](artifacts/ios-presets/low-geometry.png), [Medium](artifacts/ios-presets/medium-geometry.png). [Native mode picker](artifacts/ios-presets/native-mode-picker.png), [mic-button swipe tree](artifacts/ios-presets/mic-swipe-tree.txt), [Low tree](artifacts/ios-presets/low-tree.txt). Screens show a synthetic native host form.
