# Speech at a selected word

Tapping a word now captures the following spoken chunk for that location. It no longer pins a short literal transcription or appends a longer instruction to the document end. Existing punctuation, word-count and duration segments stay buffered until the existing 0.7-second gap or provider endpoint/finalization boundary. No extra silence timer was introduced. An empty endpoint after punctuation still closes the chunk.

The `hint` channel carries `event: targeted.speech`, capture ID, selected line/word IDs, observed line version and document revision, selected line/index, full words with confidence/language, tap and speech timestamps, source segment metadata and closing boundary. Its instruction asks the writing participant to interpret the speech at the selected location using ordinary version-checked document tools. Existing pin protections remain; speech is not directly pinned. Raw ASR and debug frames stay out of general agent history, and targeted partial text is suppressed from the general composer tail.

Retapping cancels the stale capture. Picking an alternative still explicitly pins it. Stop/cancel clears capture state; delayed pre-tap speech remains ordinary content. A mixed segment keeps its pre-tap prefix while retaining the targeted suffix until the structured event is emitted, including during final transcription drain.

## Physical iPhone with real Claude

2026-10-30, iPhone 17, signed Debug source `5702f6c`, session `374B2E3A-E0E5-4AA1-93F0-C66140A9ED03`, Note mode. Synthetic provider tokens entered through the actual Soniox debug decoder; both keys remained in Keychain. No microphone or recorded personal speech was used.

The initial document was “The meeting with Alex is tomorrow at ten.” The real session tap method selected Alex. Partial “Use Morgan instead” produced an empty general tail. After the final “Use Morgan instead.” and provider endpoint, real Claude applied one `replaceInLine` transaction changing Alex to Morgan. The final document remained one line: “The meeting with Morgan is tomorrow at ten.” No instruction was appended and no literal pin was applied. Error remained empty.

The tap used the internal session bridge, not a native popover interaction. This establishes shared runtime/model interpretation, not native word-popover appearance. [The full-screen endpoint](artifacts/targeted-speech/phone-result.png) shows the actual installed keyboard result. [Selected events](artifacts/targeted-speech/selected-events.jsonl) contain only synthetic document operations and the structured hint; full provider requests and vocabulary context remain private and uncommitted.

The phone was left idle in Note mode, with no microphone lease, busy participant or error. The optional motion probe was disabled (`0`).

Validation: 95 affected tests passed (17 Room, 11 Soniox, 8 Agent, 59 AppServices); signed iOS Debug build passed. Tests cover multi-punctuation capture, silence after punctuation, hidden partial text, retargeting, mixed timing/final-pass drain, resumed general speech and the actual AgentRunner/tool path. Full suites and extra review agents were not run.

## Inclusive quote-range backend

A tap and a dragged phrase now use the same `ComposerSession.select(lineID:wordID:endLineID:endWordID:timestamp:)` entry point. Missing end IDs mean the starting word. Keyboard intents retain action `tap` and add optional end IDs, so legacy word intents still decode. Reverse endpoints normalize into document order. The structured hint adds concrete end IDs, `selectedQuote`, all immutable `targetLines` and their observed `lineVersions`; quotes preserve source newlines. Existing silence capture, partial-tail suppression and version/pin protections are unchanged.

Three focused contracts passed after reproducing failures: single-word quote equivalence, reversed selection across three lines with immutable observed versions, and legacy/range intent serialization. This backend extension adds no paid calls or device-interaction claim; native phrase selection and popover presentation belong to the UI integration.

Dismissing the selection uses `clearSelection` / keyboard `deselect`. Buffered speech is dropped, and timestamp-bounded in-flight speech from before dismissal is discarded until the existing boundary; it never reappears as general dictation. A focused RED→GREEN dismissal regression passed with the 35 affected tests.
