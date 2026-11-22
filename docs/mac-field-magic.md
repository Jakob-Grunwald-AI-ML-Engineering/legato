# Dictation and Magic on Mac

Place the cursor where the finished text belongs and start dictation with your usual shortcut. The composer opens near the caret, or near the destination window when the app cannot report the caret's position. You can stop speaking, read the draft, and dictate more.

- **Magic** cleans up the whole current draft when you click it. Watch the revision in the composer. To request a particular change, speak a Magic instruction such as “make this shorter”.
- **Insert** puts the draft into its destination. If Legato cannot confirm delivery, the draft stays available to copy. Check the destination before pasting to avoid duplicating text.
- **Discard** clears the draft. Use **Undo** to bring back a draft you cleared by mistake.

## Internal offline verification

For credential-free Mac testing, launch an internal Debug build with `-LegatoOfflineFixture YES -LegatoDataRoot /absolute/scratch/path` and a separate `LEGATO_MAC_ROOT`. Use the [internal harness](../scripts/device/README.md) to supply synthetic speech through `dictation-debug-tail` and `dictation-debug-line`. End a take with `dictation-debug-stop`.

Use `composer-state` to inspect the staged draft. The bridge actions `composer-magic`, `composer-insert`, `composer-discard` and `composer-undo-discard` operate on that draft. Exercise the actual controls in the running app to verify keyboard routing, focus, positioning and field delivery. An isolated Mac guest lets you exercise system-wide shortcuts without triggering another running copy of Legato.
