# Native composer voice input

The shared audio recorder prevented voice input on both platforms even with valid keys. The 16 kHz mono AAC encoder rejected the hardcoded 64 kb/s rate with Core Audio `560226676` (`!dat`) at `AudioConverterSetProperty(kAudioConverterEncodeBitRate)`. This happened after opening Soniox and starting the microphone. Recording now uses supported 32 kb/s AAC.

A real AVAudioFile round-trip regression reproduced the exact failure before the rate change and passed afterward. All 59 affected AppServices tests passed. The signed Mac build succeeded.

## Mac native capture

The old signed app reproduced `!dat` on its normal `toggle` path. The repaired development-signed `de.gruenwald.legato.mac.composer-debug` app reached `listening` with no error. Session `7213C6FA-6665-42C5-BE10-1C872EBCCCC9` used `microphone.soniox`, not debug transcript injection or direct PCM replay.

One short system-speech fixture was played through the speakers and captured by the actual microphone. Soniox emitted 44 final words across 7 segments; the expected Alex, staging meeting, tomorrow at 10, and test report concepts were present. Stop emitted `mic.off` followed by `asr.finished`, with no capture/provider error. Claude work subsequently reached `finalPass` and `done` with reason `complete`. The finalized AAC file contained 24.2 seconds, 387,200 valid frames, and 96,489 encoded audio bytes at approximately 31.7 kb/s. Raw audio and Room logs stay local because they can contain surrounding speech.

This proves native capture, encoding, provider transcription, and provider shutdown on this Mac. It does not establish human speech accuracy, noisy-room quality, or long-session reliability. Accessibility permission for native field insertion is independent of this audio repair.

## Physical iPhone native capture

The signed combined build included keyboard UI PR #146 and this recorder repair on device `00008150-000E60360245401C`. Session `D65AE8B7-229C-422F-9BE5-59E179F4C68C` used the normal host `toggle` action and `microphone.soniox`. Startup reached `Listening` in approximately 606 ms with no error. No transcript tokens or PCM were injected.

Two short audible system-speech fixtures were captured by the actual phone microphone. Three final Soniox segments retained Morgan, staging review, Friday at 2, blue notebook, and the separate green compass/harbor/Saturday phrase. The finalized AAC contained 77.9 seconds and 307,840 encoded audio bytes at approximately 31.5 kb/s. Device-control interruption extended the capture beyond the spoken fixtures. Actual Room events reached `mic.off` → `asr.finished` → `finalPass` → `done` with reason `complete`. The final state was idle, error empty, dictating false, microphone lease false, busy false, and muted false. Raw local recordings and transcript logs are excluded from Git.

The native XCTest Start-button probe stalled before executing and was terminated; direct host `toggle` exercised the same normal voice pipeline. Native Start-button and Mute/Unmute interaction therefore remain unconfirmed in this pass. An attempted Settings transition failed with a CoreDevice remote-service XPC error and transient device unavailability. Both fixture phrases were transcribed, but genuine background app state was not established; this is not background-continuation proof. The device recovered, Stop was acknowledged, and the completed session was pulled. No second microphone session was started.
