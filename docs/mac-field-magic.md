# Dictation and Magic on Mac

Click the text field where you want to write. Right Option dictates directly into that field. Tap to start and stop, or hold to talk. Live mode shows words as you speak and revises them after cleanup. Settings also offers On stop, After a pause and Line by line.

Right Command turns Magic on. Speak an instruction such as “make this paragraph shorter”, then tap Magic off or release a held key to run it. Magic edits the selected text, what you just dictated, the paragraph or a larger readable scope as appropriate. When dictation is already running, Magic temporarily takes its speech; ordinary dictation resumes when Magic turns off. Starting Magic while idle opens its own microphone take and stops that take when Magic turns off.

Live updates coalesce before touching the host. Corrections replace the changing tail after the stable prefix, so the caret does not jump into a changed word and back on every partial.

The small notch indicator shows what Magic heard, progress and the result. Undo restores the exact changed scope while the field and text still match. Accept keeps the result. Magic saves the original and generated result in History before editing; Copy original is available from the history row’s context menu, including when application could not be confirmed. The indicator never becomes the key window; the editor keeps focus. Typing also accepts a completed result.

There is no separate Mac composer. The old composer shortcut becomes Magic, including custom bindings. Existing dictation bindings, history, writing model and personal instructions retain their stored settings. Change either shortcut in Settings → Shortcut.

Typing or clicking while Legato writes never stops it: the words already spoken finish where they started, later words go where your cursor is, and only text you changed is left alone (the take stays in History). It never replaces an unreadable document blindly. Where a field cannot be edited live (unreadable, or a Chromium web field such as Chrome, Edge or an installed web app), the notch panel shows the whole take as you speak, the cleanup replaces it there, and the finished text is typed once into the app where you started, while that app is still in front and you have not typed. If typing stops part-way, the rest goes to the clipboard. The `dictation.panel` default (`whenNeeded`, or `always`) chooses the panel for every field. Secure fields receive clipboard recovery only. Magic reads Chromium fields too and pastes its result over the scope. A meeting and dictation/Magic never share the microphone.

## Internal offline verification

Only an internal Debug app exposes the credential-free field fixture. Launch an isolated app identity with `-LegatoOfflineFixture YES -LegatoDataRoot /absolute/scratch/path`, and give its bridge a separate `LEGATO_MAC_ROOT`. Use an isolated bundle identifier so its preferences do not touch the installed app. No microphone, Soniox connection, Claude client call or credential warming occurs in fixture mode. History, vocabulary and recent takes use the supplied data root.

`dictation-debug-tail` supplies changing nonfinal speech; `dictation-debug-line` supplies final speech; `dictation-debug-stop` ends a synthetic take. These pass through the real speech-mode sink, pipeline and AX writer. `magic-toggle` switches the same Magic route as its shortcut. The offline instruction runner supports uppercase, lowercase and delete for selected, dictated, paragraph or whole text; it uses the shared scope/outcome contract. `magic-undo`, `magic-accept`, `magic-dismiss`, `magic-state` and `field-fixture-state` expose controls and state without provider requests.

When another installed Legato is running, assign different shortcuts in the isolated app before synthesizing real hotkeys. Its normal Right Option/Right Command shortcuts could start the installed app's microphone. Runtime results from this fixture prove local field routing and editing, not live speech recognition or provider quality.

The shared transaction and recovery contract is documented in [Direct field editing](field-editing.md).
