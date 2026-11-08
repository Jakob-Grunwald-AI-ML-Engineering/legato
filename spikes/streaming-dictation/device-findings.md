# Streaming dictation: shadow-document spike, device findings

All numbers below are from Jakob's iPhone 17 (physical, debug build, Legato keyboard in the host). Pure-planner unit tests (macOS, `swift test --filter ShadowEditTests`) are separate and only cover the function.

Status: PARTIAL. Notes (short and long) and Messages (short) are measured. Messages long, Mail, Safari textarea and WhatsApp are not: the phone dropped off devicectl ("unavailable") during the Messages 5,000-char run, so I stopped (no retry loop).

## What was built (debug only, `#if DEBUG`)
- `Sources/LegatoKeyboardCore/Input/ShadowEdit.swift`: `ShadowEditPlanner.plan(shadow:cursor:target:)` and `simulate`. Token LCS (words, whitespace runs, single punctuation), hunks applied back-to-front, UTF-16 moves, Character deletes, logical cursor mapping.
- `Tests/LegatoKeyboardCoreTests/ShadowEditTests.swift`: 6 tests.
- `Apps/iOS/Keyboard/ShadowSpike.swift` + hooks in `KeyboardViewController.swift`: polls `Library/Caches/shadow-cmd.json` in the App Group every 500 ms while the keyboard is visible. Commands `ping`, `type`, `walk` (two walks), `replay` (`fill`, `cursor` end|mid, `pace` none|settle). Output `Library/Caches/shadow-spike.jsonl`. Trigger is `devicectl device copy to` (works; the keyboard consumed commands within seconds). Nothing here ships in Release.

## Field mirror (walk)
Method: step back by the size of `documentContextBeforeInput` until it is empty (probe -1 to confirm the start), then forward by the size of `documentContextAfterInput`, appending; return to the start offset. Contexts update asynchronously; polling the proxy until the pair changes and holds still for 3 polls (6 ms each) works.

| Host | Field | Walk time | Steps back/fwd | Largest windows (before/after) | Fidelity |
| --- | --- | --- | --- | --- | --- |
| Notes | 13 chars | 1.2 s | 2/2 | 13/12 | exact |
| Notes | 147 chars | 1.3 s | 3/5 | 87/65 | exact |
| Notes | 5,324 chars (blank-line paragraphs, accents, emoji) | 8.0-8.3 s | 74-78/131-132 | 118 (547 once, after a cursor jump)/73 | exact |
| Messages (new-message body, no recipient) | 0-141 chars | 1.0-1.3 s | 1-3/3-4 | 134/65 | exact |

- Fidelity means: stitched text equals the typed text (hash and diff), zero stitch mismatches (the window before the cursor always matched the end of the text so far), the original offset matched the initial windows, and the cursor returned exactly. Two consecutive walks agreed on text and offset (Notes, verified by `walk-agree`).
- Windows are small and ragged: about 65-120 chars, often cut at sentence or line boundaries, one outlier of 547. So a walk costs roughly 1 step per 40 chars, and time scales with length. About 1.5 ms/char for the long Notes field; the fixed ~1 s floor in short fields is the two end-probe timeouts of 500 ms each (an end probe waits out the timeout because nothing changes). That floor can be removed by detecting the ends differently.
- The unit of `adjustTextPosition(byCharacterOffset:)` is UTF-16 units: text with an emoji and an accented letter stitched exactly.
- Quirk: the window content depends on how the cursor arrived, so "the windows equal the initial windows" is too strict a cursor check (it flagged `cursorExact:false` for the first walk after typing). The absolute offset check is the right one, and it held.
- Selection: all runs had a collapsed cursor; `selectedText` empty before and after. A real selection is collapsed by the walk (not tested here; the API cannot restore a range).

## Applier on device
Script: type a 134-147 char sentence in 5-char chunks every 15 ms (~0.44 s), then apply, one at a time with a re-walk after each: flip a word mid-text, flip a word in an earlier sentence, insert a word, remove a word, comma, period to "!", append ".". Then undo all of them back-to-back with no reads in between (drift check) and walk once.
- Notes short, no pacing: 7/7 steps and the 22-op undo-all, text and cursor equal.
- Notes long (+5,000 chars), no pacing: 8/8 incl. flipping "Alpha marker" at offset 0 with the cursor ~5,300 chars away (one move op), and 29-op undo-all, text and cursor equal. Apply time 16-19 ms per revision, 64 ms for the undo-all.
- Notes long, cursor parked at offset ~80 (far from the end), `pace=settle`: 7/7 plus 25-op undo-all; the cursor stayed at its logical place (80-82). Apply time 86-148 ms per revision, 824 ms for undo-all.
- Messages short, no pacing: 7/7 and 22-op undo-all, equal.
- No mismatches were logged anywhere. The applier's offline `simulate` agreed with the device in every step.
- Edits with no pause between `adjustTextPosition` and `deleteBackward` or `insertText` were applied in order; the proxy serialises them.

## Not measured
- Messages long field (run was in flight when the phone went unavailable), Mail draft, Safari textarea, WhatsApp draft. Suspect risks there: web views and Mail's rich text may expose different context windows; WhatsApp may cap or reset the context.
- Hosts that return nil/empty context (some secure fields, some web editors).
- A real user selection, simultaneous user typing during an apply, IME marked text.
- Walks while a dictation is live.

## Debug-only
Everything in `ShadowSpike.swift` and its three hooks. The planner in LegatoKeyboardCore is plain code (no UIKit) and would be kept.

## Recommendation (provisional, Notes and short Messages only)
Viable with fallbacks. The core idea works on device: the minimal word-level edit plan applied to a tracked shadow produced exact fields with correct cursor after 7-8 revisions and a 22-29 op batch with no reads. What decides production use:
1. Do not re-walk per revision: a full walk of a long field costs seconds. Take one walk at dictation start (or only a bounded window around the cursor; the hunks near the tail only need the last ~1-2 windows) and keep the shadow from our own edits.
2. Detect drift cheaply: compare `documentContextBeforeInput` with the shadow's tail on every `textDidChange`/`selectionDidChange`; on a mismatch, stop editing earlier text, fall back to the existing tail-only `ProxyEditPlanner`, and optionally re-walk when idle.
3. Fall back to the current planner for hosts with empty or capped contexts.
4. Before committing, finish Mail, Safari, WhatsApp and a live-dictation run.

## Sketch: wiring into live dictation (not built)
Raw STT goes in immediately via `insertText` and is appended to `shadow`. When tokens revise (volatile or newly final), build `target = shadow` with the span replaced, call `plan(shadow:cursor:target:)`, execute ops, and set `shadow = target`, `cursor = plan.cursor`. Own edits are tagged so `textDidChange` from them is ignored; any other change triggers the drift check in point 2.

## Scratch state left on the phone (could not clean: device unavailable)
- Notes: a new note starting "Legato spike" with the replay text (Notes, today).
- Messages: an unsent "New Message" draft with no recipient containing replay text, and possibly ~5,000 chars of filler if the long run was still typing. Nothing was sent. Close it with the X and "Delete Draft".
- Legato debug build (with the spike) is installed on the phone, replacing the previous build.
