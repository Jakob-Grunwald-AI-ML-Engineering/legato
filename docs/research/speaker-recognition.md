# Speaker recognition: meetings and background voices

Research, 2026-11-28. Desk research only: nothing here was run on Legato audio. Every number is a published or vendor figure unless marked otherwise. Current behaviour: [Background voice filtering](../uat/voice-isolation.md), [spike #242](../../spikes/only-my-voice/README.md).

## Verdict

- **Background voices:** better enrolment, calibration and cues will do more than training a model on the user's voice. On-device fine-tuning with a few enrolment clips tends to make verification *worse* ([Chen 2025](https://www.isca-archive.org/interspeech_2025/chen25_interspeech.pdf)). Collecting more, and more varied, enrolment audio is the "training" that works.
- **Meetings:** yes, this can be improved. Legato already has the signals to tell "me" from "them" (the separate Mac tracks and the voice profile). A pass over the whole meeting after it ends fixes renumbered and split speakers. Naming *other* people from their voices is the legally risky part.

## Background voices (dictation)

### Recommended first: no new model

| # | Change | Why | Confidence |
|---|---|---|---|
| 1 | **Guided enrolment:** several sentences in normal, quiet and fast speech, about 30–60 s in total, ideally on each mic the user has | Enrolment covering several conditions makes short, noisy test windows more robust ([Zhang 2022](https://www.isca-archive.org/interspeech_2022/zhang22j_interspeech.pdf)). The single 10 s quiet take is the likely cause of the "rejects my own voice" failure. | medium |
| 2 | **Whispering as its own profile**, not averaged into the normal one | Matching a whisper against a profile enrolled with normal speech is the worst case: EER of roughly 5–8% against 0.2–0.5% for matched styles. Enrolling some whispered speech closes most of that gap ([arXiv 2604.20229](https://arxiv.org/abs/2604.20229), [Sarria-Paja 2017](https://espace.inrs.ca/id/eprint/6539/1/Sarria%20Paja%2C%20Milton%20Orlando_2017.pdf)). Score against several profiles and take the best match. | medium |
| 3 | **Per-mic profiles** (built-in, AirPods, Mac) | The same voice through different mics drifts in embedding space. This is an engineering inference; nothing published either way. | low–medium |
| 4 | **Adaptive profile:** fold in windows that match strongly (≥0.6) and are close to the mic, capped so the profile cannot drift | Keeps the profile current on real routes and in real rooms. Standard practice, but no dictation-specific numbers. | medium |
| 5 | **Per-user threshold** (cohort normalisation, AS-norm) instead of the global 0.45 / 0.20 | The EER gain is small on benchmarks (~6–12% relative), but it calibrates the threshold to each voice; the spike's worst speaker kept only 83% of their own windows ([arXiv 2504.04512](https://arxiv.org/html/2504.04512v1)). Needs ~200 stored cohort embeddings, a few hundred KB. | medium |
| 6 | **Near-field prior:** loudness and spectral tilt relative to the enrolment level make the thresholds stricter or looser | A TV or a voice across the room is much quieter than the user's mouth at the mic. Cheap. Unmeasured: test on the device. | medium |
| 7 | **iPhone audio front end A/B test:** voice processing off / on / on with Voice Isolation, a TV playing nearby | `setVoiceProcessingEnabled` is Mac-only in `MicSource` today. On iOS it unlocks the user-chosen mic modes; recording apps get Voice Isolation on iOS 26+, and the user turns it on via `showSystemUserInterface(.microphoneModes)`, since there is no API to set it ([WWDC23](https://developer.apple.com/videos/play/wwdc2023/10235), [Apple](https://support.apple.com/en-us/101993)). Apple claims only that it removes ambient noise; whether it removes a competing *speaker* is unverified. It applies in the containing app, which owns the mic. | high (API) / unknown (effect) |

Swapping the embedding model buys little: CAM++ (7.2M params, 0.65–0.73% EER on VoxCeleb1-O) is already near the best accuracy for its size ([3D-Speaker](https://github.com/modelscope/3D-Speaker)).

**Shape for the user:** one voice and one setup flow; the profiles stay behind the scenes. The setup records several prompts. Legato keeps one profile per style (normal, quiet, whisper) and per mic, scores against all of them and takes the best match. The adaptive updates (row 4) refine whichever profile matched. Replacing or deleting the voice removes all of them.

### Later, if the above falls short

- **Decide per speaker, not per window:** turn on Soniox speaker separation in dictation and decide "me" from all audio of a label. Soniox allows this together with endpoint detection, but warns that endpointing lowers diarization accuracy, without giving numbers ([Soniox](https://docs.soniox.com/stt/rt/endpoint-detection)). Worth a measured spike only.
- **Target-speaker extraction on the Mac:** REAL-TSE BSRNN has a Core ML build ([model card](https://huggingface.co/ferdinandl007/REAL-TSE-BSRNN-CoreML)). The separator is ~44 MB, plus a 12 MB embedding model. It is not causal (8 s chunks) and runs on CPU only. The card's one-clip result is 57.8% → 2.0% WER. Its licence is "other". Not suitable for the iPhone keyboard path.
- **Personal VAD / VoiceFilter-Lite** (130 KB–2.2 MB, built for phones): no public weights, so Legato would have to train its own. A larger project, justified only after the first table.

### Not recommended

On-device fine-tuning (a classifier head, PLDA or LoRA) on enrolment clips: too little data, and it overfits. More varied enrolment is the cheaper and safer form of training.

## Meetings

### Recommended

| # | Change | Notes | Confidence |
|---|---|---|---|
| 1 | **Mac "me" vs "them" from the separate tracks** | `mic.caf` and `system.caf` are recorded already; only the mix is transcribed. Granola uses the same approach: mic is Me, system audio is Them ([Granola](https://docs.granola.ai/help-center/taking-notes/speaker-attribution)). Pitfalls: people in the same room are also on the mic, echo leaks in over speakers, and both sides talk at once. So mark a segment "me" only if the mic dominates *and* the voice matches the profile. | high |
| 2 | **"Me" from the voice profile** (both platforms) | Reuses the dictation enrolment. On iPhone it is the only way to find "me", since there is just one mic. | medium–high |
| 3 | **Refine after the meeting**, over the whole recording | Sees the whole meeting at once, so reconnect renumbering and split speakers go away. Two routes; benchmark both on real meetings: | medium |
|   | a. **Soniox async** on the stored mix | Soniox itself recommends async for the best speaker separation. About $0.10/h, against $0.12/h for real-time; diarization costs nothing extra ([Soniox](https://docs.soniox.com/stt/concepts/speaker-diarization), [pricing](https://soniox.com/pricing)). Also re-transcribes the words. | medium |
|   | b. **Local FluidAudio offline diarizer** (pyannote community-1, Core ML, Apache-2.0 code) | ~300× real time on an M5 Pro. AMI DER 18–20%; it found the right speaker count in 12 of 16 meetings ([Benchmarks](https://github.com/FluidInference/FluidAudio/blob/main/Documentation/Benchmarks.md)). Free, and the audio stays on the device. Check the weight licence before shipping. | medium |
| 4 | **Link labels by voice** if the live labels are kept: a CAM++ embedding per label, then clustering across streams | Cheaper than item 3 and merges reconnect duplicates. Published within-meeting EER with CAM++ is about 3%. Start at a cosine of 0.5–0.6, calibrated on real meetings. | medium |

Soniox offers no speaker identification, enrolment or stable labels across streams. A stereo stream does not give separate transcripts per channel either; per-channel transcription means one stream per source, about double the cost ([Soniox](https://soniox.com/wiki/diarization-vs-speaker-identification)).

Not realistic: a live on-device diarizer on the phone. FluidAudio's own docs report about 53% DER for streaming on AMI and recommend offline.

### Naming other people: a product and legal decision

A stored voiceprint used to recognise a person in later meetings counts as biometric data under GDPR Art. 9, which requires explicit consent ([EDPB 3/2019 ¶75](https://www.edpb.europa.eu/sites/default/files/files/file1/edpb_guidelines_201903_video_devices_en_0.pdf)). Anonymous "Speaker N" labels within one meeting probably do not. In the US, suits over voiceprints are proceeding against Otter.ai (2025) and Fireflies.AI ([Otter](https://www.sheppard.com/insights/blogs/when-ai-takes-notes-court-allows-privacy-claims-against-otterai-to-proceed), [Fireflies](https://www.sheppard.com/insights/blogs/illinois-bipa-suit-targets-ai-note-takers-practical-lessons-for-meeting-transcription)). Teams requires each person to enrol themselves.

| Option | What it does | Risk |
|---|---|---|
| Me only | Only the user's own consented profile | low |
| Names within one meeting | Names the user types are spread across label duplicates; nothing is kept afterwards | low |
| Opt-in people library | Saved voiceprints suggest names in later meetings, filtered by calendar attendees; can be deleted | high: needs other people's consent |

## How to measure

- **Meetings:** the separate Mac tracks label each saved meeting for free (system track = them, mic track = me or room). Replay saved meetings through items 1–4 and compare against Soniox's live labels before changing the UI.
- **Dictation:** real recordings on the device are needed: the user's speech with a TV and another person nearby, in normal, quiet and whispered styles, on the built-in mic and AirPods. Measure at word level through the real insertion path, as the spike asked.

## Decisions (2026-11-28)

1. **Only the user who records is recognised**, from their own voice profile. No people library and no stored voiceprints of other participants. Users rename other speakers by hand. Embeddings computed temporarily for diarization within one meeting are discarded, never stored. Recognising others from a stored library could count as "remote biometric identification" under the EU AI Act, a high-risk class from 2 Dec 2027 that the open-source exemption does not cover.
2. **No re-sending meetings to Soniox async.** Speaker cleanup, both splitting and merging, runs locally after the meeting.
3. **A guided setup of about 60 s:** the user reads sentences in normal, soft, lively and whispered tones. Behind the scenes there is one profile per style and per mic.
