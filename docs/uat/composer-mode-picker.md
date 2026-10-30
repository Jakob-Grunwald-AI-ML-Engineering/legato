# Keyboard mode picker and two heights

Tapping the Mode key immediately opens the keyboard's own four-row icon/name list. Its opaque native key surface and curved stem join the Mode key; the current mode has a checkmark. Selecting a row changes the mode and closes the popup. Tapping elsewhere dismisses it. The bounded list scrolls when more items are added; it does not change keyboard height.

The only heights are Medium (243 pt owned content in portrait) and Full (approximately 85% of the complete screen including the native tray). Taps toggle the two heights; vertical swipes clamp at those endpoints. Previously stored `low` values restore as Medium. Insert now uses the paper-plane glyph while retaining its Insert accessibility label and field-insertion action.

Physical iPhone 17 UAT, 2026-10-30:

- **Full:** one native tap opened the popup; all four rows were hittable; selecting Email closed the popup and updated the keyboard's mode key.
- **Medium:** the same one-tap flow displayed all four rows without clipping; selecting Note closed it and updated the mode key. The keyboard remained Medium.
- **Checks:** 13 affected preset/geometry checks passed, including removed-Low migration and both size endpoints. Signed iOS build and physical installation passed, including the native voice fix from #148.

[Medium popup](artifacts/mode-picker/popup-medium.png), [connected key detail](artifacts/mode-picker/popup-key-detail.png), [Full popup](artifacts/mode-picker/popup-full.png), [selected Note](artifacts/mode-picker/selected-note.png), [native tree](artifacts/mode-picker/selected-note-tree.txt). Screens show a synthetic host form. Repeat the native tap/selection flow with `bash scripts/device/native-control.sh mode Email`.

This leg changes the picker, height choices, and Insert glyph. It does not claim to fix native height animation smoothness or revalidate microphone transcription; those are separate legs. No paid provider calls were used.
