# Composer Soniox provider smoke — 2026-10-30

**PASS:** one real Soniox connection transcribed the first 25 seconds of the existing bilingual recording into four document lines, preserving word confidence and language metadata, and completed the production finalization handshake. No production change was needed. This evidence supports the provider path in #113 / #118 independently of debug transcriber injection.

The disposable Swift executable depended on this checkout's production `LegatoSoniox`, `LegatoRoom`, `LegatoAudio`, `LegatoCore`, and `LegatoComposerDoc` products at `4bdd5ac`. It used `AVAudioFile` → `AudioChunk` → `PCM16Converter` → `SonioxClient` → the real `URLSessionSonioxSocket` → `Room` with automatic segment routing. A socket observer forwarded all calls to the production socket and recorded only timing, provider errors, and finalization markers; it did not replace transport or transcription. No agent or Anthropic request ran.

Input was `Tests/LegatoFluidAudioTests/Fixtures/mixed-long.m4a`: AVAudioFile reported 129.1454375 seconds, 16 kHz mono. The probe sent exactly 25.0 seconds / 800,000 bytes of PCM16 in 250 chunks, waiting 100 ms after each awaited send. The existing secure credentials file was read inside the executable; no credential value, request header, or environment dump was logged or committed.

| Observation | Result |
| --- | --- |
| Model and endpoint | `stt-rt-v5`, `wss://stt-rt.soniox.com/transcribe-websocket` |
| First provider tokens after connect | 1.898 s |
| Final document | 4 lines, 60 words; `de`, `en`, `de`, `en` |
| Per-line minimum confidence | 0.940, 0.994, 0.933, 0.852 |
| Per-line mean confidence | 0.9937, 0.9993, 0.9950, 0.9901 |
| Finalize sent | 46.114 s |
| `<fin>` received | 46.231 s |
| Empty **text** end-of-audio sent | 46.234 s |
| `finished: true` received; socket closed | 46.339 s |
| Finalization drain | 0.225 s |
| Room lifecycle | `listening` → `trailing` → `finalPass`; explicit final pass completion → `done` |
| Provider errors | None; `finish()` returned successfully |

The 25-second replay took 46.339 seconds overall, including awaited sends and pacing. This is a bounded correctness smoke, not evidence that a live microphone stream achieves realtime throughput. The first-token timing is measured from connection initiation, not speech onset.

Actual document, with segment boundaries represented by line breaks:

> Guten Morgen zusammen, ich möchte kurz den Stand des Projekts zusammenfassen.
>
> The first milestone was delivered last week, and the client was very happy with the result.
>
> Wir haben das Backend auf den neuen Server migriert, und die Antwortzeiten sind deutlich besser geworden.
>
> However, we still need to fix two bugs in the login flow before the release on Monday.

Each segment closed with the production segmenter's `punctuation` reason. Metadata above came from the resulting `Word` objects published on `asr.segment`, not hand-entered transcript annotations. The final `Room.documentSnapshot.text` contained all four lines, including the last line drained during finalization.

Validation commands (disposable package and sanitized log remain outside Git):

```sh
swift build --package-path /tmp/legato-soniox-uat-20261030
/tmp/legato-soniox-uat-20261030/.build/debug/Probe
```

Both exited 0. The sanitized result is `/tmp/legato-soniox-uat-20261030/result.log`. Only one paid provider connection was made; no retry or alternate key was needed. The docs-only change was checked with `git diff --check`; no full application build or broad test suite was run for this report.

This proves recording replay through production conversion, provider transport, token decoding, word merging, segmentation, confidence/language propagation, document append, and finalization. It does not prove new three-minute Jakob speech, acoustic noise tolerance, native microphone capture, background operation, device UI, or any combined Soniox-plus-Claude flow.

The configuration and authentication were checked against Soniox's current [WebSocket API](https://soniox.com/docs/api-reference/stt/websocket-api) and [WebSocket authentication guide](https://soniox.com/docs/guides/websocket-authentication): the existing Authorization header and `stt-rt-v5` configuration matched the documented API.
