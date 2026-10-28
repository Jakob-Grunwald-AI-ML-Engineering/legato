# Mac live meeting diagnostics

Build Debug and launch Legato with `--meeting-debug`. The running app keeps a once-per-second `status.json` and bounded `events.jsonl` (4 MiB plus one previous file) in `~/Library/Caches/de.gruenwald.legato/meeting-debug/`. No files or command listeners are created without this flag. Release builds omit this mode.

Post commands to the existing process with `notifyutil -p de.gruenwald.legato.mac.debug.status`. Replace `status` with `meeting-start`, `meeting-stop`, `meeting-mute`, or `meeting-unmute` as needed. Start/stop use the ordinary meeting controller; stop also runs its ordinary after-meeting processing. Mute commands set the requested state only when it differs. They affect the microphone and preserve system audio.

Read `status.json` or follow `tail -f ~/Library/Caches/de.gruenwald.legato/meeting-debug/events.jsonl`. Status includes phase, explicit microphone UID, mute, engine, latest notice, raw microphone and sink measurements. Counters reset on each snapshot, normally once per second (an explicit status command shortens that interval). RMS and last-buffer age distinguish silence from absent buffers. Sink meters include written silence. Engine events report start attempts, first-buffer timing, configuration changes, restarts, and actual audio-unit device elements. Only measurements and metadata are logged; audio samples and transcript contents are excluded.

Acceptance check: launch Debug with the flag, request status, start a meeting, speak and inspect increasing raw-mic counts/RMS, mute/unmute and inspect sink meters while system audio continues, then stop and confirm idle. Without the flag, notifications must have no effect and diagnostics files must not be updated.

For an acoustic check, generate a synthetic speech fixture with `say -v Samantha -o /private/tmp/legato-microphone-probe.aiff "This is a microphone test"`, then post `de.gruenwald.legato.mac.debug.probe-speaker`. The Debug app plays it quietly through the built-in speaker. Its own playback is excluded from the system tap, so received speech tests the physical microphone. Missing files or unavailable built-in speakers produce a diagnostic event.
