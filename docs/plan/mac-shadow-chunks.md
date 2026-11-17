# Mac shadow document, chunked edits and the typewriter entrance (#301, #300)

Status: **planned 2026-11-17, branch `feat/mac-shadow-chunks`.**

Round 2 (Mac), 2026-11-18: planning from the shadow with a notification wake, shadow-based cleanup placement through changes since (`FieldMerge`), per-key readability probe in bursts, LRU field memory done in code and unit tests; the Edge CodeMirror journals are fixtures and replay green through the existing hidden-break reader. Still open: a `<ul>` marker list fake, reproducing the list-editor drop faithfully (unverified on Edge), VM acceptance not run.

## Goal and scope

Bring the Mac field queue to the iPhone's edit model (#299, `docs/field-editing.md` "The edit model") and give chunks on both platforms a fast typewriter entrance.

Done when (#301, #300):
- Measured in the Mac VM (TextEdit, Safari, a Chromium app): edit latency, how long user keys are held during a hunk write, AX read cost, AX notification availability and latency.
- The Mac keeps a shadow of the field fed by AX notifications; chunks are checked once, not key by key.
- Host behaviour (AX vs keyed, latency) is learned per field; the deadline adapts.
- Mac cleanup runs from the shadow, per sentence during the take, with the whole-take pass (stop, 3 s pause) using raw words, as on iPhone.
- Dictation in a Chromium field never pauses visibly while speaking.
- Cleanup lands in list-style editors (today: caret move fails, recovery refused `changedOrAmbiguous`, cleanup dropped `userChanged`).
- Live speech, revisions and cleanup chunks enter as a very fast character burst on iPhone and Mac; each chunk stays one queue unit with one check; the caret jump to a chunk's place happens in one go (not animated).

Excluded: recognition quality, the cleanup prompt beyond what the Mac attach needs, Magic behaviour beyond running on chunks, meetings, the iPhone word-row kept text, live promotion.

## Decisions (Jakob, 2026-11-17)

1. Measurement and UAT on the Mac run in the VM (`scripts/device/mac-vm.md`). If its readiness cannot be repaired without Jakob, stop and ask before using the host desktop.
2. Per-sentence cleanup on the Mac: yes. Mac and iPhone attach cleanup the same way (`perSentence`, shadow ask, whole-take pass with raw words).
3. Typewriter entrance for every chunk (speech, revisions, cleanup) on both platforms, "really fast", with the jump in one go. One shared owner; total burst capped (target ~250 ms, an estimate until tuned) so a key never waits more than the 500 ms interruption budget. Reduce Motion or a flush: whole insert.
4. The Mac keeps a whole-field shadow (its AX read is the whole field), not the iPhone's windowed `ShadowDocument`. Shared: the observation idea (matches / user change / unknown), `SpanPlanner`, `FieldMerge`, the latency learner. Kept difference, recorded in `docs/field-editing.md`: windowed proxy vs whole-field AX.
5. One latency learner: the latency/deadline core of `HostProfile` becomes a shared `HostLatency` in `LegatoKeyboardCore`; iPhone and Mac use it. Window and callback pattern stay iPhone-only.
6. Keyed (Chromium/Electron) fields: a chunk's keys go out back to back, each through the key guards, checked once by value at the end within the learned deadline. A field whose burst checks fail twice falls back to verified keys (learned per field).

## Owners

| Fact | Owner | Plan |
|---|---|---|
| Per-field latency, deadline, back-off | `HostProfile` (iPhone) | Extract `HostLatency`; iPhone and Mac use it |
| Diff → hunks | `SpanPlanner`, `FieldEditCoordinator.changes` | Unchanged; Mac `NativeEditPlan` / `KeystrokePlanner` keep building on it |
| Typing pace | `SpanPlanner.macPaceMs` + constants repeated in `KeystrokePlanner` | Replaced by `ChunkEntrance` (shared); remove the repeats |
| Mac field picture | `MacFieldQueue.read` → `Document` every step | `MacFieldShadow` fed by `AXObserver` (value, selection) on `TextTarget`; poll fallback learned per field |
| Rebase through changes since a read | `FieldMerge`, iPhone `placeThroughRead` | Mac gets the same placement for shadow-based cleanup |
| Cleanup attach | `DictationPipeline.attachCleanupField`, `FieldCleanupSession` | Mac attaches like iPhone (`perSentence`, shadow ask) |
| Recovery | `FieldRecovery` | Journal the exact refusal (`changed`, `ambiguous`, `uncorroborated`, `cancelled`) |

## Tasks

0. **Measure (VM).** Bring the VM to readiness; a committed probe `scripts/device/mac-ax-probe` (one README line) measures for the focused field: AX read cost vs length, value/selection notification arrival and latency after an AX write and after a key, hunk write latency, key hold during a hunk. Hosts: TextEdit, Safari textarea and contenteditable, Edge (incl. a list editor). Results → `docs/field-editing.md`.
1. **`HostLatency`** extracted from `HostProfile`; iPhone moved onto it; no behaviour change.
2. **Mac shadow and observer** on `TextTarget`/`AXTextTarget`; `step()` plans from the shadow, reads only to check its own writes or where notifications are missing.
3. **Mac chunk executor**: native one replace per hunk, one check; keyed bursts (decision 6); learned deadlines replace `keyConfirm`, `waitTick`, `placeGrace` where the shadow makes them unnecessary; kept constants listed with reasons.
4. **Mac cleanup from the shadow** (decision 2).
5. **List editors**: reproduce with a fake list editor that re-renders items and placeholder breaks (and a real Edge journal from task 0 if obtained); split the refusal reason; fix caret moves across hidden breaks and recovery context.
6. **`ChunkEntrance`** (#300): iPhone `FieldQueue` chunk insert as a burst inside one in-flight chunk; Mac native and keyed paths; old pacing removed.
7. **Docs**: `docs/field-editing.md` rules for both platforms, kept list, measurements.

Order: 0 ∥ (1, 6-iPhone) → 2 → 3 → 4 → 5 → 6-Mac → 7.

## Checks

Small unit tests: `HostLatency`, Mac shadow observation, keyed burst check and fallback, `ChunkEntrance` splitting and cap, list-editor fake. Existing seeded stress suites stay as no-corruption checks. Full `scripts/ci/test.sh` before enqueueing.

## What to tell the UAT agent

On the Mac, dictation types without visible stalls in Chrome/Edge fields; cleaned sentences replace raw ones about a second after each sentence while the person keeps talking; cleanup also lands in bulleted and numbered lists. On both platforms words arrive as a quick typing burst rather than blocks. Behave like someone dictating a message or a list: speak, pause, fix a word, speak again. Hosts: TextEdit, Safari, Edge/Chrome incl. a list editor (Mac VM); Notes and WhatsApp self-chat (iPhone, only when Jakob says the phone is free). Report stalls, slowness, wrong text, and anything of the user's that is lost.
