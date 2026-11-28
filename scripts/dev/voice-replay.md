# Voice replay

Measures background voice filtering on the user's own recordings: own-voice words admitted and background words admitted, per recording, per setting and microphone, and in total. It runs the production `VoiceTokenFilter` and the production best-of-profiles matcher. Mac only.

## Get recordings

On the iPhone (Settings → Background voices) or the Mac (Settings → Voice), turn on **Keep recordings for testing**, then record the setup or settings. Each recording is a folder with `recording.wav` (16 kHz mono) and `recording.json`: the setting, microphone route, device, platform, date, language and the labelled intervals (`reading` with its sentence, `quiet`). **Export all recordings** shares one zip with every recording and `profiles.json`; AirDrop it to the Mac.

## Run

```bash
scripts/dev/voice-replay.sh ~/Downloads/"Legato voice recordings 2026-11-28 1402.zip"
```

A zip is unpacked once beside itself. Folders are searched for `recording.json`. Options:

- `--transcribe` gets Soniox tokens for recordings without `tokens.json`. **This is a paid live call** (one real-time stream per recording, at real-time pace). The key is the one the app saved (Keychain service `de.gruenwald.legato.soniox`). An unsigned command-line build usually cannot read the app's Keychain item; then set `SONIOX_API_KEY` for that run. Tokens are cached as `tokens.json` next to the recording, so later replays are offline and free.
- `--profiles FILE` chooses the voice to match. Default: the export's `profiles.json`, then the Mac app's saved voice (read only).
- `--exclude-own-profile` drops the profile computed from the recording being replayed (it was recorded with the profile it is tested against).
- `--json` prints a machine-readable report. `--models DIR` keeps the pinned CAM++ model elsewhere (default `~/Library/Caches/legato-voice-replay`; downloaded once from the pinned revision and hash-checked).

## What the numbers mean

`tokens.json` holds the stream's responses; each `t` is the seconds of audio sent when it arrived, so the filter sees as much audio as it would have live. A word runs from a token with a leading space to the next; it belongs to the interval holding its midpoint. **Own voice admitted** counts words in reading intervals that got through whole; **background admitted** counts words in quiet intervals that got through whole (TV, other people). Words that got through in part, and words outside every interval, are listed separately. Quiet intervals start one second after the pause begins, so a last word read late is not counted as background.
