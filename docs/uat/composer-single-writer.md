# One writer, two tempos

The composer now uses one active writer, one selected model and one conversation. Ordinary speech receives quick local corrections. Substantial drafting/reorganization waits for 2.5 seconds of quiet or the final Stop pass. Fresh partial speech resets that timer and cancels a pause rewrite; the previous provider stream retires before another starts. Explicit word/quote corrections retain full tools immediately, scoped to the target. Stop drains pending input, then asks the same writer to finish.

Settings on both platforms contain one **Writing model** selector. The saved `composer.liveModel` choice is preserved; Haiku remains the unset default, with Sonnet and Opus available. There are no independent worker switches, second structure model, or delegation tool. Auto still loads specialized writing guidance as context without changing its UI mode. System/tool definitions remain stable across phases; quick broad-edit attempts return an explicit deferral rather than a generic refresh/retry error.

## Why the architecture changed

Read-only inspection of the user's actual phone session `536307AF-9D41-4BC8-A525-CB592F8B4DA1` found overlapping editing and visible churn, but did not establish an endless feedback loop or repeated semantic reversals between agents. The 259.7-second trace contains 28 ASR segments, 57 transactions, and 25 agent edits (13 live, 12 structure), with 52 live and 28 structure provider requests including tool continuations. Both logical busy flags were true for approximately 75.9 seconds. Seven tools failed: six `invalidOperation` and one actual `versionConflict`.

At +211–231 seconds, revisions 41–51 alternate participants without new ASR. The exact reversal at revision 47→48 belongs entirely to the live agent: it inserted four words and removed them 3.8 seconds later, restoring revision 46's text. This is self-revision, not proof that two agents reversed each other. The user chose one writer as the product architecture rather than optional switches.

[Transcript-free metadata](artifacts/agent-contention/metadata.json) retains verification IDs and observed versions. The actual conflict is event `18DF0A3B-F791-4D36-B491-2B97A4BEAFC2`, sequence 3682. The self-revision transactions are `E7929349-90E7-4223-9CDF-EA06DD9C94B0` and `F1F2038A-10F2-44A3-9982-57725B2C5252`. Raw user transcripts, audio, prompts and vocabulary are not committed. Inspection did not alter the phone session.

## Focused checks

Three new contracts reproduced the old failures and pass after the change: one provider stream and selected model across quick/pause/final with terminal completion; continuing speech delaying and preempting pause work without overlap; and quick local spelling versus deferred broad edits while explicit targeted edits retain full capability. Auto's guide tests and the existing accepted-content/hint filters remain in the affected set. Final affected checks passed: 59 AppServices and 14 Agent tests. No extra reviewers or full local suite were used for this leg.

## Real provider pipeline check

The signed Mac build passed. One bounded real Claude session, `A2B0139E-EE87-4211-9F80-AFB61B0D8B60`, used debug transcript input through the actual segmenter, document, Auto writer and UI, with no microphone lease. Its five provider requests all reported `claude-haiku-5-5`; the retained Room trace had one maximum in-flight request and only the `liveAgent` writing participant. It recorded quick → quick → pause → final, then completed normally with an empty error.

The synthetic `Helo Morgan. The staging review is Friday at 2.` received a local `Helo`→`Hello` correction during the first quick turn, approximately 1.85 seconds after the accepted ASR append. The pause turn began 3.92 seconds after the last append, following the already queued quick turn and exceeding the 2.5-second quiet threshold. The final same-writer pass reached `done` approximately 1.16 seconds after Stop. Morgan, Friday and 2 remained intact; Auto remained selected throughout. No delegation or second model was used.

This establishes the real model/pipeline path with synthetic transcript input, not native ASR latency. Native microphone proof remains in [composer-native-voice.md](composer-native-voice.md). The app was left nonrecording with no busy work and reset to Message before the Mac was handed to the selection-UI agent. No phone interaction was required for this check. Exact merged Mac/phone installation and the broader integrated gate are the root session's final steps.
