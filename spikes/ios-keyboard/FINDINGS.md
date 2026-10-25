# Spike #1: keyboard dictation with no app hop

**Status:** builds unsigned for iOS 26. It has not been installed or tested on a device yet.

## Built

Three targets, generated from `project.yml`. Bundle IDs use the `de.gruenwald.legato.spike1` prefix, and the App Group is `group.de.gruenwald.legato`.

- **App.** The recording session uses `.playAndRecord` with `.mixWithOthers`, `.allowBluetoothA2DP` and `.defaultToSpeaker`, and prefers the built-in mic. It transcribes with `SpeechTranscriber` (de_DE). It writes a heartbeat and mic level to the App Group every second, and logs to `spike.log`.
- **`StartSessionIntent` / stop intent.** They conform to `AudioRecordingIntent` and `LiveActivityIntent`, so `perform()` runs in the app process, with `openAppWhenRun = false`. They are exposed through App Shortcuts, which makes them available to the Action Button and to Shortcuts automations.
- **Widgets.** A Live Activity (required while recording) and Control Center start and stop controls.
- **Keyboard** (`RequestsOpenAccess`). It shows whether the session is alive. Each start path has its own button:
  - **A:** `Button(intent:)` inside the keyboard
  - **B:** a Darwin notification
  - **C:** opening a URL into the app (the baseline that hops)

  It also has a Dictate button, which streams volatile and final text through `textDocumentProxy`, and an "Insert test" button.

## Verified by command

- **Device:** iPhone 17 on iOS 26.6.1, paired, Developer Mode on.
- **Build:** `xcodebuild` with `CODE_SIGNING_ALLOWED=NO` gives `BUILD SUCCEEDED`, with only an interface-orientation warning.
- **Built plists:** the keyboard has `RequestsOpenAccess=true`. The app has `NSSupportsLiveActivities` and `UIBackgroundModes=[audio]`.
- **Intent metadata:** `StartSessionIntent` carries the `AudioRecording` and `SessionStarting` protocols, with `openAppWhenRun=False`.

## Blocker

Team signing fails with "PLA Update available". The Program License Agreement on developer.apple.com/account has to be accepted first.

## Run

```
xcodegen generate
xcodebuild -project LegatoSpike.xcodeproj -scheme LegatoSpike -destination 'id=<UDID>' -derivedDataPath build -allowProvisioningUpdates build
xcrun devicectl device install app --device <UDID> build/Build/Products/Debug-iphoneos/LegatoSpike.app
xcrun devicectl device copy from --device <UDID> --domain-type appGroupDataContainer --domain-identifier group.de.gruenwald.legato --source spike.log --destination spike.log
```

## Device checklist

**Setup:** grant the mic permission, tap "Prepare speech model", enable the keyboard with Full Access, bind the Action Button to "Start session", and add the control to Control Center.

For each test, note **hop / no hop / error** and the log line.

1. Action Button, with the app force-quit and the phone unlocked.
2. Action Button, with the phone locked.
3. Control Center control.
4. Shortcuts personal automation, with "Ask Before Running" off.
5. Keyboard path A. Did `perform()` run in the app process?
6. Keyboard path B, once with the app in recents and once with it force-quit.
7. Keyboard path C. Note which open method worked.
8. Dictate in Notes: is the volatile text replaced cleanly? Use "Insert test" to tell keyboard problems from app problems.
9. Idle lifetime: check the heartbeat log after 1, 5 and 30 minutes.
10. Dismiss the Live Activity while recording. Does the session die?
11. Music on the iPhone speaker (Spotify, then Apple Music) while dictating.
12. Music on AirPods. Does it stay on A2DP with no drop in quality?
13. Interrupt with a call, Siri or an alarm, then check the `INTERRUPTION` log lines.
14. Battery drop over 30 minutes with a session running, compared with no session.

## Open risks

- **Starting from the background may fail.** One forum thread reports a "Target is not foreground" error when an `AudioRecordingIntent` starts a Live Activity and recording together; the only answer, from a community member, says the first start must be in the foreground ([815725](https://developer.apple.com/forums/thread/815725)). Apple has said elsewhere that privacy rules block starting a recording from the background ([698253](https://developer.apple.com/forums/thread/698253)). Superwhisper's Action Button behaviour suggests this can work anyway.
- **Path A is unproven.** I found no documentation of `Button(intent:)` working inside a keyboard extension.
- **Path B needs the app running.** Darwin notifications only reach a live process.
- **Returning to the host app.** Looking up the host app has been broken since iOS 26.4 ([836168](https://developer.apple.com/forums/thread/836168)), which matters if path C is used.
- **Always-on mic.** The mic indicator stays visible the whole time. The battery cost and the App Review risk haven't been assessed.
