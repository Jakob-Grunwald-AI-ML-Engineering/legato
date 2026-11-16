# Fresh acceptance result

Result: **first round failed on both platforms** (2026-11-16, product source `7838631`). After fixes (`b960ed3`) the Mac recheck passed; the iPhone recheck is untested. The PR stays draft. Two fresh agents without implementation context explored live, one or two actions at a time; the conductor reproduced or traced each failure below independently.

## Physical iPhone (real keyboard extension, Safari fields, recorded speech at speed 1)

- **Cleanup deletes letters the user typed during speech.** In four of four runs, keys typed while speech was live appeared in the field and were removed by the end. The edit journal shows the cleanup target itself dropping them (`o`, `l`; `z`, `q`): the field text, including the user's letters, goes to the cleaner and its result is applied. The simulator stress runs use a scripted cleaner that never removes markers, so they could not show this.
- **An aborted cleanup edit loses one dictated letter.** Journal pattern: `move`, `delete 1`, `resync stale`, `reverted`. The caret returns but the deleted character is not restored (`coast.` → `coas.`, `fresh` → `resh`, `bread` → `read`). A later cleanup sometimes repairs it.
- Held: the caret stayed where the tester left it after the take; speech kept pace; text typed before or after a take survived.
- Untested: WhatsApp, Notes, Messages, Mail; send/clear then new draft; History recovery; dictated non-ASCII; measured latency.
- A cleanup paragraph break inside a rich list produced an empty bullet (single sighting).

## Mac guest (offline fixtures, real typing over VNC)

- TextEdit: every promise held, including a 36-character run typed while seven speech lines arrived, caret parking, clearing mid-session and non-ASCII text.
- Safari textarea: held in a healthy session.
- **Safari `contenteditable`: speech does not land.** From a fresh app start the first write lands (`plain ` in an empty field, one space in a prefilled one), the caret check after it fails ("Native edits stopped because the cursor could not be restored.") and the rest goes to the pill's kept text. No user text is lost.
- **One failed field blocks every field.** `NativeInputHandoff` is a process-wide lease; once `blocked`, `begin` refuses for any other field or app until relaunch or a click in the original field. A later session in another field stalls the same way.
- Untested: a cleanup in flight mid-session (the offline stub lands only at stop), microphone, Magic.

## Access notes

The earlier Mac blocker (`hotkeysEnabled=false`) cleared with a plain relaunch after the guest permissions were granted. The phone needed a restarted WDA runner and a new session. Handback: phone on Home, bridge idle/unarmed, VM stopped, WDA runner and fixture server stopped, no simulator booted. Raw journals and screenshots stay private (`fresh-phone-uat`, `fresh-mac-uat`).

## Recheck after fixes (`c915d7f`, `b960ed3`)

Fixes: an aborted cleanup edit is parked, resolved from a fresh field read and followed by one new cleanup pass (iPhone); a failed native edit blocks only its own dictation run (Mac); WebKit's trailing no-break space is accepted by the scoped write check and the read-back (Mac). Letters typed during speech and then removed by cleanup were in the cleaner's input, which is the decided behaviour; no change.

- **Mac guest: passed.** Safari `contenteditable` takes dictation fully (empty, prefilled, multi-line, typing in between, 26 keys typed during the stop cleanup); TextEdit and the textarea still hold; a cleared draft stays cleared; a run that fell back to the pill stays there and the next run writes normally without a relaunch.
- Mac friction left open: Safari autocorrect capitalising a dictated word (`charlie` → `Charlie`) fails the caret check and sends the rest of that run to the pill, where the kept text mixes the raw sentence with a partial cleanup; a stale pill stays on screen until dismissed; the first dictation after Safari launches goes to the pill. Arrow-key caret moves and a pause-triggered cleanup stayed untested.
- **iPhone recheck: letter loss not seen again; one new blocker.** Across Safari, Notes and (after an app relaunch) the WhatsApp self-chat, no settled take had a missing or doubled dictated letter. The retained journal window holds no `stale`/`reverted` sequence, so the new recovery path itself was not observed on the device; it is covered by tests built from the first round's journal.
- **Fixed in `55fdcbd`, not rechecked by a fresh tester: a take stuck in `cleaning`.** A tap into a field that already held text, with the caret not moving, marked the selection as unverified and held all automatic work, so a following take typed nothing and the app waited without end. Speech now types at the caret while the selection is unverified; moves, deletes and edits still wait. Jakob used the build and found it generally good.
- **Open, iPhone: cleanup is slow and can end half-applied.** Measured on Jakob's phone: edit operations 120 ms apart, about 7 s for one 100-character cleanup, and cleanups cut off when the draft was cleared. The plan is `docs/plan/shadow-document-edits.md`.
- Open, iPhone, lower: a burst of several keys within about half a second during speech (faster than hand typing, sent by the test driver) stopped the rest of the take from arriving in four of five tries; a caret tap inside a word while it was being typed split the word and cleanup rewrote the fragment.
