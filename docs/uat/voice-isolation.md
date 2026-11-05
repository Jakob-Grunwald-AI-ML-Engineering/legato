# Only my voice

Only my voice is an experimental, opt-in filter for composer and direct dictation. Meetings retain every speaker. It is off by default and adds no model work to ordinary dictation when off.

On iPhone, open Settings → Voice isolation. Record ten seconds of your voice alone in a quiet place, then enable Only my voice. First setup downloads the pinned voice model. You can replace or delete the profile; deletion also turns the option off. Stop active dictation, held microphone sessions and meetings before recording a profile. Enrollment reserves the microphone until recording or cancellation has finished.

Enrollment audio stays in memory and is discarded. Only a normalized voice embedding is saved locally. Dictation audio still goes to Soniox; filtering happens before provisional or finalized words reach cleanup, insertion or History. Settings changes apply to the next take. Unknown, untimed or unrecognized words are withheld, with a visible identifying or uncertain status. The filter needs about two seconds of audio context and can miss the user's words or admit other voices, especially for short or overlapping speech.

The runtime uses the pinned CAM++ v2 CPU model and a 0.58 similarity cutoff. A frozen profile is used for each stream. Audio context is bounded to thirty seconds in memory and cleared when the stream ends. Model files are downloaded only during explicit setup and verified against committed SHA256 hashes.

## Evidence and limits

The focused Soniox checks cover provisional and final filtering at the socket-to-Room boundary, bypass when off or diarizing meetings, bounded uncertain audio, ordered buffered words and visible matcher failures. The native iOS Release build and internal-code exclusion scan passed after retrying a transient asset-catalog read error.

An offline replay through the production matcher and SonioxClient, using real public human recordings and handwritten token labels, admitted 14/16 target-speaker labels and 1/16 other-speaker labels. Off and meeting modes admitted all labels without model calls. This verifies integration and exposes accuracy limits; it is not live Soniox recognition or two-person acoustic acceptance. Profile save, reload, deletion and silent-enrollment rejection passed in the same probe.

Physical iPhone enrollment, background use and live insertion acceptance must be recorded separately. The measured spike remains at `spikes/only-my-voice/README.md`; its no-go describes the stricter reliability goal, while this integration exposes the requested experimental option.
