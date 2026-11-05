# iPhone meetings verification

The companion app provides a Meetings tab for microphone recording, live and saved transcripts, summaries, audio playback, metadata and speaker editing, notes, search, Copy and Share. It reuses the shared meeting engine and store. Starting a meeting reserves the microphone without clearing an existing composition; competing keyboard and dictation starts remain blocked until recording ends.

## Observed evidence

Verification used Xcode 27.2, an iPhone 17 running iOS 26.6.1, and an iOS 26.5 simulator. The repository pins Xcode 26.6, which was not installed locally. The physical test app used a distinct bundle identity alongside the installed Legato app.

A fresh tester explored the simulator app interactively. Live and saved transcripts populated with speakers and timestamps. Renaming a meeting, editing its client and tags, and renaming a speaker persisted after reopening and updating the app. Speaker naming updated the saved transcript and summary. Content search found transcript text. Copy succeeded; Share opened the native share sheet without sending anything. Synthetic playback advanced its timer and position, then paused. Summary headings and lists were rechecked after replacing inline-only Markdown rendering with the existing block parser.

On the physical iPhone, the tester started a real microphone recording and observed the meeting Live Activity while locked. Independent diagnostics captured appState=background, 1,378 input buffers, 2,204,800 converted frames and 137.8 seconds of CAF audio, with the built-in microphone selected. Both provider implementations were scripted. This proves physical background capture and recording continuity; it does not establish transcription accuracy.

The test process was terminated to end capture while the locked phone required human authentication. At relaunch, the full 192.8-second recording recovered to m4a, retained its transcript and summary, and remained marked interrupted. Verification found and fixed duration metadata that initially reflected only the last transcript timestamp; a later independent read confirmed both the recovered meeting duration and audio duration were 192.8 seconds. A separate foreground recording stopped through the app UI and reached finished, with audio and summary steps complete and microphone ownership released.

The first-use microphone permission transition was fixed and rechecked on the phone: the original Record tap reached Recording after permission was granted, without a second tap.

The tester also expanded the meeting Live Activity in Dynamic Island while the phone was authenticated and pressed its Stop control. The app then showed Finished with saved transcript and playback controls. Independent diagnostics confirmed no active meeting or activity, microphone reservation released, and completed audio and summary steps. This verifies the authenticated activity action; the locked-screen action remains unverified.

## Isolation and checks

Internal fixtures replace both meeting providers unconditionally and isolate files and preferences. A temporary test identity can bake LegatoMeetingFixtureName and LegatoMeetingFixtureUsesMicrophone into its Info.plist so widget and automation launches remain isolated without arguments. A meetingsuat identity missing its fixture configuration fails before shared storage access. Production builds omit the fixture implementation, and the ordinary Release binary scan checks for fixture and diagnostic strings.

Focused keyboard/service contracts passed, including draft preservation and competing microphone admission. Additional recovery contracts use real CAF and converted m4a files, previously recovered meetings and unavailable audio. Debug simulator builds, signed device builds, ordinary Release compilation and the Release exclusion scan passed. The protected merge queue owns the full integrated repository gate.

## Limits

Stop while locked is not yet verified: the first physical attempt encountered a Live Activities permission overlay and authenticated-device automation limits. Real Soniox/Claude quality, physical audible playback, sharing to recipients, real call/Siri/alarm interruptions and Bluetooth route changes remain untested. No paid provider requests or distribution deployment were performed. Other apps' call audio is outside this microphone recording feature.
