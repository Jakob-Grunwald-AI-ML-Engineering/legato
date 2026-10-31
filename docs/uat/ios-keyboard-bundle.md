# Physical iOS keyboard acceptance — 2026-10-31

Product revision `0bd1ecaed4e712265b8b77f64a2b96c26596f5aa` was signed, installed on the physical iPhone 17 (`de.gruenwald.legato`) and installed/launched in the isolated Mac app (`de.gruenwald.legato.mac.composer-debug`, hotkeys disabled). Both native builds and code-signature checks passed. Production Mac was untouched. This supersedes the phone-install hold in the [earlier report](composer-two-stage-authoring.md).

## Overflow diagnosis and repair

On the earlier `1bc85ec` revision, a controlled 5,000-word paragraph became blank before the native runner executed any tap. The matching physical-device diagnostic recorded 15 `RBLayer unable to create texture BGRA8Unorm` failures for LegatoKeyboard PID65515 between 11:40:49.771 and 11:40:50.513, with texture dimensions up to 1269×93408 pixels. This establishes an oversized texture allocation failure; it does not establish a Jetsam termination. The PID remained present in a later diagnostic. A subsequent `483e541` comparison still fell back to the native keyboard; no matching crash/Jetsam termination reason was recovered.

The final bundle bounds blur/shadow input, skips oversized word effects, clips the viewport before Send transforms, and removes unbounded whole-composer/block opacity transitions. Separately, the publication-cache check reduced twenty identical 5k polls to one 394,172-byte write and one decode, preserving every word. This cache result is an owner-run deterministic check, not a physical memory measurement.

On installed `0bd1eca`, a four-word fixture and then a 5,000-word / 43,889-character paragraph both rendered in the actual Composer. Extension PID65997 survived both captures. The large screen displayed later words and a scroll indicator with the Legato toolbar still present. No agent UI gestures occurred between seeds, but concurrent user activity appeared during this comparison, so an exclusive gesture-free large-edit/Insert acceptance claim remains open. Fresh post-fix GPU-log absence and peak device memory were not measured.

## Native interaction results

The final-source native body measured the extension at **402×271 points**, with a **402×217-point Composer viewport** and a native ABC face approximately **59.67×43 points**. No Draft header, Undo/Redo or extra utility row was present. Swiping preserved the viewport height. Native ABC opened the reused typing keyboard; actual h/e/l taps entered `hel` into the disposable external field. A physical screenshot showed three live suggestions: `helfen`, `hey`, `hello`.

**Prediction selection/delete/Composer return/exact-once phone Insert remain unproven.** Earlier runner failures came from an invalid generic Keyboard-type assertion, an empty prediction-wrapper assertion and seeding before host relaunch. These were private-driver errors. Later native attempts reached live suggestions but failed the Button-only prediction lookup. The final simplified attempt found neither mode control after the user returned to their chat, before any test gesture; testing stopped. A coordinate-based word tap also failed to open the quote bubble, without enough evidence to distinguish a missed glyph from a product hit-test issue. Phone manual bubbles and animation timing remain untested.

Only synthetic fixtures were intentionally changed. A previously poisoned 5k fixture was cleared only after exact ownership verification, restoring an empty usable keyboard. No microphone/provider start command was issued by the agent, no simulator was launched, and no new paid calls were made. During the final window, a real user session became active; it was left untouched, without cleanup, stop or further device capture. Controlled Claude usage remains at the conservative cumulative upper estimate **$0.7464997 / $2**. Human UAT and the remaining physical flows are pending.

[Small Composer](artifacts/ios-keyboard-bundle/small.png) · [Readable 5k Composer](artifacts/ios-keyboard-bundle/large.png) · [Live native predictions](artifacts/ios-keyboard-bundle/predictions.png). All retained screens show disposable synthetic content; raw device logs and unrelated user screens remain private.
