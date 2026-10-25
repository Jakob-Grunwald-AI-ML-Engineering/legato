# Spike #1: keyboard dictation with no app hop

**Status:** done. Verified on an iPhone 17 running iOS 26.6.1 on 2026-10-25. Seven Action Button dictations in a row succeeded, with Spotify or Audible playing.

## Verdict

- **Action Button: no hop.** `ToggleDictationIntent` (`AudioRecordingIntent` + `LiveActivityIntent`) starts mic recording from the background.
  - If our keyboard is visible, text streams live into the host field through `textDocumentProxy`.
  - Otherwise the Scratch screen opens.
- **Keyboard button: a hop is unavoidable when no session is running.** `Button(intent:)` in a keyboard runs `perform()` inside the keyboard process, never in the app. Every shipping app (Wispr Flow, Dictus, VivaDicta, Raycast) uses the "open the app once, then signal a live session" pattern. v1 plan: hop when nothing is running, then keep the session for a configurable time (0 = off).

## Device findings

- **Only an intent-launched process can start the mic from the background while other audio plays.** The second start in the same process fails with kAUStartIO 'what' (2003329396). This also happens in a process the user opened. **Workaround:** `exit(0)` about 0.6 s after a background stop, so every press is a fresh launch. It is reliable (7 of 7), but quitting itself is an App Review grey area. Revisit before any App Store release.
- **Other audio:**
  - `.mixWithOthers` works with Spotify and Audible.
  - `.duckOthers` works with both, and lowers their volume.
  - `.interruptSpokenAudioAndMixWithOthers` pauses Audible, but the input route then disappears (format 0 Hz), so recording fails. **Use ducking, not pausing.**
  - Changing options on an already-active session from the background fails with '!int' (560557684). Options are set before activation.
- **Engine:** create a fresh `AVAudioEngine` after the session is configured. One created at launch caches an invalid input format, and `installTap` throws an ObjC exception.
- **Swift 6:** build the mic tap block outside the MainActor (`tapBlock(_:)`), otherwise it traps on the realtime thread.
- **SpeechTranscriber:** `reportingOptions: [.volatileResults]` alone produced nothing until finalize. `preset: .progressiveTranscription` streams live.
- **Keyboard ↔ app:** App Group defaults plus Darwin notifications work. Read state fresh on every notification, never cached.
- **Logs:** they must live under the App Group `Library/` for `devicectl device copy from` to reach them.

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
