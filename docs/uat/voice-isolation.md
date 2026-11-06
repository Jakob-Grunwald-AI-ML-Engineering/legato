# Background voice filtering

Reduce background voices is an experimental, opt-in transcript filter for composer and direct dictation. It quietly reduces other speakers' words while prioritizing the user's speech. It does not denoise the microphone waveform or remove background sound from recordings. Meetings retain every speaker. It is off by default and adds no model work to ordinary dictation when off.

On iPhone, open Settings → Background voices; on Mac, open Settings → Voice. Record ten seconds of your voice alone in a quiet place, then enable Reduce background voices. First setup downloads the pinned voice model. You can replace or delete the profile; deletion also turns the option off. Stop active dictation, held microphone sessions and meetings before recording a profile. Enrollment reserves the microphone until recording or cancellation has finished. Existing saved profiles remain valid; this policy update does not require enrollment again.

Enrollment audio stays in memory and is discarded. Only a normalized voice embedding is saved locally. Dictation audio still goes to Soniox; transcript filtering happens before provisional or finalized words reach cleanup, insertion or History. Settings changes apply to the next take. There are no live identification, rejection or filter-status messages in the app or keyboard. Ordinary dictation notices and errors remain available.

The current policy prioritizes speech recall: uncertain matches, short speech and words without usable timing pass immediately. Only repeated strong evidence of a different speaker suppresses words. A recent positive match briefly protects the user's speech; that bounded grace expires across pauses so it cannot admit background conversation indefinitely. The filter has no pending-final queue and does not hold earlier words for a later identity decision. Missing or failed voice matching bypasses the optional filter so dictation can continue. Other voices may still get through, particularly during overlap or brief speech; this is not reliable speaker exclusion.

The runtime uses the pinned CAM++ v2 CPU model. Audio context is bounded in memory and cleared when the stream ends. Model files are downloaded only during explicit setup and verified against committed SHA256 hashes.

## Evidence and limits

Physical iPhone testing confirmed that the user could enroll and save a voice profile. The initial strict integration then failed product acceptance: it rejected the user's own voice and later dumped text that had been deferred. The user also reported TV and other people's speech being picked up during thought pauses. These findings drove the current recall-first, immediate-text policy and removal of live filter messages. The user accepted the revised physical iPhone build: their voice comes through and background speech is reduced. This confirms the tested room experience, not universal speaker exclusion.

Earlier focused Soniox checks and the native iOS Release build covered the initial strict integration. Their passing results do not establish acceptance of the revised policy or override the physical failures. Current automated results must be recorded separately after the revised implementation is checked.

An earlier offline replay through the initial strict production matcher and SonioxClient, using real public human recordings and handwritten token labels, admitted 14/16 target-speaker labels and 1/16 other-speaker labels. Off and meeting modes admitted all labels without model calls. Profile save, reload, deletion and silent-enrollment rejection passed in that probe. Those numbers describe the initial strict policy only; they are not measurements of the revised filter, live Soniox recognition or two-person acoustic acceptance.

The revised filter passed user acceptance on the physical iPhone. The measured spike remains at `spikes/only-my-voice/README.md`; its no-go still applies to the stricter reliability goal. The accepted scope is quiet background reduction that prioritizes the user's speech; the stricter speaker-isolation goal remains outside this acceptance.
