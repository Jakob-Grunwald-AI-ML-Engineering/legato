# Mac scoped-edit cursor preservation

Unselected Magic and cleanup edits preserve the user's rebased caret. Selected replacements still collapse after the replacement. Both platforms consume the shared `ScopedEdit.cursorAtEnd` policy; the Mac adapter no longer forces every result to the end of its scope.

After a confirmed queue edit, the Mac adapter reads the actual caret and acknowledges its UTF-16 offset relative to the landed scope. Undo anchors to that observed position. If the caret is unreadable, selected or outside the landed scope, the adapter withholds the relative acknowledgement and clears its cached Undo anchor. It preserves the actual user caret and refuses a fabricated Undo rather than guessing an end position.

## Runtime evidence

A signed isolated offline build exercised real Magic in TextEdit. Native End/Left positioned the caret immediately before the final period, and each step inspected the host's actual text and Accessibility insertion range. A real typed marker additionally confirmed the final insertion point.

| Step | Actual field | Caret in UTF-16 units |
| --- | --- | ---: |
| Initial | `blue boat.` | 9, before period |
| Magic uppercase | `BLUE BOAT.` | 9, before period |
| Replace `BLUE` with `BRIGHT BLUE` | `BRIGHT BLUE BOAT.` | 16, before period |
| Undo replacement | `BLUE BOAT.` | 9, before period |
| Type `x` | `BLUE BOATx.` | 10, before period |

The [synthetic evidence](mac-caret-uat.json) records exact source and signed binary hashes, source base and raw insertion ranges. An initial direct Accessibility range assignment was ignored by the host; that attempt was excluded from the before-period claim. Native navigation established and verified the successful baseline.

All 49 `MacFieldEditorTests` passed. Relevant contracts cover unchanged-length and expanding/shrinking edits with Undo, UTF-16 emoji context, a nonzero scoped range rebased through intervening user input, selected replacement collapse, and safe Undo refusal when the user caret moves outside the applied scope. The Mac app build and strict signature verification passed.

This is focused runtime verification of the fix, not the fresh agent UAT or final integrated gate. Providers and microphone were offline, and no installed app or global permission changed. After verification, the own test fixture was cancelled to idle and exited, and only its named synthetic TextEdit document was closed. The Mac was visibly free again before evidence writing and commit work continued.
