# Direct field editing

Dictation and Magic share a field coordinator on iOS and macOS. Each field binding has a generation and revision; requests carry the revision they read. Replaced, cancelled and stale work cannot acquire the field for another write.

## Field state

Desired text is the requested result. Predicted text is what an issued operation should leave. Observed text is what the host actually reports. Issuing an operation does not confirm it. The coordinator keeps these states separate, and a failed or unconfirmed write prevents further automatic writes until the field is reconciled.

On iOS, observations cover only the windows exposed by the keyboard proxy. Unknown text outside those windows stays unknown. The scoped edit queue verifies each operation and waits across host updates before allowing a matching echo to authorize the next operation. A caret move that the host reverses does not authorize a delete at the guessed position. A failed operation is never repaired by blindly reinserting text at an uncertain caret.

On macOS, Accessibility edits verify the replacement, caret, surrounding text and document length. Live hypotheses coalesce before reaching the host. Corrections preserve the stable prefix and replace the changing tail, ending at the natural caret without a separate jump over an unchanged suffix. Focus loss or manual input revokes the captured field rather than rebinding a pending result elsewhere.

## Recovery

Before applying a Magic rewrite, Legato saves the original and generated result together in History. The same entry records whether application succeeded, was refused or could not be confirmed. A recovery-save failure prevents the edit from being sent.

History copies the generated result by default. Its context menu offers Copy original for a rewrite. Both versions remain available after a read or write failure, without another successful field walk. Undo is offered only when a known resulting scope can be verified; an uncertain result is never retried automatically. Explicit instruction retries use a fresh identity and revoke the previous attempt.

## Limits and verification

A keyboard extension cannot obtain the complete text or absolute caret position in every host. Structural boundaries, missing selection information and stale browser proxy windows can make an edit unverifiable. Such cases stop with a specific status instead of assuming that the user moved the cursor or that nothing changed.

The small package checks cover ownership, cancellation, stale responses, recovery persistence and caret-sensitive edits. Native acceptance uses the real Safari fields and keyboard extension on iOS, and the running desktop app against browser fields on macOS. In-process text fixtures do not establish browser compatibility. Offline speech and instruction fixtures establish field behavior, not recognition or model quality.
