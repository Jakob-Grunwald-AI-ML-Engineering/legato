# Native composer voice input

The shared audio recorder prevented voice input on both platforms even with valid keys. The 16 kHz mono AAC encoder rejected the hardcoded 64 kb/s rate with Core Audio `560226676` (`!dat`) at `AudioConverterSetProperty(kAudioConverterEncodeBitRate)`. This happened after opening Soniox and starting the microphone. Recording now uses supported 32 kb/s AAC.

A real AVAudioFile round-trip regression reproduced the exact failure before the rate change and passed afterward. All 59 affected AppServices tests passed. The signed Mac build succeeded.

## Mac native capture

The old signed app reproduced `!dat` on its normal `toggle` path. The repaired development-signed `de.gruenwald.legato.mac.composer-debug` app reached `listening` with no error. Session `7213C6FA-6665-42C5-BE10-1C872EBCCCC9` used `microphone.soniox`, not debug transcript injection or direct PCM replay.

One short system-speech fixture was played through the speakers and captured by the actual microphone. Soniox emitted 44 final words across 7 segments; the expected Alex, staging meeting, tomorrow at 10, and test report concepts were present. Stop emitted `mic.off` followed by `asr.finished`, with no capture/provider error. Claude work subsequently reached `finalPass` and `done` with reason `complete`. The finalized AAC file contained 24.2 seconds, 387,200 valid frames, and 96,489 encoded audio bytes at approximately 31.7 kb/s. Raw audio and Room logs stay local because they can contain surrounding speech.

This proves native capture, encoding, provider transcription, and provider shutdown on this Mac. It does not establish human speech accuracy, noisy-room quality, or long-session reliability. Accessibility permission for native field insertion is independent of this audio repair.
