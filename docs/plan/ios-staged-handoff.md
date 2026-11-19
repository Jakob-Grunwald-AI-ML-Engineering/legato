# iPhone staged dictation: manual send and animated hand-off (#313)

Follows `ios-staged-dictation.md` (#312, merged in #314). Staged delivery works; this round makes it feel good and puts sending under the user's hand.

## Goal and scope

- **Send setting.** New iPhone setting *Send to field* under the "As you speak" mode: **When I tap the preview (default)** or **At each sentence end** (today's behaviour).
- **Manual mode.** Pauses and sentence ends never close a unit. A tap on the preview row sends everything spoken so far as one cleaned unit, and listening continues. Stop sends the rest.
- **Touch bloom.** The tap shows a soft bloom across the row that grows from the touch point. It is not a button look.
- **Slower typewriter.** Staged units type into the field at about 35 ms per grapheme, which is an estimate to tune on the phone. A user key lands the rest of the running burst at once and then goes in.
- **Synced exit.** The unit being typed leaves the preview letter by letter, in step with the field typewriter. Each letter lifts about 6 pt and fades, as if it rises to a layer above. Raw text that has been sent and is waiting for cleanup gets a slow shimmer in the magic colours (`CountdownRim`: purple, blue, pink), so the tap reads as "taken".
- **Reduce Motion.** No lift, no shimmer and no bloom growth. Units type whole (as today) and fade out of the preview as a whole. A tap shows a brief plain highlight.

**Out of scope:**
- The Mac. It does not use staged delivery, and its typewriter pace stays at one piece per 60 Hz frame, capped at 250 ms. That is a kept difference, recorded in `docs/field-editing.md`.
- The buffered modes (On stop, After a pause).
- Removing the in-place cleanup internals.

## Decisions and constraints

Jakob decided these on 2026-11-19:
- Manual is the default.
- Only a tap or Stop sends in manual mode.
- The pace starts at 35 ms per letter and is matched to the exit.
- The exit animation should be nice but not distracting, chosen on the phone.

**Manual unit.** The open unit grows across sentences and pauses. `maxUnitWords` (40) does not close it, because nothing sends without the user. A tap closes the whole open unit, raw finals plus the head.

**Tap sends the head too.** On a tap the app cuts the recognizer (`DictationEngine.finalizeChunk`, already used by the magic-key cut). Once the `finalize` boundary arrives, or after 1.5 s without it, the open unit closes and is cleaned. Words still being spoken after the cut start the next unit.

**Auto mode** keeps today's unit rules: sentence end with at least 6 words, an admitted pause, Stop. It also gets the new pace and the new exit.

**Time bounds must include the burst.** A 300-character unit at 35 ms takes about 10 s to type. These limits are measured from when the unit is confirmed or begins, after its typing time, and never cut a burst short:
- the stall bound (`StagedDictation.stallMs`, 10 s; `unverifiedStallMs`, 2 s),
- the queue's confirm budget,
- `takeEndWait` (3 s).

The unverified 2 s bound counts only while the unit has not started.

**Key latency.** A key during a burst lands the rest of the burst in one write, then the key, so the key waits only for one write. The 500 ms interruption budget in `CLAUDE.md` still holds.

**Letters leaving vs. layout.** A leaving letter keeps its place while it lifts and fades, so the remaining text does not reflow letter by letter. When the unit has fully left, the rest of the preview settles into place with a short animated move, not a jump.

## Owners and measurements

- **Pace:** `ChunkEntrance` (`Sources/LegatoKeyboardCore/Input/ChunkEntrance.swift`) owns typewriter pace. Add a staged typewriter pace: `typewriterGapMs = 35`, no cap, one grapheme per piece. It is chosen by the iPhone staged path (`FieldQueue.Edit.isSpeech` units). The Mac and other chunks keep the frame pace.
- **Send mode:** `DictationSendSetting` (`Sources/LegatoAppServices/DictationSendSetting.swift`) owns send settings. Add `liveSendKey = "dictation.liveSend"`, `enum LiveSend { manual, sentence }`, and default `.manual`. iOS `SettingsView` shows it only under "As you speak". Rewrite the stale footer, which still describes in-place correction, for the staged behaviour.
- **Unit rules:** `LiveDictationRun` (`Sources/LegatoKeyboardCore/Link/LiveDictation.swift`) owns unit closing. Add a `manual` flag: `addFinal` never closes, and `flush()` closes everything.
- **App-side send:** `DictationPipeline` gets `sendNow()`: finalize cut, then flush, with a 1.5 s fallback. It also stops `closeUnitAtPause` in manual mode. `KeyboardSession` and `KeyboardLinkHost` route it.
- **Request:** `KeyboardRequest` / `RequestCommand` gains `case send`. The keyboard writes it through the same `LinkClient` path as `stop`. In the background the app acts on it like `stop`, with no hop.
- **Exit progress:** `StagedDictation` owns preview text. It gains the exit progress of the in-flight unit: `exited` graphemes of the unit's own text, separator excluded. The controller feeds it from the queue's sent pieces. `preview` stays the single derivation, and the view gets `(leaving: String, exited: Int, rest: String)` or an equivalent from it.
- **Preview view:** `WordRowView.PreviewRow` draws the preview. Draw the lift and fade with a SwiftUI `TextRenderer` (iOS 26) over per-glyph exit times, driven by a `TimelineView` only while letters are leaving. Reuse the existing `GlyphReveal` timing curve if it fits. Pull the shimmer and bloom colours from one shared magic-gradient constant: extract it from `CountdownRim` into `LegatoComposerUI`, and point `CountdownRim` at it.
- **Measurements:**
  - The 35 ms pace, the 6 pt lift and the fade length (about 220 ms) are estimates, to tune on the phone with Jakob.
  - The 1.5 s finalize fallback is an estimate. Log `finalize` latency with the existing diagnostics so it can be measured.

## Implementation tasks

**A. App side: setting, manual units, send** (agent A)
- Files:
  - `Sources/LegatoAppServices/DictationSendSetting.swift`
  - `Sources/LegatoKeyboardCore/Link/LiveDictation.swift` (the `manual` flag only)
  - `Sources/LegatoAppServices/DictationPipeline.swift`
  - `Sources/LegatoAppServices/KeyboardSession.swift`
  - `Apps/iOS/App/Keyboard/KeyboardLinkHost.swift`
  - `Apps/iOS/App/AppController.swift`
  - `Apps/iOS/App/Views/SettingsView.swift`
  - `Apps/iOS/App/Debug/DebugBridge.swift` (a `liveSend` command for UAT)
  - Tests in `Tests/`
- Live mode reads the send setting at take start; one take uses one rule.
- Depends on `RequestCommand.send`, which agent B adds.

**B. Keyboard side: pace, key flush, exit, bloom, shimmer** (agent B)
- Files:
  - `Sources/LegatoKeyboardCore/Input/ChunkEntrance.swift`
  - `Sources/LegatoKeyboardCore/Input/FieldQueue.swift`
  - `Sources/LegatoKeyboardCore/Link/StagedDictation.swift`
  - `Sources/LegatoKeyboardCore/Link/KeyboardRequest.swift`
  - `Apps/iOS/KeyboardUI/KeyboardController.swift`
  - `Apps/iOS/KeyboardUI/WordRowView.swift`
  - `Apps/iOS/KeyboardUI/LinkClient.swift`
  - `Sources/LegatoComposerUI/CountdownRim.swift` (the gradient extraction)
  - Tests in `Tests/`
- The tap on a non-empty preview sends `.send` and blooms. A tap on an empty preview does nothing.
- The bounds listed under "Time bounds must include the burst" scale with the burst.

**C. Docs** (main session, after A and B)
- Update `docs/field-editing.md`: manual send, the pace and the Mac kept difference.

## Checks and environment

- **Unit tests** (small, contracts only):
  - `ChunkEntrance` staged pace: 35 ms, one grapheme per piece, no cap.
  - The `FieldQueue` key-during-burst flush: the rest of the burst is one write, before the key.
  - `LiveDictationRun` manual: no close on sentence end, pause or 40 words; `flush` takes everything.
  - `StagedDictation` exit progress.
  - `DictationSendSetting` default `.manual`.
  - Existing staged tests stay green.
- **Gate:** the full `scripts/ci/test.sh` once on the final candidate before enqueueing.
- **Device:**
  - Jakob's iPhone, built with `ctl.sh build` (or generic xcodebuild if the phone is busy) and installed with `ctl.sh install`.
  - Replay fixtures through `ctl.sh` drive takes without speech. The hidden-keyboard path needs real speech.

## What to tell the UAT agent

**What changed for the user.** On iPhone, in the "As you speak" mode:
- Dictated words wait in the two-line preview above the keys until the user taps that row, or presses Stop. Tapping sends everything said so far, cleaned, to the text field, and the row glows briefly.
- The text then types itself into the field visibly, letter by letter, and the same letters lift away from the preview as they go.
- Settings → Dictation has *Send to field*, with the tap or every sentence end.
- Reduce Motion should make all of this plain.

**How to reach it.** Jakob's iPhone through the device-measure harness, with replay fixtures via `ctl.sh`. Use the Notes app or the harness field.

**Limits and permissions:**
- Ask Jakob before taking the phone, and hand it back visibly.
- Never send messages, and never touch real chats or drafts.

**Evidence to return:**
- Screenshots or a screen recording of the hand-off.
- The longest key delay during typing.
- Whether it looks good and reads as intuitive.

## Round 2 (2026-11-19, after the phone test)

- The swipe between the compact strip and the full keyboard is gone; the chevron is the only switch.
- A swipe up on the preview inserts what is not typed yet without cleanup (`RequestCommand.sendRaw`, `DictationPipeline.sendRawNow`); a tap still sends for cleanup. A subtle upward swoosh, none with Reduce Motion; a second accessibility action "Insert without cleanup".
- The kept-text row is removed. When delivery is held, the undelivered units return to the preview as pending; a tap or swipe sends them again at the caret. A keyboard that goes away leaves the take in History only.

## Round 3 (2026-11-19): the mic key pauses (manual mode)

- In manual mode Stop does not send: `DictationPipeline.pauseTake` keeps the run open ("paused", published as `LiveDictationSnapshot.paused`), the words stay pending in the preview with tap (cleaned) and swipe up (raw) live. The next start resumes the same run (`beginTake`), new words join the open unit and are cleaned with it as one.
- A send while paused skips the recognizer cut and ends the run once the unit is out. The run also ends at the keyboard session's close or hide (History records the cleaned take; the raw finals are checkpointed as they arrive), at a Stop with nothing pending, or when the keyboard reports it left the run (`LiveDictationAck.ended`). Sentence-end mode is unchanged.
- `HostLink` accepts `send`/`sendRaw` while no phase runs (a paused take has none); the app ignores a send with nothing to send.
