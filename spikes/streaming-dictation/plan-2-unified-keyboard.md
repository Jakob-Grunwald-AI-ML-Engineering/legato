# Bundle 2: unified keyboard with instruction mode — implementation plan

Base: `main` after bundle 1 has merged (it needs `RunShadow`, the anywhere applier and `live` mode). Spike notes: `spikes/streaming-dictation/harness-report.md` (sections "Product rule: walk lazily" and "Instruction mode") and `device-findings.md`.

## Goal and scope

One iOS keyboard, with the full keys always on screen. A magic toggle turns speech into an **instruction** instead of dictation. The instruction runs against the text in the field, and the result lands in the field as word-level edits. This replaces the separate composer surface on iOS.

Done when:
- **Toggle:** tap latches instruction mode on and off; hold is momentary (on while held). Releasing, or tapping off, runs the instruction. Nothing runs on its own.
- **Mixed speech:** dictation and instructions can alternate within one session. Each speech segment is tagged with the mode active when it was spoken.
- **Strip:** while instruction mode is on, the strip shows the live instruction transcript. While an instruction runs, it shows its status, then accept/undo.
- **Edits:** the result reaches the field through the bundle 1 applier and only changes text the model was shown.
- **Undo:** one tap restores the pre-instruction text of the scope.
- **Carried over from the composer:** history (one entry per instruction, before/after), the model choice setting, and `DocPresenter`-style confidence marks in what the model sees.
- **Composer surface removed:** the iOS composer surface (`KeyboardSurface.composer`, `ComposerView` in the keyboard) is gone. The Mac composer panel and the shared `ComposerSession` keep working.

Exclusions: Mac changes; a full-tool agent mode (line-edit tools); marked text; editing text the model wasn't shown; automatic running on a pause.

## Decisions and constraints

The design has three layers, built so that small models work too, with no keyword matching on the instruction:
1. **Structural prefetch (start):**
   - The model is shown the session's text (from the shadow), the cursor paragraph, and `selectedText` when there is a selection.
   - The read goes back to the nearest structural stop: field start, a quote header ("On … wrote:", "-----Original Message-----"), a signature `-- `, or a character cap (start at 3,000).
   - Walk only when no shadow exists yet *and* the proxy shows more text beyond what is known.
   - Text that wasn't read is shown to the model as a marker ("text continues above, not read").
2. **Edit as plain text:**
   - The reply's first line is `SCOPE: selection|session|paragraph|above|all`, followed by the rewritten text for that scope.
   - The app maps the scope to a shadow range. The keyboard word-diffs the rewrite into the field.
   - A scope larger than what the model was shown triggers a read: stop the stream after the header, read deterministically up to the cap, then re-ask with that text.
   - No line IDs and no edit tools.
3. **More context:**
   - One argument-free tool, `read_more()`. Each call extends the read upward by one block (paragraph group, ≤1,000 characters), within the cap.
   - It returns the text plus `more_remains: true|false`.
   - A failed read comes back as a tool error, never as partial text.

Constraints:
- **Walking stays rare and self-verifying.** Accept a window pair only after two identical reads that stitch. Spike: long Messages fields return windows that don't tile at some boundaries, so a failed stitch ends the read with an error.
- **The cursor visibly moves during a walk,** so the strip shows "reading…" while it happens.
- **Model:** the composer's model choice (`composer.liveModel`) carries over. The prompt must work on Haiku. A new prompt goes in `Sources/LegatoAgent/Prompts/instruction.md`, built from the composer's writing guidance where it applies.
- **Transport:** a new keyed request/reply pair `link.read` / `link.read.ack` (app → keyboard: "read N more"; keyboard → app: text, `more_remains`, error), following the `RefineRequest`/`RefineReply` pattern with a timeout. It adds about 1–2 s per read, so the prompt keeps reads to 0–1 per instruction.

## Implementation tasks

1. **Mode-tagged speech.** `KeyboardSession`/`DictationPipeline` carry a mode per segment, driven by the toggle state the keyboard publishes. Dictation segments flow into bundle 1's `live` target. Instruction segments collect into an instruction buffer that's shown in the strip.
   Files: `Sources/LegatoAppServices/{KeyboardSession,DictationPipeline}.swift`, `Sources/LegatoKeyboardCore/Link/` (toggle state in presence).
   Depends on: bundle 1.
2. **Magic toggle UI.** A key for tap-latch and hold-momentary, plus strip states: instruction transcript, running, accept/undo. It takes the place of the surface toggle. Remove `KeyboardSurface.composer` and its view from the keyboard. Reuse `MicKeyMode` patterns.
   Files: `Apps/iOS/KeyboardUI/{KeyboardController,MicKey,…}.swift`, `Apps/iOS/Keyboard/KeyboardRootView.swift`, `Sources/LegatoKeyboardCore/Layout/KeyboardStrip.swift`.
   Depends on: 1 (state contract).
3. **Field reads.** The keyboard implements the self-verifying walk: block reads upward, stopping at structural stops, with the cap and loud failure. It serves `link.read` requests. Pure stitching and stop detection go in core with unit tests.
   Files: `Sources/LegatoKeyboardCore/Input/FieldReader.swift` (+ tests), `Sources/LegatoKeyboardCore/Link/{LinkChannel,…}.swift`, `KeyboardController.swift`.
   Depends on: bundle 1 `RunShadow`. Independent of 1–2.
4. **Instruction runner (app).**
   - Build the prefetch context, the prompt and the `read_more` tool. Parse the `SCOPE` header and stream the rewrite.
   - Map the scope to a shadow range, and publish the target to the keyboard via bundle 1's live snapshot (as a scoped replacement).
   - Write a history entry and support undo.
   - Model choice comes from `composer.liveModel`. Reuse `AgentRunner`/streaming plumbing where it fits, not its line tools.
   Files: new `Sources/LegatoAgent/InstructionRunner.swift` + `Prompts/instruction.md` (+ tests for SCOPE parsing and scope mapping), `Sources/LegatoAppServices/KeyboardSession.swift`.
   Depends on: 1, 3.
5. **Retire the iOS composer path.** Remove the keyboard-side composer intents and publication polling that only the iOS surface used. Keep everything the Mac panel needs. Update `docs/composer.md` and the user-facing settings copy.
   Files: `Sources/LegatoKeyboardCore/Link/{ComposerLink,ComposerPollWatch}.swift` (iOS users only), `Apps/iOS/App/Views/SettingsView.swift`, docs.
   Depends on: 2, 4.

## Checks and environment

- **Unit tests:** `SCOPE` parsing (including malformed headers and an unknown scope, which falls back to no edit), scope → range mapping, structural-stop detection, walk stitching with non-tiling windows, mode tagging. Existing composer tests that the Mac still relies on stay green; tests for removed iOS-only code go along with that code.
- **Gate:** `scripts/ci/test.sh` in the merge queue, plus a local `swift test` and a device build at the end.
- **Device and spend:** as in bundle 1. Live Claude/Soniox spend is approved for agent testing.
- **Evidence gaps:** Mail, Safari and WhatsApp walks were untested in the spike. Report them per host.

## What to tell the UAT agent

The Legato iPhone keyboard has a new magic key: with it on (tap) or held, what you say becomes an instruction for the text in the field ("make this more formal", "turn this into bullet points"), and the field is edited in place, with undo. The separate composer screen is gone. Reach it on Jakob's iPhone with the Legato keyboard in Notes, Messages, Mail, Safari and WhatsApp; without a microphone, use the replay bridge command for speech (`scripts/device/README.md`). Mix dictation and instructions, try a selection, a short note and a long email-like text. Use only notes and drafts you create; never send anything; never edit Jakob's existing content; delete them afterwards. Report what the field showed versus what you expected, with screenshots and diagnostics.

## Open questions for Jakob (before the go)

- Where does the magic key go? Recommended: in place of the current composer/surface switch.
- Should accept/undo stay in the strip until the next keystroke? Or should the change be auto-accepted, with undo shown for a few seconds?
