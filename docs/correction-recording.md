# Captured edits

Legato records settled edits to completed dictations locally on iPhone and Mac. Open **History → Captured edits** on iPhone or **Captured edits…** in the Mac menu. Expand a record to inspect the original transcription, inserted text, before/after text, device locale and observation source. Delete individual records there; deletion is separate from dictation History. The view refreshes while open and displays the newest 200 records.

Capture follows a uniquely identifiable delivered scope in the same readable field for up to ten minutes. A one-second pause groups backspacing and replacement typing into one edit. Word-level summaries accompany exact before/after text, so sentence and formatting changes remain available for later analysis. Records identify the source dictation run or line; that identity is not always a History entry UUID.

The iPhone adapter observes settled field snapshots while the Legato keyboard is visible. The Mac adapter observes the focused accessible destination field. Legato's own writes suspend or reset observation; cursor movement alone produces no correction. Clearing a whole field is treated as a send/clear boundary. Secure and unreadable fields are excluded.

Coverage is conservative: changing fields, losing readability, ambiguous repeated text, changed surrounding anchors, or a shifted/truncated iPhone proxy window can stop capture. Edits during streaming machine writes and unreadable/panel delivery paths are not captured. Keyboard-origin means observed after Legato keyboard input; either observation source may include host autocorrect. The recorded locale is the device locale, not detected speech language.

Each observation is a private immutable JSON file under `Corrections/` in the app's data root (shared App Group on iPhone). Records contain text and remain on that device; no new provider calls or training jobs are started. Personal vocabulary/style derivation is tracked in #276, and applying those preferences in #277.
