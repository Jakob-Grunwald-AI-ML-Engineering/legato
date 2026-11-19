# iPhone: dictation-first top row (#315)

Builds on #313 (`ios-staged-handoff.md`). In #313 the preview became the send control: a tap sends the text cleaned, a swipe up inserts it raw. Jakob, 2026-11-19: the magic key is no longer needed, and he almost never uses the undo and redo keys. The keyboard's top layer becomes one multifunction dictation key next to the transcript.

## Decisions (Jakob, 2026-11-19)

**Full keyboard.** The word row and the tool row merge into one row above the key grid:
- the dictation key sits on one side;
- the transcript, today's preview row with its tap, swipe, exit, shimmer and bloom, fills the rest of the row beside it.

The keyboard gets shorter by the height that is freed. The magic, undo, redo and chevron keys are removed.

**Dictation key gestures:**
- tap starts, pauses or resumes, as the mic key does now;
- swipe down minimises the keyboard;
- swipe up expands it;
- swipe left undoes, swipe right redoes, through the existing undo owner.

A tap must stay reliable, so a drag never also taps. The swipe threshold is an estimate of about 20 pt; tune it on the phone. Faint hint glyphs (‹ › ⌄ and ⌃ when minimised) show on the key for the first few uses, counted in keyboard preferences, then never again.

**Minimised keyboard.** Two rows of keys on the dictation-key side:
- top: the dictation key;
- below it: backspace (with the existing repeat-delete) and enter;
- the globe key next to them when iOS asks for one (`needsInputModeSwitchKey`).

The transcript spans both rows beside them.

**Suggestions.** When no transcript is showing, the transcript area shows the existing typing suggestions (the word row's prediction slots), with fewer slots to fit the narrower width.

**Setting.** *Dictation key*: Left or Right, default Right. It lives in the app's Settings under Keyboard or Dictation, and the keyboard reads it from the App Group, so the keyboard and the app agree. The layout mirrors.

**Magic key removed.** The keyboard's magic/instruction UI goes: `MagicKey`, `InstructionRowView`, the keyboard-side instruction state and the magic toggle in presence. The app-side instruction engine and its link stay; removing those is a separate cleanup. The Mac is untouched.

**Kept.** Dictation, the staged preview behaviour from #313, the key grid, emoji, globe and suggestions all keep working.

## Owners

- **Layout:** geometry tokens stay in `KeyboardHeights` / `WordRowLayout` / `KeyboardMetrics` (`KeyGeometry`: `wordRowFrame`, `toolRowFrame`) and in `KeyboardStrip` / `StripRow` / `StripGeometry` for the compact form. Replace the two frames with one top-row frame rather than adding a parallel set. Layout tests are updated deliberately.
- **Dictation key:** extend `MicKey` with the gestures. Expansion stays with `KeyboardController.toggleExpansion` and `KeyboardExpansion`. Undo and redo go through the controller's existing undo and redo actions, which the removed keys used.
- **Transcript:** `WordRowView` / `PreviewRow` move into the new row unchanged in behaviour. Their width now comes from the row instead of the full keyboard width; check the preview's inset and fade, and the corner inset on the dictation-key side.
- **Setting:** a new key beside the existing keyboard preferences (`KeyboardPreferences`, App Group). No second store.

## Checks

- Small unit tests for:
  - the new geometry: heights, frames, and the left/right mirror for full and minimised;
  - gesture classification: tap vs swipe directions and threshold;
  - the hint counter.
- Existing tests are updated where the contract changed deliberately (the removed keys); none are weakened.
- `LegatoKeyboardCoreTests`, `LegatoAppServicesTests`, the unsigned iOS build, and the full `scripts/ci/test.sh` once at the end.

## What to tell the UAT agent

**What changed for the user.** On iPhone, the Legato keyboard's top area is now a single row:
- a big dictation key on one side, with the dictation transcript or word suggestions beside it;
- on the dictation key: tap to dictate or pause, swipe down to shrink the keyboard and up to bring it back, swipe left to undo and right to redo;
- shrunk, the keyboard keeps only the dictation key, delete and return beside the transcript;
- Legato's Settings can put the dictation key on the left or the right.

The magic key and the undo and redo keys are gone.

**How to reach it.** Jakob's iPhone through the device-measure harness and `ctl.sh` replay fixtures (see the `legato:iphone-agent-uat-runbook` memory), typing in a new Apple Notes note.

**Limits and permissions:**
- Ask Jakob before taking the phone, and hand it back visibly.
- Never touch real chats or notes.

**Evidence to return:**
- Close-up screenshots per state: full, minimised, left and right, and while dictating.
- A ranked visual judgement.
