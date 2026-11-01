# Sentence authoring and finalized prompt UAT

Product source: `90de466757a08bde167847a9a28d68f6afb009cf`, 31 October 2026. Both signed apps built and installed. Mac used `de.gruenwald.legato.mac.composer-debug` with hotkeys disabled; production was untouched. iPhone used `de.gruenwald.legato` on the physical iPhone 17. Subsequent documentation-only commits do not change this product evidence.

## Observed Mac/provider behavior

Synthetic provider-token input entered the actual signed app, segmenter, document, writer and composer UI, without a Mac microphone lease or Soniox connection. Claude reported `claude-haiku-5-5` throughout.

- Continued rough speech produced two agent document transactions before Stop. Sentence composing completed while further partial speech was arriving. An intermediate draft overclassified an observation as a second bug; intermediate wording was not treated as final acceptance.
- The complete synthetic case described a disappearing custom keyboard, native keyboard fallback, the session still running after switching back, an unknown cause, and the trailing instruction “rewrite this into a nice prompt, please.” Immediate Insert drained authoring through `quick → pause → final → paused`. The completed draft was: “Investigate and fix an iOS issue where the keyboard sometimes disappears and iOS shows the native keyboard instead. After switching back, my session is still running, but I don't know why the keyboard disappears.” Filler and the meta instruction were consumed; the remaining session was context, and the cause remained unknown.
- Insertion into an ordinary focused TextEdit document took the secure-field clipboard fallback and retained the draft. A native Carbon probe confirmed global secure input was enabled; the app owning that state was not established. The toast explicitly said the text was copied rather than typed. This proves fallback preservation, **not successful external insertion or clearing**. No security setting or guard was changed.

The first continuous-case edit took **15.78 seconds**, including **14.71 seconds to the first provider SSE event**. The complete prompt case's first edit took **11.48 seconds**, with a first-event time of **1.83 seconds**. These measurements establish progress before Stop, not fast editing or improved latency.

Three bounded sessions made 15 requests. Two initial sessions were canceled by an unnecessarily inflated provisional budget guard and are incomplete acceptance runs; the third completed finalization. The request/usage trace showed at most one unfinished request at a time. [Transcript-free metadata](artifacts/sentence-authoring/provider-summary.json) includes phases, model, counts and timings. Using the verified higher Haiku pricing tier for every token gives an upper estimate of **$0.1243**, below the authorized $2 total; this is an estimate, not a provider invoice. [Official pricing](https://platform.claude.com/docs/en/about-claude/pricing).

## Physical iPhone and remaining acceptance

The exact product build installed and launched. One standalone native insertion UAT attempt never reached its test body and was stopped at its 120-second host deadline. The phone was actively being used for the user's chat/voice input. No native gestures or successful insertion assertions ran; phone Insert/clear acceptance remains **untested**. Device interaction stopped, and the active host, composition and retained microphone lease were preserved. Private full-device captures remain outside the repository.

Live punctuationless directive escalation, pause/resume conversation continuity, quote countdown timing, successful native insertion/clearing, and final human UAT remain pending. Existing focused tests cover the scheduler and captured-line boundaries; they do not substitute for those live scenarios. The later Dictation/Instructions toggle is outside this revision and this report.
