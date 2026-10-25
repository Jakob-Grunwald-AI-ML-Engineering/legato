# Spike #1: keyboard dictation with no app hop

**Status:** the toggle rework builds for iOS 26 (Swift 6 strict concurrency). It has not been installed on the device yet (phone was locked, CoreDeviceError 4016).

## Device findings so far

- `StartSessionIntent: AudioRecordingIntent, LiveActivityIntent` (`supportedModes .background`), run from the Action Button, starts mic recording from the background **when the intent launches the process**.
- In a process the user launched and then backgrounded, `engine.start()` fails with kAUStartIO 'what' (2003329396).
- From the background, changing category options on an already-active session to interrupt others fails with '!int' (560557684). The planned fix, untested on device, is the Google Maps pattern: engine.stop, `setActive(false, .notifyOthersOnDeactivation)`, setCategory with `[.duckOthers, .interruptSpokenAudioAndMixWithOthers]`, setActive(true), engine.start.
- Keyboard and app talk over App Group defaults plus Darwin notifications.
- Dictation with `SpeechTranscriber` (de_DE) streams text into the host field through `textDocumentProxy`.
- The mic tap block must be built outside the MainActor (`tapBlock(_:)`). Swift 6 traps otherwise.

## Built

Three targets generated from `project.yml`. Bundle IDs use the `de.gruenwald.legato.spike1` prefix, the App Group is `group.de.gruenwald.legato`. There is no idle session: one action toggles everything.

- **`ToggleDictationIntent`** (`AudioRecordingIntent` + `LiveActivityIntent`, `supportedModes [.background, .foreground(.dynamic)]`, `source` parameter for logging). `perform()` runs in the app process.
  - **First press:** activates `.playAndRecord` with `[.duckOthers, .interruptSpokenAudioAndMixWithOthers, .allowBluetoothA2DP, .defaultToSpeaker]`, prefers the built-in mic, starts the engine, the Live Activity and `SpeechTranscriber` dictation. Music ducks and Audible pauses (always on).
  - **Second press:** stops dictation, ends the Live Activity, stops the engine, then `setActive(false, .notifyOthersOnDeactivation)`.
  - **Target choice at start:** if the keyboard wrote `kbd.visibleAt` within the last 2 s (and `kbd.visible` is true), text streams to the keyboard. Otherwise the app opens a Scratch screen via `continueInForeground(alwaysConfirm: false)` ([docs](https://developer.apple.com/documentation/appintents/appintent/continueinforeground(_:alwaysconfirm:))). Scratch is a focused TextEditor with Copy / Share / Clear.
- **Entry points:** App Shortcut "Toggle dictation" (Action Button), Control Center control, Live Activity stop button, keyboard `Button(intent:)`. All run the same intent. The old start/stop intents are gone.
- **Keyboard** (`RequestsOpenAccess`): the Dictate button is `Button(intent: ToggleDictationIntent(source: "keyboard"))` (path A, unproven in keyboard extensions) and logs the tap. One fallback button posts a Darwin notification (works only while the app process is alive). `viewWillAppear` / `viewDidDisappear` write `kbd.visible`, with a 1 s `kbd.visibleAt` heartbeat while visible.
- **Logging** (`Library/spike.log` in the App Group): toggle source, pid, appState, `isOtherAudioPlaying`, `secondaryAudioShouldBeSilencedHint`, category and options, interruptions, route changes, the keyboard-vs-Scratch branch, and every failure with domain, code and four-char code.

## Run

```
xcodegen generate
xcodebuild -project LegatoSpike.xcodeproj -scheme LegatoSpike -destination 'generic/platform=iOS' -derivedDataPath build -allowProvisioningUpdates DEVELOPMENT_TEAM=XWSGN23W75 build
xcrun devicectl device install app --device <UDID> build/Build/Products/Debug-iphoneos/LegatoSpike.app
xcrun devicectl device copy from --device <UDID> --domain-type appGroupDataContainer --domain-identifier group.de.gruenwald.legato --source Library/spike.log --destination spike.log
```

## Test list

**Setup:** mic permission, "Prepare speech model", enable the keyboard with Full Access, bind the Action Button to "Toggle dictation", add the control to Control Center. Force-quit the app before each start test. Note **hop / no hop / error** and the log line.

1. **Keyboard toggle via intent** (Notes, our keyboard up, app force-quit): hop or no hop? Is `perform()` logged with an app pid? Does text stream? With Audible playing: pauses on start, resumes on stop? With Spotify: ducks, then unducks?
2. **Action Button, our keyboard visible:** log shows the KEYBOARD branch, text streams, no app switch.
3. **Action Button, no keyboard visible** (e.g. Home Screen): log shows the SCRATCH branch and the `continueInForeground` result. Scratch opens with the cursor active and text streaming. Is a confirmation prompt shown?
4. **Second press stops everything**, from each source: Action Button, Control Center, Live Activity button, keyboard. Check: Live Activity gone, mic indicator off, music unducked, Audible resumed, `setActive(false) ok` in the log.
5. **Fallback Darwin button:** works only if the app process is alive; compare with test 1.

## Open risks

- `.foreground(.dynamic)` is added to the supported modes. It might change how the system launches the intent's process (the background-only version is the one that worked on device). If the Action Button start regresses, compare against `.background` alone.
- `continueInForeground` may show a confirmation despite `alwaysConfirm: false`.
- Path A is undocumented inside keyboard extensions.
- The duck / interrupt cycle on a fresh session is untested from the background.
- The mic indicator is on during dictation only; battery cost and App Review risk are not assessed.
