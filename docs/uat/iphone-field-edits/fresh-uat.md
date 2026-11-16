# Fresh acceptance result

Result: **failed on both platforms** (2026-11-16, product source `7838631`). The PR stays draft. Two fresh agents without implementation context explored live, one or two actions at a time; the conductor reproduced or traced each failure below independently.

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
