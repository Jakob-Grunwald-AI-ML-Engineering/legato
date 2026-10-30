# Physical iPhone Composer UAT

Real Claude writing now works on the physical iPhone after the SSE framing and empty-tool-input fixes. Message composition, a friendly rewrite, real keyboard Insert, Email fact preservation, Prompt restructuring and a mid-session mode change passed. This round also exposed repeat-Undo and terminal-busy defects; both focused fixes passed the final native device retest. One spontaneous fallback to Apple's keyboard remains unexplained.

Tested 2026-10-30 on physical iPhone 17 `00008150-000E60360245401C`, canonical signed Debug bundle `de.gruenwald.legato`. Fixed writing run: branch commit `54779b8`, containing merged SSE fix `d778e5f` and the agent-authored empty-tool-input fix. Built locally using Xcode 27.2 because pinned 26.6 was unavailable. Credentials stayed in the existing device Keychain.

## Fixed writing sessions

| Session | Result | Evidence |
| --- | --- | --- |
| Message `5C413236-F150-4F69-BF3A-76BC59DA2D35` | Pass: German composition, friendly rewrite, actual keyboard Insert into native host field | [Room](artifacts/phone/fixed-message-room.jsonl), [native delivery](artifacts/phone/message-inserted-native-field.png), [accessibility tree](artifacts/phone/message-native-insert-tree.txt) |
| Email `5BFF548D-2DF1-4E50-B4CE-4EBCFCEB8045` | Draft facts passed; alternatives, literal spoken hint and pin action exercised; repeat Undo failed | [Room](artifacts/phone/fixed-email-room.jsonl), [correction UI](artifacts/phone/email-correction-undo.png) |
| Prompt `E5A27125-7EF0-4121-A40A-CAEB51A72D83` | Pass: CSV constraints, seven-section rewrite, Prompt→Note mode change, restored long-document rendering and native scrolling; final-pass busy indicator failed | [Room](artifacts/phone/fixed-prompt-room.jsonl), [initial](artifacts/phone/prompt-initial.png), [long restored](artifacts/phone/prompt-long-restored.png), [scrolled](artifacts/phone/prompt-long-scrolled.png) |

Message input was “Schreib Alex: Ich komme zehn Minuten später, fangt bitte ohne mich an.” The useful first output removed the instruction: “Hallo Alex, ich komme zehn Minuten später, fangt bitte ohne mich an.” A natural follow-up asking for a friendlier message and thanks produced “Hallo Alex, es tut mir leid, ich komme etwa zehn Minuten später. Bitte fangt schon ohne mich an. Danke fürs Warten!” Native XCTest tapped the actual keyboard `Insert` button. The host field contained the result and the session became `done`; `composer-insert-host` was not used.

Email preserved Morgan, Project Atlas, Tuesday, 14:30 and the updated-budget request. The English Morgan token carried confidence 0.35; the real alternatives participant produced `Mortan`, `Morgen`, `Horgan` at room sequence 16. Claude rewrote the greeting as `Hi [Morgan],`, so the draft still required recipient confirmation. The live draft's rewritten name had a new word ID without the original confidence metadata. Native alternative-popover selection was not established; the direct `composer-pick` session action was exercised.

A tap at injected clock offset 7000 ms followed by “Morgan ohne Klammern.” at the same offset produced a direct hint and pinned that entire three-word literal phrase. Short tapped speech is treated as replacement text, so this phrasing did not remove brackets semantically. A subsequent exact pick changed the first pinned word to `Morgan,`. Undo then removed that comma; a second Undo reapplied it. Room `doc.ops` sequences 774 and 776 prove adjacent undo transactions at revisions 7 and 8 without an intervening agent document edit. The polluted correction draft was cancelled instead of inserted.

Prompt initially requested a developer-oriented CSV import tool with preview, explicit column mapping, validation of every row and no production writes. All constraints survived. After Prompt→Note, a natural follow-up requested implementation sections, acceptance criteria and examples. The result covered parsing/encoding, mapping, preview, row errors, cancellation, fixtures and staging-only execution. Examples included Latin-1 “Müller”, row 42 validation and rejecting a production connection string. No HTTP 400 occurred; logged thinking-token counts were zero, so this does not establish signed-thinking replay behavior.

## Native presentation and remaining defects

Full-screen captures show the intended large Composer pane, mode/Undo/Insert/Close controls and compact tool strip, with no Legato QWERTY grid. [Before](artifacts/phone/fixed-before-message.png) and [friendly message](artifacts/phone/message-friendly.png) show the actual extension. Long content scrolled under a fixed control row without controls overlapping the text viewport. The gray rounded system cap above the flat white pane and the empty prediction row remain visible cosmetic discontinuities; no speculative layout patch was made.

During the long expansion, the keyboard unexpectedly switched to [Apple QWERTY](artifacts/phone/prompt-long-top.png). The preceding [Prompt capture](artifacts/phone/prompt-initial.png) showed Legato. No globe tap was issued between those captures. Native keyboard selection restored Legato, which then rendered and scrolled the complete long document. Cause is unproven: this is a reliability caveat, not a diagnosed extension crash.

`composer-stop` exercised the actual final-pass path. The room completed with restructure-agent usage at sequence 1357, empty pending edits at 1358, `cancel.work` at 1359 and document `done` at 1360. Device state nevertheless remained `status:done, busy:true` through eight bounded observations. Explicit cancel cleared it. Repeat Undo and terminal busy are separate defects with retained real-device evidence.

## Provider usage

Logged successful response usage for the three fixed writing sessions, including tool continuations and final-pass work:

| Session | Responses | Uncached input | Cache creation input | Cache read input | Output |
| --- | ---: | ---: | ---: | ---: | ---: |
| Message | 8 | 22 | 27,798 | 65,570 | 1,998 |
| Email | 14 | 40 | 32,441 | 182,456 | 2,908 |
| Prompt | 15 | 46 | 176,913 | 304,883 | 4,355 |
| Total | 37 | 108 | 237,152 | 552,909 | 9,261 |

These are recorded provider token categories, not a billing estimate. Earlier failed requests logged no usage.

## Preserved pre-fix baseline

| Session | Result | Evidence |
| --- | --- | --- |
| `94E85C10-2F21-401D-AC2E-5AD21E723013` | Partial-only passed; final and friendly follow-up returned `incomplete` | [Room](artifacts/phone/message-room.jsonl) |
| `1A696D20-6B5D-494D-8FEC-A3E1B7A05F77` | Email interrupted by overlapping setup install/launch; no provider verdict | [Room](artifacts/phone/email-interrupted-room.jsonl) |
| `7BC04367-4B37-48EB-8FA6-070B273FC84F` | Exclusive-handoff Message retry failed `incomplete`, raw document unchanged | [Room](artifacts/phone/message-clean-room.jsonl), [actual Composer baseline](artifacts/phone/native-composer-before-fix.png) |

Partial-only input returned revision 0, no document lines, `busy:false` and only a speculative tail. Its immediately pulled room contained no segment, document operation or Claude request. The clean pre-fix Message request ended 3.788 seconds later with the complete terminal payload `{"event":"error","message":"incomplete"}` and no response/tool/usage record. Those failures are retained separately from the successful fixed runs.

## Proof boundaries

Transcript injection entered the actual Soniox-shaped decoder/segmenter and real Composer participants; Claude calls used the real provider. No microphone audio, Soniox network socket, real-ASR quality or background liveness was tested. `microphoneLeaseActive` was false throughout. Actual native controls proved Message text-proxy insertion and long-pane scrolling; direct bridge actions proved mode, hint, pin and cancellation behavior. This is physical-device evidence, not a simulator or full test-suite gate.

The phone was left in Message mode, `idle`, `busy:false`, with no microphone lease after cancellation.

## Final native fix verification

The final signed app was rebuilt and installed from `faae6bd`, including Undo fix `ca5c209` and terminal activity fix `faae6bd`. Session `A52037CF-2E5E-4072-9570-4F21098C6630` used one bounded real Message turn. An exact pick changed `Alex:` to `Sam:` at revision 2. The actual Composer `Undo` button restored `Alex:` at revision 3; a second actual Undo tap left both text and revision unchanged. The sanitized [event excerpt](artifacts/phone/final-fixes-room.jsonl) contains one undo transaction, sequence 113. [Native capture after the second tap](artifacts/phone/final-repeat-undo.png) confirms the correction was not redone.

The real compact-strip `Stop dictation` control then ran the final pass. The room completed at sequence 210. Device state was `status:done`, `busy:false`, `pendingLineIDs:[]`, `error:""`, with the text retained for insertion. [Completion capture](artifacts/phone/final-done-no-spinner.png) shows no spinner or pending highlight. Explicit cancel subsequently left the requested [idle Message state](artifacts/phone/final-idle-state.json), with no microphone lease.

The final trial also exposed a model-quality caveat: “Schreib Alex: Wir treffen uns morgen um zehn.” remained verbatim both live and after the final pass. Claude's live response described the line as already complete instead of removing the writing instruction. This does not invalidate the earlier useful ten-minute Message and friendly rewrite, but instruction/content separation was inconsistent across these two utterances. No additional quality retry or lexical guard was added.

This final regression session logged five successful provider responses: 16 uncached input tokens, 17,666 cache-creation input tokens, 22,316 cache-read input tokens and 617 output tokens. The root session owns tracker follow-up and the full gate; this UAT agent changed only report/evidence files.

## Artifact privacy and validation

All linked `*-room.jsonl` files are selected, sanitized event excerpts. System/personal/vocabulary prompt layers and request message bodies are omitted; streamed token deltas are omitted while terminal provider events, usage, document operations, synthetic transcripts, hint/alternative events and exact errors retain their original sequence numbers. Full original room traces remain in the untracked private directory `.claude/tmp/phone-uat-private/` in this worktree, with directory mode 0700 and original files mode 0600. The actual device session logs were not modified.

The seven sanitized excerpts contain 1,008 parseable JSONL records. A local scan found no API-key/header patterns, prompt preference/vocabulary headings or the original private vocabulary marker. Screenshots show only the synthetic native-field exercises. Earlier pre-fix evidence remains clearly separate from fixed-run acceptance.
