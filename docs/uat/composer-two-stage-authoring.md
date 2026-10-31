# Two-stage composer acceptance

Product source: `67f6a848c93e11f29d818901f700d5a1d41fd3c5`, 31 October 2026. Signed Mac and iPhone builds passed and both were installed. Mac UAT used isolated `de.gruenwald.legato.mac.composer-debug` with hotkeys disabled; production Mac was untouched. The physical iPhone received `de.gruenwald.legato`, but normal launch was blocked by **Locked**. Installation does not establish that the new iPhone app is running.

## Observed behavior

All provider content below was synthetic. Mac tests exercised the signed native app, real sentence-cleanup and writing providers, actual composer UI and guarded TextEdit insertion. No microphone was started by this UAT. Revision-specific results remain distinct.

| Scenario | Observed result | Revision |
| --- | --- | --- |
| Conservative Prompt editing | Preserved wording, order and uncertainty; corrected only `somthing` to `something`. Writer requests contained the validated correction, not the raw misspelling or raw ASR channel history. | `6ddf49c` |
| Explicit concise rewrite | Previously expanded a 20-word source to 47 words with an unsolicited heading and requirements. After the fix, the same instruction produced 20 words, retained uncertainty and added no heading or investigation checklist. | `3bc70b8` failure; `6ddf49c` recheck passed |
| Instructions routing | Instruction speech stayed outside the draft, invoked only the writer, then the completed bubble hid. | `3bc70b8`, `6ddf49c` |
| Pause/resume | Same session and draft retained; settled request counts did not increase on Pause or Resume. | `3bc70b8` |
| Immediate Insert with pending cleanup | Triggered with two cleanup jobs pending. Drained in 4.74 seconds, inserted the exact draft once into a new empty TextEdit document, then cleared the composer to idle. No extra polishing turn. | `3bc70b8` |
| Two-role concurrency | Every controlled session observed at most two sentence requests and one writer request in flight. Only validated text reached writing requests. | All three revisions |
| Native Mac channel key | Glyph and shortcut fit at the native 580-point window width; the previous clipped Instructions label was removed. | `6ddf49c`, unchanged in final source |
| Actual Soniox response replay | Eight provider-punctuated fragments became four draft lines through normal sentence turns. Several clear continuations joined, but one dependent clause remains separate. | Final `67f6a84`: partial improvement, remaining gap |

The conservative synthetic source was “I think the keyboard maybe disappears when I switch apps, but I am not sure. It could be something else.” The explicit instruction was “Rewrite this into a concise investigation prompt. Keep the uncertainty and do not invent a cause.” The corrected result was “Investigate why the keyboard maybe disappears when switching apps. I am not sure of the cause; do not assume one.” This verifies the observed expansion fix; it is not a universal rewriting-quality guarantee.

The earlier native channel/app-action/topic flows on `cee7b80` and `964feb9` also completed: quoted dictation did not clear the draft; explicit voice Insert inserted into TextEdit without sending an external Return; explicit voice Clear emptied only the composer; successful insertion retained Morgan/Thursday/3 topic context for a follow-up; native New topic cleared that context. Those are historical single-writer results, not new two-stage acceptance claims.

## Semantic endpoint comparison

One local TTS fixture contained a 900ms mid-phrase pause, a 200ms sentence pause, a 1500ms incomplete-phrase pause and a continuation longer than 25 words. Two real Soniox streams each consumed the same 22.223-second mono 16kHz PCM fixture. No microphone or speaker playback was involved.

Soniox v5 already provides semantic endpoint detection. Defaults produced seven endpoints and prematurely punctuated “Please investigate why.” and “I would like to.” A less eager comparison (`endpoint_latency_adjustment_level: 0`, `endpoint_sensitivity: -0.3`, `max_endpoint_delay_ms: 3000`) produced five endpoints and joined one hesitation better, but still split the first incomplete phrase and changed recognition. This single synthetic comparison does not justify changing production defaults. No external semantic VAD model was evaluated. [Soniox endpoint controls](https://docs.soniox.com/stt/rt/endpoint-detection).

The exact default provider responses were then replayed through the actual app decoder and both agent stages. Final source joined these boundaries:

- “Please investigate why the keyboard disappears.”
- “I would like to write a clear report about this behavior, including what happens before the keyboard disappears.”
- “What remains visible after it changes, and whether the original composing session keeps its text and continues working when I return to it.”

The last clause still remains on its own line instead of attaching to the preceding report sentence. Full grammatical sentence grouping therefore remains **partially unmet**. All eight cleanup jobs drained, all words were retained, no extra final provider request ran, and the Mac ended paused with no error or microphone lease. [Final native screenshot](artifacts/two-stage-authoring/mac-stream-replay.png).

## Bounds and remaining acceptance

[Transcript-free metadata](artifacts/two-stage-authoring/provider-summary.json) records request counts, role concurrency, usage and timings. Sentence cleanup took approximately 2.5–3.6 seconds in the controlled warm samples; this does not establish instant edits or improved end-to-end latency. The conservative global Claude estimate, including prior controlled session work, is **$0.6158** against the authorized $2 cap. It applies higher-tier rates to every token and is not a provider invoice. The two actual Soniox streams consumed 44.4466 seconds separately. [Claude pricing](https://platform.claude.com/docs/en/about-claude/pricing).

Physical transcription with the broken AirPods microphone still connected is **untested on both platforms**. Current Mac metadata showed a built-in candidate and no armed microphone; the phone was locked. Inventory, PCM fixtures and signed builds do not prove speech clarity, best-source ranking or recovery on real hardware. No background microphone preference was changed. The iPhone native ABC/type/delete/Return/Insert walk also remains untested: earlier bounded XCTest attempts never reached observable test-body assertions, and were not repeated.

Human UAT remains pending: unlock the updated phone; confirm actual built-in transcription while the broken AirPods remain connected; compare short hesitations against complete thoughts; try ABC and return to the retained composition; verify default edits stay minimal and explicit instructions transform only as requested. The new audio selection measures PCM health, not semantic speech clarity, and does not establish universal best-input selection.
