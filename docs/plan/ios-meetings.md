# iOS meetings

Add microphone meeting recording to the iPhone companion app using the existing Soniox/Room meeting engine and durable meeting store. Work is scoped to the iOS portion of #119; voice isolation, calendar integration, call detection and Mac changes are outside this bundle.

## Delivery

1. Add a native Meetings tab with search, recording controls and live transcript; saved meetings provide summary, transcript, playback, speaker naming, metadata editing and Copy/Share.
2. Retain an iOS meeting controller in the app, reuse MeetingServices and MeetingStore in the App Group, and recover interrupted recording and unfinished processing at launch.
3. Give the microphone one owner. Hand off an idle keyboard/composer hold without clearing its draft, refuse competing starts, and publish meeting state to the keyboard. Coordinate overlapping microphone recovery work in #248 without taking over that PR.
4. Start recording in the foreground and continue across backgrounding/locking. Handle route changes with bounded recovery; when an audio interruption prevents capture, save the meeting as interrupted and require an explicit new start. Keep the UI and activity honest about missing audio.
5. Add a meeting-specific Live Activity and stop-only intent, visually aligned with dictation, requested before audio activation. Its timer, recording status and Stop action follow the recording lifecycle; stale Stop cannot start another meeting.
6. Bound stop/processing background execution and retain enough durable state for later recovery. Automatic summaries follow visible user settings; provider failures preserve the recording and transcript.

## Verification

Use small contract checks for microphone handoff, competing starts, interruption/restart races and recovery. Build the iOS app and extensions, including the ordinary Release exclusion check. Run the full `scripts/ci/test.sh` locally on the final candidate before enqueueing. The protected merge queue's Ubuntu `gate` reports this policy and does not independently test the merge-group revision.

Provide an internal, isolated offline fixture mode with unconditional fake providers. It must not read or mutate real meetings or provider credentials. Simulator evidence proves interface behavior; signed builds prove compilation/signing; physical recording proves device audio and background behavior. Real Soniox/Claude transcription requires separate session authorization and remains explicitly untested until authorized.

Local Xcode is 27.2 while the repository pins 26.6. An iPhone 17 running iOS 26.6.1 is paired; connectivity and automation must be verified at test time. Respect existing device/build ownership and use fixed cache paths with their locking protocol.

## Agent UAT brief

The iPhone app now records and manages meetings alongside Compose and History. Open the Meetings tab in the installed test build; explore it as a user, including recording and reading back a meeting. Test data and provider responses are isolated from real meetings and paid services. Return observed behavior, friction, reproducible findings and screenshots, clearly identifying simulator versus physical-device evidence. Work interactively, reacting to each screen; do not substitute a scripted test run for user testing.

## Landing

After implementation, run fresh agent UAT, fix findings, recheck affected behavior, open one PR to main and wait for the protected merge queue to report MERGED. Keep #119 open for acceptance outside the completed scope. Update the issue and current-focus record with the actual outcome, then run meta:wrap-up. Promotion to live is separate.
