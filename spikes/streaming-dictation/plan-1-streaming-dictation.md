# Bundle 1: streaming dictation into the field — implementation plan

Base: `main`. Spike evidence: `spikes/streaming-dictation/{harness-report,device-findings}.md` on branch `spike/streaming-dictation`. Reuse the spike's `ShadowEdit.swift` + `ShadowEditTests.swift` (cherry-pick); leave `ShadowSpike.swift` behind.

## Goal and scope

Dictation on the iOS keyboard types raw Soniox text into the host field as it is spoken (finals and non-finals). Soniox revisions flip only the words that changed. Each finished sentence is cleaned and lands as a word-level diff behind the speaking head. It feels like Apple dictation: text appears at once and single words change.

Done when:
- A new send mode `live` is the default (`DictationSendSetting`); `onStop`, `afterPause`, `lineByLine` keep working unchanged.
- In `live`, non-final text is in the field within ~1 s of speech; revisions and cleanup change only the differing words, anywhere in the run.
- Drift (the user taps elsewhere, types, or the host changes text) never corrupts the field: Legato stops editing the affected text and keeps appending at the cursor (today's tail-only behaviour).
- No cursor walking in this bundle. Only moves to an edit point and back.

Exclusions: Mac (it types through AX ranges; untouched beyond shared `DictationPipeline` changes, which must stay behaviour-neutral for the Mac); instruction mode/magic toggle (bundle 2); marked text (`setMarkedText`); async re-transcription (the spike says no); full-field reads.

## Decisions and constraints

- **Soniox:** keep `stt-rt-v6`, endpointing on, the default 4000 ms non-final window. The spike found no gain from 6000 ms, and endpointing adds sentence breaks.
- **Cleanup unit:** one finished sentence/segment, reusing `DictationCleanupPipeline`. It already cleans finalized segments with two in flight, ordered, raw on failure, guarded by `DictationCleanupGuard`.
  - Model: Haiku 5.5 stays the default. Per sentence it's fast, and the spike's Haiku weakness was on long takes.
  - Make the model selectable in Settings (Haiku / Sonnet), stored in the App Group.
- **The keyboard owns the truth about the field.** The app publishes the run's *target text*; the keyboard diffs it against its shadow and applies the edits. Reasons: the keyboard alone sees the proxy, and the diff stays correct under proxy lag.
- **Shadow rules (lazy):**
  - Seed from the free `documentContextBeforeInput`/`AfterInput` at run start; no walk.
  - Apply every Legato edit to the shadow directly.
  - After each apply, compare the proxy's before-window with the shadow's text before the cursor. A mismatch is drift.
- **Ownership:** the run owns only the spans Legato typed. A user keystroke on the Legato keyboard, a cursor move or drift *freezes* everything before the current cursor. Later target changes to frozen spans are dropped. New text keeps streaming at the cursor.
- **Smoothing:** keep the `TypewriterDrain` reveal (250 ms) for appended text. Flips and cleanup diffs apply immediately in one batch, back-to-front, then the cursor returns.
- **Transport:** App Group `UserDefaults` + Darwin notes, re-read on every note (`LinkStore` contract); one versioned snapshot per publish, at most every 100 ms.

## Implementation tasks

1. **Applier and shadow in core.** Cherry-pick `ShadowEdit.swift`/tests. Add `RunShadow` (shadow text, cursor, owned spans, frozen boundary, drift check) and a planner: shadow + target → ops. Edits are word-level, inside owned unfrozen spans only, back-to-front, UTF-16 cursor moves. Pure and unit-tested.
   Files: `Sources/LegatoKeyboardCore/Input/ShadowEdit.swift`, new `Sources/LegatoKeyboardCore/Input/RunShadow.swift`, tests in `Tests/LegatoKeyboardCoreTests/`.
   Depends on: nothing.
2. **App side: live target text.** In `live`, build the run's target as a list of segments: cleaned sentences where cleanup landed, raw finals otherwise, then the current non-final tail. Publish it with a run ID and version on a new link key (`link.dictation.live` or a `DictationLink` extension). Read the non-final tail from `KeyboardSession.dictationTail`; today it only feeds the word row. Add `Mode.live` as `defaultMode`, plus the Settings UI and the cleanup model picker.
   Files: `Sources/LegatoAppServices/{DictationPipeline,KeyboardSession,DictationSendSetting}.swift`, `Sources/LegatoKeyboardCore/Link/{DictationLink,LinkChannel}.swift`, `Apps/iOS/App/Views/SettingsView.swift`, `Sources/LegatoAgent/SentenceCleanupClient.swift` (model parameter instead of the hard-coded Haiku).
   Depends on: the link contract only (agree on the snapshot struct first; put it in `LegatoKeyboardCore/Link`).
3. **Keyboard: apply live runs.** In `KeyboardController`, receive live snapshots and run them through the task 1 planner. Feed appends through the drain, apply diffs at once, and ack the applied version. Handle freeze triggers: own keystrokes, `selectionDidChange`/`textDidChange` that isn't an own-edit echo (see `OwnEditEcho.swift`), and drift. Keep the word-row tail display in sync. A new run starts a new shadow. Secure fields: no live typing (same as today).
   Files: `Apps/iOS/KeyboardUI/KeyboardController.swift`, `Apps/iOS/Keyboard/KeyboardViewController.swift`, small additions in `Sources/LegatoKeyboardCore/Link/`.
   Depends on: 1, 2.
4. **Replayable test input.** Add a debug bridge command `dictation-debug-replay <file>` that feeds a recorded Soniox token timeline (non-final/final, with timing) into `DictationEngine` in place of the socket. The spike harness's cached raw responses are the input format. Add one neutral fixture recorded from scratch text. This lets agent UAT and Jakob reproduce flips without a mic.
   Files: `Sources/LegatoDevHarness/`, `Sources/LegatoAppServices/DictationEngine.swift`, `scripts/device/README.md`.
   Depends on: 2. Can run in parallel with 3.
5. **Diagnostics.** Internal builds append `live2.*` lines (counts, chars, ms, no text) to `audio-diag.jsonl`: snapshot received, ops applied, flips, cleanup landed/dropped, freezes with cause, drift.
   Files: wherever tasks 2–3 touch.
   Depends on: 2, 3.

## Checks and environment

- Unit tests: the task 1 planner and shadow (word flips mid-run, cleanup replacing an earlier sentence while the tail grows, frozen spans untouched, emoji/UTF-16, drift detection), the task 2 target builder, and the `DictationSendSetting` default. Existing `ProxyEditPlanner*`, `TypewriterReveal*`, `DictationTypist*` and cleanup tests stay green.
- Gate: `scripts/ci/test.sh` runs in the merge queue (`gate`). Locally, run `swift test` once at the end, plus a device build per `legato:iphone-device-debug-loop`.
- Device: Jakob's iPhone (UDID `00008150-000E60360245401C`); build output in `~/Library/Caches/legato/derived/ios-device`. Live Soniox/Claude spend is approved for agent testing; keys are in the main checkout's `.env` for Mac tooling.
- Evidence gaps to report separately: device vs simulator; replayed tokens vs a real voice. Real-voice proof comes from Jakob.

## What to tell the UAT agent

Legato's iPhone keyboard now types dictation into the text field while you speak and corrects single words afterwards; finished sentences get tidied in place. Reach it on Jakob's iPhone in any app's text field with the Legato keyboard; with no microphone, drive dictation with the replay bridge command (`scripts/device/README.md`). Try Notes, Messages, Mail, a Safari text area and WhatsApp, short and long texts, and interrupting yourself by typing or moving the cursor. Use only new notes and drafts you create; never send anything; never edit Jakob's existing content; delete your notes and drafts afterwards. Report what the field showed versus what you expected, with screenshots and the `live2.*` diagnostics.
