# Direct field editing

Dictation and Magic share a field coordinator on iOS and macOS. Each field binding has a generation and revision; requests carry the revision they read. Replaced, cancelled and stale work cannot acquire the field for another write.

## Field state

Desired text is the requested result. Predicted text is what an issued operation should leave. Observed text is what the host actually reports. Issuing an operation does not confirm it. The coordinator keeps these states separate, and a failed or unconfirmed write prevents further automatic writes until the field is reconciled.

On iOS, observations cover only the windows exposed by the keyboard proxy. Unknown text outside those windows stays unknown. The scoped edit queue verifies each operation and waits across host updates before allowing a matching echo to authorize the next operation. A caret move that the host reverses does not authorize a delete at the guessed position. A failed operation is never repaired by blindly reinserting text at an uncertain caret.

On macOS, one queue per field (`MacFieldQueue`) makes every change: live words and their revisions, cleanup, typed lines, Magic and its undo, and the panel's final typed insert. Nothing else writes to the field.

- **One op in flight.** Each op is planned just before it goes out, against the field as last read: select the spot, replace, then read back the text and caret before the next op.
- **Minimal diff, typed.** Only the differing characters change, one grapheme per op at the typewriter pace. Reduce Motion, the Typewriter setting off, or a flush (Magic reading the field) sends each change whole. A change away from the user's caret is a jump unit: the caret goes back to where the user expects it.
- **Rebase, never freeze.** The user's typing and clicks show on the next read. A key or click closes the open dictation region, and later words start a new region at the user's caret. Regions are found again at their place or uniquely elsewhere, and pending work is replanned there. Only work whose text the user changed, or that cannot be placed, is dropped; the take or result stays in History and goes to the clipboard.
- **Keystroke fields.** Chromium web content (Chrome, Edge, their installed web apps, Electron) exposes its text once Legato reads the application's role, but ignores Accessibility text writes. The queue edits it live with synthetic keys, one in flight, each confirmed by reading the text and selection back: Left/Right arrows without modifiers to move, Backspace to delete, one grapheme per Unicode key to type. A key that does not read back is not sent again until it shows or a second has passed. Line breaks and tabs are pasted, never Return or Tab keys, and the clipboard comes back.
- **Keystroke planning.** As on iOS, a word that changes by half or more is retyped whole, changes a few characters apart merge into one span, and each span takes minimal edits or a block delete and retype, whichever costs less. A change aims at about 1.2 s; typing speeds up with the backlog, still one grapheme per key. Moves and edits settle briefly between each other.
- **Key guards.** Before every key: the bound element is focused in the frontmost app, no real key or click since the key was planned, no modifier held, and the selection is still where it was read. A failed guard sends nothing; the queue reads again and replans. A held modifier (push-to-talk) only pauses it. Every synthetic key-down has its key-up, and a sequence goes out whole or not at all.
- **Panel mode.** Unreadable fields show the take in the notch panel. The queue's only op there is one typed insert with synthetic keys at the end, while the same app is in front and no real key was pressed.

Debug and internal builds journal every queue event with full text in `~/Library/Caches/<bundle id>/edit-journal.jsonl`.

## Recovery

Before applying a Magic rewrite, Legato saves the original and generated result together in History. The same entry records whether application succeeded, was refused or could not be confirmed. A recovery-save failure prevents the edit from being sent.

History copies the generated result by default. Its context menu offers Copy original for a rewrite. Both versions remain available after a read or write failure, without another successful field walk. Undo is offered only when a known resulting scope can be verified; an uncertain result is never retried automatically. Explicit instruction retries use a fresh identity and revoke the previous attempt.

## Limits and verification

A keyboard extension cannot obtain the complete text or absolute caret position in every host. Structural boundaries, missing selection information and stale browser proxy windows can make an edit unverifiable. Such cases stop with a specific status instead of assuming that the user moved the cursor or that nothing changed.

The small package checks cover ownership, cancellation, stale responses, recovery persistence and caret-sensitive edits. On macOS a seeded stress test drives the queue against a fake Accessibility field with lagging reads, user typing and clicks, revisions, cleanup and Magic, and against a fake keystroke field whose keys lag, land late, drop and meet focus blips (`LEGATO_STRESS_RUNS`, `LEGATO_STRESS_SEED`). Native acceptance uses the real Safari fields and keyboard extension on iOS, and the running desktop app against browser fields on macOS. In-process text fixtures do not establish browser compatibility. Offline speech and instruction fixtures establish field behavior, not recognition or model quality.
