# Shadow-document edits: fast chunked field writing

Status: **plan, awaiting Jakob's go.** Written 2026-11-16 at the end of the PR #298 session so a fresh session can execute it. Nothing here is implemented.

## Goal and scope

Dictated text, Soniox revisions and cleanup reach the host field quickly and without mangled edits, on iPhone and Mac, by replacing the "one verified character at a time" contract with a small model:

1. **Shadow document.** One observer keeps an accurate picture of the field at all times, separately from executing edits.
2. **Chunks, not characters.** Speech, a Soniox revision, a cleanup and a user key are each one chunk. The queue schedules chunks and executes one whole chunk at a time.
3. **One place per chunk.** Deletes and inserts at one position go out together at full speed.
4. **Jump only to text the keyboard can see,** then look, adjust by the few characters it is off, and edit.
5. **No fixed waits.** Act on the keyboard's immediate view; check once after the chunk; one deadline for a result that never comes.
6. **A failed check re-reads and runs a fresh cleanup.** No blind restore.
7. **User input wins.** A key waits only for the chunk that is running.

Done when: a cleanup of a normal message lands in well under a second on the phone, hand edits made in pauses survive, and the rule set in `docs/field-editing.md` is these seven plus an explicit list of anything kept.

Excluded: recognition quality, the cleanup prompt, Magic/instruction behaviour beyond moving it onto chunks, meetings, live promotion.

## Decisions and constraints (Jakob, 2026-11-16)

- **Realistic input only.** People edit by hand in pauses (mic possibly on), never while speaking. The realistic overlap is a key pressed right after speech while the last words or a cleanup still land. Keys during active speech only need to be safe. Memory: `legato:realistic-input-during-dictation`.
- **Cleanup may change hand-typed text** only if that text was in the cleanup's input; text typed after the read cancels that result and a new pass follows. This already holds (`FieldQueue.placeThroughRead`); keep it.
- **Cleanup should find its way in between dictation:** per sentence, in gaps between words, not only at stop. Edits are targeted (delete and insert only what changes); remembering what was typed and making jumps combine.
- **The observer reconciles breaks.** A window that is suddenly empty, wholly different, or elsewhere is noticed. It stitches when it can (short paste, jump to known text) and otherwise marks a seam (unknown region). An edit that would touch text across a seam first explores with jumps and looks.
- **Mac block scope** is the dictation run (done in #298). **Kept text on iPhone** should be reachable in the keyboard like the Mac pill (task 8).
- Recorded host behaviour the design must respect (`git log`, `docs/field-editing.md`):
  - Safari answered a batch of moves, deletes and inserts only when all had run, and operations sent close together landed out of order (`8e8de01`, `f7161fb`). Deletes and inserts of one kind land in order.
  - The proxy shows a move at once; the host applies it 25–50 ms later; an edit up to about 110 ms later (Safari).
  - A page that re-renders its textarea puts the caret back after a move (`95e9691`).
  - Emptying a line in a rich editor drops its list item or leaves a placeholder break (`1580283`): keep the line's last old grapheme until the new text is in.
  - Chromium on Mac ignores AX writes and recreates elements; it is keyed (`6cec010`).

## Owners and measurements

Build on these; add no parallel writer.

| Fact | Owner today | Plan |
|---|---|---|
| iPhone model of the field (`text`, `cursor`, `userCursor`, `spans`; `seed`, `merge`, `reseed`, `restore`) | `FieldQueue` (`Sources/LegatoKeyboardCore/Input/FieldQueue.swift`) | Extract into a `ShadowDocument` type first; the queue and the observer both use it |
| Reading the proxy (`Report`) | `KeyboardController.currentReport`, `ProxyDocument` | The observer feeds every callback into the shadow, idle or not |
| Diff to hunks | `ShadowEditPlanner`, `SpanPlanner` (`mergeGap` 3) | One hunk = one chunk |
| One in flight, confirm | `FieldEditCoordinator.Operations` | One chunk in flight |
| Rebase around user changes | `FieldMerge.rebase`, `placeThroughRead` | Unchanged |
| Looking around | `FieldReader` (self-verifying walk) | Used only to explore across a seam |
| Ops | `ShadowOp`; `KeyboardController.dispatch` (delete n = n single calls) | Unchanged API; a chunk is a short op list sent back to back |
| Mac read, plan, write | `MacFieldQueue.read` (whole value each step), `NativeEditPlan`, `TextTarget` | Hunk granularity, unpaced; the fresh read is the shadow |
| Journal and rigs | `EditJournal`, `JournalReplay`, `FakeField`, `QueueRig` | Journal chunks; extend `FakeField` with measured host behaviour |

**Measure first, on Jakob's iPhone, per host (WhatsApp self-chat, Notes, Safari textarea and contenteditable), with the raw probe (`scripts/device/keyboard-probe.md`):**

1. Delay from a move, a delete run and an insert to the host callback (`textDidChange` / `selectionDidChange`), and whether a callback arrives for each.
2. Whether n back-to-back `deleteBackward` calls all land.
3. Failure rate of jump → delete run → insert at full speed (no waits), judged by a read afterwards.
4. Visible window size before and after the caret.
5. How far a move of n lands from n (emoji, line breaks).

Baseline already measured on the phone (2026-11-16, build `55fdcbd`): edit-lane ops 120 ms apart; one 790→690 character cleanup spent about 7 s on 60 single deletes; model wait 1–1.5 s; two long jumps mislanded in WhatsApp. Window size 65–120 characters is from 2026-11-08 (`legato:streaming-dictation-spike-findings`). Everything else above is unmeasured.

On Mac, measure how long the user's keys are held during one hunk write in TextEdit and Safari before fixing chunk size.

## Implementation tasks

1. **Measure** (above). Record results in `docs/field-editing.md`. If full speed fails often in one host, that host gets the callback wait between jump and edit; say so there.
2. **Extract `ShadowDocument`** from `FieldQueue` with no behaviour change; existing tests stay green.
3. **Observer.** Every proxy callback updates the shadow, including while idle. Classify each observation: matches, extends, stitches (found elsewhere in the shadow), or seam. Replace the unverified-selection hold with this.
4. **Chunk executor (iPhone).** A chunk = optional hops within sight, one delete run, one insert, return to the user's caret; sent without settle waits; one check after; deadline then re-read. Speech append and tail edits need no hop.
5. **Chunk planning.** Soniox revision and cleanup become hunks via `SpanPlanner`; hunks that reach the caret are rewritten from the caret. Keep the rich-editor last-grapheme rule.
6. **Per-sentence cleanup during dictation** on iPhone: request when a unit ends, with the previous sentence as context; apply in the next gap. Keep the final pass at stop.
7. **Mac.** `NativeEditPlan` steps per hunk; drop pacing for automatic edits; fresh read before each chunk; keyed (Chromium) fields keep verified keys.
8. **Kept text in the word row (iPhone).** Load `ui:collaborative-ui-design`; show Jakob a mock before building. Insert and Copy, like the Mac pill.
9. **Check draft-cleared detection** (`observeDraftBoundary`): one clear fired in the same instant as a move to the start of the text. Diagnose with the journal; fix only if real.
10. **Remove what the model replaces** and list anything kept, with its reason, in `docs/field-editing.md`: fixed settle constants, per-grapheme pacing of edits, `deleteConfirmationMs = transitMs`, stale-nudge and lag heuristics, parked spans and recovery, the keys-wait-for-take hold. Confirm each against the tests before deleting.

Depends on: 1 → 4, 5; 2 → 3, 4. Tasks 7, 8, 9 are independent.

## Checks and environment

- Small unit tests on the contracts: observer classification (match, stitch, seam), chunk planning for tail and mid-text hunks, a failed check leading to a re-read, user key ordering around a chunk. Replays of the device journals in `~/Library/Caches/legato/iphone-field-edits/` are good fixtures (they hold synthetic text only in `fresh-phone-uat` and `recheck-phone-uat`; `user-session` holds Jakob's real dictation and stays private).
- The seeded stress suites assert the old contract in places. Keep them as a no-corruption check; changing or trimming them is a deliberate step to agree with Jakob.
- `bash scripts/ci/test.sh` on the final candidate before enqueueing (repo rule).
- **Phone rules.** Ask whether the phone is free before taking it. Bridge speech commands type into whatever field has focus: verify the foreground app and the "Message yourself" header immediately before each one and abort the whole run on failure (`legato:phone-replay-types-into-focused-field`). Hand back visibly (Home, mic released). The WDA runner needs Jakob's passcode when iOS shows "Enable UI Automation".
- **Mac VM** (`scripts/device/mac-vm.md`): stopped. Each new ad-hoc build needs Accessibility re-granted in guest Settings, then a relaunch.

## What to tell the UAT agent

Dictation with cleanup should now feel immediate: a cleaned sentence replaces the raw one within about a second, while the person keeps talking. Behave like someone dictating a message: speak, pause, press Enter or fix a word, tap somewhere and speak again, send, start a new draft. Do not interleave keys with speech. Hosts: WhatsApp self-chat only, Notes, Safari fields; on Mac TextEdit and Safari in the VM. Report anything slow, any text that ends up wrong, and anything of the person's that is lost.

## State handed over

- Branch `feat/iphone-field-edits`, draft PR #298. Build `55fdcbd` is on the phone (speech types while the selection is unverified; trace of queue holds in the edit journal). Jakob finds it generally good but cleanup slow and some edits wrong, which this plan addresses.
- Not verified on the device: the aborted-delete recovery path (`c915d7f`), which is covered by tests built from a device journal.
- Open in #298, lower priority: Safari autocorrect on a dictated word sends that Mac run to the pill; a stale Mac pill stays until dismissed; the Mac gets no automatic re-pass after an unplaceable cleanup; after a real Select All the dictated text starts with a space and a lowercase letter.
- **Open question for Jakob:** land #298 first and build this on a new branch on top (recommended), or fold it into #298.
