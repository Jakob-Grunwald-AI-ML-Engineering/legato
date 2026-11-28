# `legato meetings speakers --replay`

Runs the after-meeting speaker check (`MeetingSpeakerCleanup` in `LegatoMeetingSpeakers`, the `speakers` step of the after-stop chain) on a saved meeting and prints what it would change. It never writes in the meetings folder and prints counts and speaker names only, no transcript text.

```sh
swift build -c release --product legato
.build/release/legato meetings speakers --replay <meeting id, or its start, or its folder>
```

Options:

- `--threshold <x>`: the cosine similarity at which two stretches count as one voice (default `SpeakerClustering.defaultThreshold`, 0.5).
- `--no-profile`: ignores the voice profile. On a Mac meeting "Me" is then the one voice that is loud on the microphone.
- `--voice-root <dir>`: where the CAM++ models and the profile are. The default is the Mac app's folder under `~/Library/Application Support/Legato/VoiceIdentity`, else the first folder there that has a profile.
- `--root <dir>`: the meetings folder used to resolve an id.

The first run downloads the pinned segmentation model to `~/Library/Application Support/Legato/Models/pyannote-segmentation-3.0` and, if they are missing, the CAM++ models.

## What it prints

- **Run time** against the audio length, split into the segmentation model and the voice embeddings. The one-time download is not counted.
- **Word times**: how many segments carry them. A meeting saved before they were kept takes them from its `log/room.jsonl` when it has one, which the app itself does not do.
- **Local speakers**: embedded reliably, embedded from little speech, placed by context, or left out. Then the voices found and how many seconds each one speaks.
- **People** before and after, with word counts. Then merges, new people, which person each voice went to, segments split, and words moved.
- **Me**: the person found as the user, the voices loud on the microphone, and each one's similarity to the profile.
- **Quality**, self-labelled from the live segments and the tracks: the number of people before and after; the changes of person inside a live segment (the live engine heard one speaker there), how many of them the louder track switches at, and the parts shorter than the cleanup's minimum (`SpeakerReassignment.minimumRunSeconds` or `minimumRunWords`).
- **Track truth** (Mac meetings only): words loud on the microphone count as "me", words loud on the system audio as "them". The Me/Them disagreement is the share of these words whose track differs from the side most of their person's words are on, before and after the check. "Moved words" tells whether each moved word went toward that truth or away from it. **Me recall** is the share of microphone words given to Me, **Me precision** the share of Me's words (loud on one track) that are on the microphone. Both use the same tracks the cleanup decides by, so they show consistency, not independent accuracy; microphone words where the diarization hears no voice of the user's (quiet noise, a word timed a little off) are deliberately not given to Me and count as misses.

Embeddings exist only in the process's memory while it runs.
