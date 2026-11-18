# iPhone staged dictation (#312, with #300, #293, #278 on iPhone)

Status: **implemented 2026-11-18 on `feat/ios-staged-dictation` (cut from #311, `0afc884`, so #311's work lands with this one); not yet run on the phone.** Package tests and the iOS build passed locally; agent UAT on the iPhone and the device numbers below are open. See "Implementation notes".

## Goal and scope

During the final iPhone test of #311, live dictation into the host field ran smoothly. Cleanup then edited text that was already typed, which made the caret jump and removed text. On iPhone, dictation therefore moves to staged delivery:

- Live speech appears only in the keyboard, in a stable, left-aligned, two-line preview.
- Each cleaned segment enters the host field once, at the caret, with the typewriter entrance (`ChunkEntrance`, one piece per 60 Hz frame).
- A segment that has entered the field leaves the preview.
- A pause or stop flushes what remains.
- Delivery never edits text that is already in the field. Undelivered speech stays recoverable if the field changes or delivery stops.

Done when:
- #312: all three Done-when items in the issue are met.
- #300: the entrance has been looked at on the phone, through staged segments.
- #293 (iPhone): the pause flush uses the admitted pause (`DictationActivity`, endpoint plus 200 ms at -55 dBFS or below), and its responsiveness has been checked on the phone.
- #278 (iPhone): when the proxy context is stale, empty or contradicts what this take delivered, the separator follows the take's own delivery record. If neither source is known, the separator is left off rather than guessed. A changed field holds the text instead of inserting blind.

Excluded:
- Mac: its field queue and cleanup are unchanged.
- Buffered send modes (`onStop`, `afterPause`).
- Magic, including #260.
- The cleanup prompt.
- Meetings.
- Promotion to `live`.

## Decisions

1. **Segment = cleanup unit.** The producer on iPhone becomes the `LiveDictationRun` unit pipeline (`submitLive`/`landLive`/`setCleaned`, units close at sentence end with at least 6 words, a line break or 40 words). iPhone no longer attaches the field-pass cleanup (`attachCleanupField`, shadow ask). The Mac keeps it.
2. **Pause and stop close the open unit.** An admitted pause or stop closes the open unit early, whatever its length, and cleans it. A unit whose cleanup fails or exceeds its deadline is delivered as raw text: cleanup only tidies, so raw is a valid result. History records which of the two was delivered.
3. **Delivery uses the queue.** Each segment is one `FieldQueue.Edit(atCursor: true)` unit: one entrance burst, one check, `FieldInsertion` spacing, and one `EditHistory` undo step per segment. User keys keep priority as today. Segments are delivered in order and never reordered.
4. **No raw text in the field on iPhone live mode.** On the iPhone live-mode path, the raw `Piece` typing, revisions, stop swap and #311's in-place cleanup plumbing (`projectedCleanupDocument`, `EditIntent`, `CleanupReplacement`, `restrictingCleanup` and the shadow ask) become unused. Remove whatever is iPhone-only and now dead. Keep shared code the Mac still uses. Keep #311's `KeptText` identity, verified Insert, draft-boundary evidence and `cleanupRecoveryText`.
5. **Recovery.** If the field changes under delivery, the draft is cleared, the keyboard closes, or an insert fails its check, the remaining segments (cleaned where available, otherwise raw) go to the `KeptText` row. Nothing is inserted blind. History always holds the whole take.
6. **Preview.**
   - It lives in `WordRowView` while a take is active: left aligned, two lines, tail-anchored so the newest words stay visible.
   - It is stable: the text grows at the end and does not re-centre or jump.
   - It shows the undelivered segments followed by the live head. Cleaned text replaces raw text in place once a segment's cleanup arrives.
   - One controller property derives it. `dictatingStatus` and the take display are not a second derivation; fold them into the same owner.
   - Height: 27 pt portrait does not fit two 13 pt lines. Measure on the phone and choose the smallest change that fits two lines. Prefer a modest permanent word-row growth or a smaller font over resizing the keyboard mid-take.
   - The compact strip must not shrink (memory: compact keyboard always available). Record the chosen numbers here.
7. **Docs.** `docs/field-editing.md` states the staged iPhone contract and moves the replaced iPhone live-typing rules to history or deletes them.

## Owners

| Fact | Owner | Plan |
|---|---|---|
| Cleaned segments | `LiveDictationRun` units, `DictationPipeline.submitLive`/`setCleaned` | iPhone producer. Add the pause-closes-unit rule here. |
| Pause | `DictationActivity` → `DictationPipeline.boundary` | Reuse as is |
| Link | `LiveDictationSnapshot`, `LiveDictationAck` | Carry cleaned/final per segment (exists). The ack marks delivered segments. |
| Insert with entrance | `FieldQueue.Edit(atCursor:)`, `ChunkEntrance`, `FieldInsertion` | Reuse. No new insert path. |
| Spacing | `FieldInsertion` vs `LiveSegment.joined` | One owner for the join between segments; move the other onto it |
| Preview text | new single controller property | Replaces live-mode `dictatingStatus` for live mode |
| Recovery | `KeptText`/`KeptTextStore`, `Drop.kept`, History | Reuse |

## Tasks (one implementer, in order)

1. Producer: the iPhone live path moves to units, with pause/stop close, the raw fallback and History.
2. Link and keyboard intake: split the snapshot into preview text and segments ready to deliver. Deliver in order through the queue. Ack delivered segments.
3. Recovery and stale context (#278): hold and keep the rest as described in decision 5; the separator comes from the take's record.
4. Preview UI and height measurement.
5. Remove dead iPhone-only live-typing and in-place-cleanup code (decision 4).
6. Docs: `docs/field-editing.md`, plus this plan's status and measured numbers.

## Checks

- Small unit tests:
  - unit closing on pause and stop
  - raw fallback on cleanup failure
  - snapshot → preview/segments split
  - in-order delivery and ack
  - hold to `KeptText` on a field change
  - separator from the take record when the context is stale
- Existing stress and replay suites stay as no-corruption checks. Tests for removed behaviour go with the code. No other test is weakened.
- Full `scripts/ci/test.sh` once, on the final candidate.
- A signed Debug build installed on Jakob's iPhone (`MEASURE_TEAM=XWSGN23W75`).

## Note for the UAT agent

**What changes:** on iPhone, dictating with the Legato keyboard no longer types raw words into the app. The words show in a two-line preview in the keyboard. Tidied sentences then type themselves into the field, one after another, with a quick typewriter effect, and leave the preview. Pausing or stopping sends the rest.

**What to try:** existing text around the caret must survive. Editing the field in a pause must not lose anything. Words that couldn't be delivered must be offered back.

**How to reach it:** use the Legato keyboard in Messages, Notes, Mail and Safari on Jakob's iPhone, through the device-measure harness (Appium cannot see the iOS 26 phone).

**Limits:**
- Ask Jakob before taking the phone, and hand it back visibly (CLAUDE.md).
- Live Soniox and Claude calls are approved at test size.
- Check the installed build timestamp before trusting a round.

## Implementation notes (2026-11-18)

Built as planned, with these choices where the plan left room:

- **Owners.** `LiveDictationRun(staged:)` (producer units, `LiveSegment.ready`, `setRaw`), `StagedDictation` (keyboard-side preview, next unit, record, recovery; `LegatoKeyboardCore/Link`), `KeyboardController.dictationPreview` (the single preview/status derivation; replaces `dictatingStatus`). Delivery is `FieldQueue.Edit(atCursor:, requiresVerifiedInsertion:)`; no new insert path.
- **Spacing owner.** `FieldInsertion.separator` is the one rule; `LiveSegment.spaced` delegates to it. The em dash joined `FieldInsertion`'s closing marks, so the Mac panel no longer puts a space before a leading em dash either.
- **Pause-close rule.** `DictationPipeline.boundary("endpoint")` (already the admitted pause: endpoint plus 200 ms at -55 dBFS or below) closes the open unit with `LiveDictationRun.flush()` and cleans it at once. Stop does the same in `endLive`. Forced-split words are not closed by a pause (they wait in the head). No new pause constant.
- **Raw fallback.** `liveTimeout` (6 s) bounds a unit's cleanup; the existing line pipeline returns raw on failure or timeout and `landLive` marks the unit ready as raw (`setRaw`). Delivery is in order, so one slow unit holds the later ones up to that bound.
- **Hold rule.** Any dropped segment insert, a cleared draft, a hidden keyboard or a field change after typing stops delivery; the in-flight unit (it may not have landed) and the rest go to the kept-text row from the draft they came from; later-ready units join it. A take that typed nothing yet follows the user into another field.
- **Stale context (#278).** The proxy's context is used while it ends with the last 12 characters this take typed (or nothing was typed yet); otherwise the take's record. Nothing known: no separator.
- **Preview height (ESTIMATE, not measured).** The row keeps 27 pt portrait / 44 pt landscape: it must not grow (it matches the native prediction frame) and the compact strip must not shrink. The preview font is the largest of 13, 12, 11 pt whose two lines at 1.2 x size fit: 11 pt portrait (26.4 pt of 27), 13 pt landscape. A real 11 pt line may be 13.1 pt; to measure on the phone: whether two lines clip, legibility, and whether the bottom-anchored text shows partial top lines.
- **Removed.** The iPhone keyboard's shadow answer (`answerShadowAsk`, `LinkClient.writeFieldShadow`, `link.dictation.shadow`, `LiveDictationLink.send/takeShadow/clearShadow`), the iPhone's `attachCleanupField` call, `dictatingStatus`.
- **Not removed (open).** The queue's in-place cleanup internals (`FieldQueue.shadow(of:)`, `ShadowDocument.EditIntent`/`CleanupReplacement`, `FieldMerge.restrictingCleanup`, scoped `requiresShadowRead` edits) and the pipeline's `waitsForLiveDelivery`: they are tangled with the run machinery, Magic's scoped edits, the recorded-journal replays and `FieldCleanupTests`; the buffered send modes still use the raw `Piece` path. Removing them means re-recording the journal fixtures; do it as its own change.
- **Device numbers still to take** (`ui:device-measure`): the longest keyboard lock during a take, entrance feel per unit, pause-flush latency (#293), preview legibility at 11 pt.
