# Composer instruction/content follow-up — 2026-10-30

Both bounded real-Claude Message checks passed after clarifying the bundled authoring prompts. Newly appended speech is identified as unprocessed input; writing directives guide the draft instead of remaining in it. Needed changes must use document tools. Intended facts and already suitable authored text are preserved. This is a generic prompt clarification, with no lexical substitutions or personal preference override.

## Baseline and result

The prior physical-phone session `A52037CF-2E5E-4072-9570-4F21098C6630` on `faae6bd` left “Schreib Alex: Wir treffen uns morgen um zehn.” verbatim both live and after Stop. Its live response called the line already complete. The earlier ten-minute-late message worked, establishing inconsistent authoring rather than a transport failure. The baseline is recorded in `composer-phone.md`, final native fix verification.

| Input | Actual authored output, unchanged after Stop | Verdict |
| --- | --- | --- |
| Schreib Alex: Wir treffen uns morgen um zehn. | Hallo Alex, wir treffen uns morgen um zehn. | Pass: recipient interpreted, instruction consumed, tomorrow and ten preserved. |
| Text Morgan: The staging rollout is Tuesday at 14:30. Ask if that works. | Hi Morgan, the staging rollout is set for Tuesday at 14:30. Does that work for you? | Pass: recipient and request interpreted, staging rollout, Tuesday and 14:30 preserved. |

German session `275AA3B7-01E9-4E4B-BD86-E8B72DEFE205` applied an actual agent `replaceLines` transaction at room sequence 77, revision 2; successful tool result is sequence 79. Stop ran the restructure participant and document `done` is sequence 123. English session `CB59362B-8CE2-4A4C-833F-C49C736BC68D` applied `replaceLines` at sequence 115, revision 3; successful tool result is sequence 117. Stop ran the restructure participant and `done` is sequence 213. Each final state was `done,busy:false,pendingLineIDs:[],error:""`. No output phrase was asserted as an exact target; the verdict concerns usable message content and factual preservation.

## Runtime and checks

The development-signed native Mac app was built from `b48c285` plus this prompt diff, using the existing isolated identity `de.gruenwald.legato.mac.composer-debug`, team `XWSGN23W75`, bridge `/Users/work/Library/Caches/Legato/composer-debug-bridge`, and `-LegatoDisableHotkeys YES`. Existing Keychain credentials were used without reading or importing them. App: `/Users/work/Library/Caches/legato/device-derived/49128d68bad9/Build/Products/Debug/Legato.app`. The bundled base prompt was compared byte-for-byte with the changed source.

`swift test --filter LegatoAgentTests` passed all seven tests. `LEGATO_MAC_SIGNED=1 scripts/device/ctl.sh --target mac build` passed using local Xcode 27.2; pinned 26.6 was unavailable. Logs are `/Users/work/Library/Caches/Legato/prompt-uat-evidence/agent-tests.log` and `mac-build.log`. Full integration testing belongs to the epic integration gate.

These two sessions used `composer-debug-start message`, `composer-debug-text <input> final 0`, real Claude participants/tools, and `composer-stop`. Synthetic finalized words entered the production transcript decoder and session path; no microphone audio, Soniox network request, native field insertion or phone reinstall was performed. The convenience input labels words German even for the English utterance; this is not an ASR language-detection check. The previously reported Mac Accessibility insertion gap remains. Two useful outcomes establish this bounded repair, not universal prompt reliability.

After the trials, cancellation restored Message mode, `idle,busy:false,dictating:false,microphoneLeaseActive:false,error:""`; no active pipeline remained.

## Private evidence and usage

Full provider requests, streamed responses, tool results and document operations remain in `/Users/work/Documents/sessions/<sessionID>/room.jsonl` for the two IDs above. Bridge observations, including both final texts and the idle state, are copied to `/Users/work/Library/Caches/Legato/prompt-uat-evidence/bridge.jsonl`. These full traces can include private prompt layers and are not committed.

| Session | Successful responses | Uncached input | Cache creation input | Cache read input | Output |
| --- | ---: | ---: | ---: | ---: | ---: |
| German | 3 | 10 | 13,377 | 5,196 | 385 |
| English | 5 | 18 | 22,696 | 25,367 | 580 |
| Total | 8 | 28 | 36,073 | 30,563 | 965 |

Counts cover recorded provider usage, including tool continuations and final-pass responses; they are not a billing estimate. No further quality retries were run.
