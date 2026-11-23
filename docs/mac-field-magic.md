# Dictation and Magic on Mac

Start dictation with your usual shortcut. The activity opens near the original caret, focused field, or editor window depending on what the app exposes. The draft grows with your speech and scrolls when it reaches the edge of the display.

- **Microphone** pauses or resumes dictation. The filled red microphone shows that Legato is listening.
- **Magic** cleans up the draft when you click it or tap your Magic shortcut (Right ⌘ by default). Click the waveform beside Magic or hold the same shortcut to speak an instruction such as “make this shorter.” Click the stop icon or release the held shortcut to apply it.
- **Insert** (→) sends the draft to the focused editor’s current caret or selection and closes the activity. Short drafts can type in and longer drafts paste in one go. If text is missing from the editor, copy the draft from **History**. Password drafts are private and do not appear in History.
- **Discard** (←) clears the draft and closes the activity. **Undo Discard** is briefly available from the Legato menu bar icon.

Change these bindings in **Settings → Shortcut**. Each activity action shows its current shortcut. The activity owns its shortcuts while interactive and releases them on dismissal.

## Internal offline verification

For credential-free Mac testing, launch an internal Debug build with `-LegatoOfflineFixture YES -LegatoDataRoot /absolute/scratch/path` and a separate `LEGATO_MAC_ROOT`. Use the [internal harness](../scripts/device/README.md) to supply synthetic speech through `dictation-debug-tail` and `dictation-debug-line`. End a take with `dictation-debug-stop`.

Use `composer-state` to inspect the staged draft. The bridge actions `composer-magic`, `composer-insert`, `composer-discard` and `composer-undo-discard` operate on that draft. Exercise the actual controls in the running app to verify keyboard routing, focus, positioning and field delivery. An isolated Mac guest lets you exercise system-wide shortcuts without triggering another running copy of Legato.
