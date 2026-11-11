# Direct field editing

## iOS: one queue owns the field

Every write the keyboard makes goes through one queue per field (`FieldQueue`). That includes the user's keys, deletes, space-bar cursor pans, word-row and undo edits, live dictation and Soniox revisions, typed lines, the host's text, cleanup and Magic. Nothing else inserts, deletes or moves the cursor, so the queue is the only source of truth for where the cursor is. The one exception is a cursor walk that reads the field for an instruction. It runs only while the queue is paused with nothing in flight and the caret back at the user's cursor.

- **One confirmed op at a time.** The next op goes out only after the field's report confirms the last one. The report must pin the expected cursor in the queue's model of the text, at that place and nowhere else. A report that fits the state before the op as well confirms nothing.
- **Safari timing (measured).** No field puts its caret back after a move. The proxy reports a move before the host has applied it (25–50 ms later), so a move counts only after a report at least 80 ms later. Ops sent close together can land out of order, so no op follows the last one sooner than 50 ms. An edit sent right after a move can leave the proxy on a stale report; an edit that stays unreported gets a zero-offset move that makes the proxy report afresh.
- **Lanes.** User input goes first, behind at most the op in flight. After about 150 ms the op in flight counts as landed and the input goes. Edits come next, then live dictation, with snapshots coalesced to the newest per run.
- **Planning at start.** Each item is planned when it starts, against the model as it is then, so queued work rebases onto the user's moves and typing.
- **Jump units.** A change away from the cursor moves there, deletes and inserts only the differing characters (minimal grapheme diff), then moves back. No other op goes out meanwhile. User input ends a unit early: the caret goes back first, and the rest is planned again later.
- **No freezing.** A report that does not confirm leads to a resync. The queue re-locates the model around the cursor (unique matches only) or takes the report as the new model, then planning goes on. An edit is dropped only when its text can no longer be placed or the user changed it. Drops are reported to the owner: Magic answers the app, which keeps the original and the rewrite in History, and dictation points the user to the take in History. A dictation region that is out of sight waits.
- **Dictation regions.** A live run types at its region's end. A key or a cursor move closes the region, and a word cut short by a key is finished first. Later words start a new region at the user's cursor. Revisions of closed regions still land as jump units while their text is unchanged.

Internal builds journal every queue event with full text (`EditJournal`; see `scripts/device/README.md`). A pulled journal replays against the queue in a test.

## macOS

Dictation and Magic share a field coordinator (`FieldEditCoordinator`). Each field binding has a generation and revision; requests carry the revision they read. Replaced, cancelled and stale work cannot acquire the field for another write. Desired text is the requested result, predicted text is what an issued operation should leave, and observed text is what the host reports. Issuing an operation does not confirm it.

Accessibility edits verify the replacement, caret, surrounding text and document length. Live hypotheses coalesce before reaching the host. Corrections preserve the stable prefix and replace the changing tail, ending at the natural caret without a separate jump over an unchanged suffix. Focus loss or manual input revokes the captured field rather than rebinding a pending result elsewhere.

## Recovery

Before applying a Magic rewrite, Legato saves the original and generated result together in History. The same entry records whether application succeeded, was refused or could not be confirmed. A recovery-save failure prevents the edit from being sent.

History copies the generated result by default. Its context menu offers Copy original for a rewrite. Both versions remain available after a read or write failure, without another successful field walk. Undo is offered only when a known resulting scope can be verified. Explicit instruction retries use a fresh identity and revoke the previous attempt.

## Limits and verification

A keyboard extension cannot obtain the complete text or absolute caret position in every host. Structural boundaries, missing selection information, stale browser proxy windows and text typed by another keyboard can make an edit unverifiable. Such cases resync or drop with a specific status instead of writing at a guessed position.

The package checks cover the queue's contracts (minimal flips, the bound on user input, rebasing, unit integrity, drops) and a seeded stress test. Its fake field lags, shows short windows, echoes Safari's block boundary, moves emoji as one unit and reproduces the measured Safari timing. `LEGATO_STRESS_RUNS` sets a long local run and `LEGATO_STRESS_SEED` replays one seed. Native acceptance uses the real Safari fields and keyboard extension on iOS, and the running desktop app against browser fields on macOS. In-process text fixtures do not establish browser compatibility.
