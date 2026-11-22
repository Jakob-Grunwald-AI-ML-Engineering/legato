# Dictation and Magic on Mac

Place the cursor where the finished text belongs and start dictation with your usual shortcut. The composer opens near the caret, or near the destination window when the app cannot report the caret's position. You can stop speaking, read the draft, and dictate more.

- **Magic** cleans up the whole current draft when you click it or tap your Magic shortcut (Right ⌘ by default). Watch the revision in the composer. Hold the same shortcut to speak an instruction such as “make this shorter”, then release it to apply the instruction.
- **Insert** (⌘→) puts the draft into its destination. If Legato cannot confirm delivery, the draft stays available to copy. Check the destination before pasting to avoid duplicating text.
- **Discard** (⌘←) clears the draft. **Undo Discard** (⌘Z) restores it while Undo is visible.

Change these bindings in **Settings → Shortcut**. Each composer action shows its current shortcut. Composer chords belong to the focused app whenever their corresponding action is unavailable.

## Internal offline verification

For credential-free Mac testing, launch an internal Debug build with `-LegatoOfflineFixture YES -LegatoDataRoot /absolute/scratch/path` and a separate `LEGATO_MAC_ROOT`. Use the [internal harness](../scripts/device/README.md) to supply synthetic speech through `dictation-debug-tail` and `dictation-debug-line`. End a take with `dictation-debug-stop`.

Use `composer-state` to inspect the staged draft. The bridge actions `composer-magic`, `composer-insert`, `composer-discard` and `composer-undo-discard` operate on that draft. Exercise the actual controls in the running app to verify keyboard routing, focus, positioning and field delivery. An isolated Mac guest lets you exercise system-wide shortcuts without triggering another running copy of Legato.
