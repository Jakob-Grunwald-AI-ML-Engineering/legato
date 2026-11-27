# Contextual style from everyday edits

A send key tells Legato which kind of field is active. It cannot tell Legato whether the user is messaging a friend or negotiating a contract. The offline emoji study exposes that distinction even when earlier edits were attributable to the user. Keep contextual style suggestions in research while collecting ordinary-use evidence with the internal build. Learning from grounded vocabulary corrections continues independently.

## What the app can observe

| Action | Evidence available for a later replay |
|---|---|
| Typed or selected an emoji | The iPhone keyboard can attribute an edit to a user action when the field and take still match and delivery was confirmed. Two actions in one take give one source of support. |
| Magic produced an emoji | The model supplied the change. A small exact English/German command vocabulary distinguishes a request such as “add an emoji” from “no emoji.” Other instructions remain unresolved. A request applies to that draft. |
| Cleanup produced an emoji | This is model output, including when the resulting draft was inserted. A second model output provides no independent evidence of user preference. |
| Host text changed or cleared | A settled diff can reveal an emoji change. External typing, host autocorrect and another keyboard can have the same effect. An empty field is a boundary. It cannot establish that a message was sent or that the user wanted every part of it. |
| Undo or history deletion | A deletion invalidates the take. A confirmed undo without an operation ID leaves its earlier support uncertain. The replay conservatively withholds the entire take. |

The internal Mac build can report finalized dictation, model changes, confirmed insertion and observable host edits with unknown field context. The iPhone can identify an eligible field with an explicit send return key. Other eligible editable fields have unknown context. Each platform keeps its own history. The redacted export holds event and take IDs, time, platform, action, coarse field type, instruction category, available request mode and result-to-request link, and counts of added and removed emoji graphemes. It carries no glyphs, draft, instruction text, surrounding field text or application identifier. Scope and missing values matter when interpreting counts. [Collection and replay instructions](../../../scripts/device/README.md#offline-style-evidence)

## Held-out request comparison

The fixed study uses invented English and German drafts and four chronological sessions. The first two supply history. Only the last two contain scored requests, with subsequent edits entering history in time order. The comparison observes serialized bodies from the production sentence-cleanup client through an in-memory transport. A trial cue uses an isolated writing-preferences setting in the replay process. The study checks both the system preference and the user payload, including the explicit “no emoji” instruction. No production preference changes and no provider receives a request.

Three policies share the same data. The current behavior supplies no learned style cue. A deliberately permissive comparison lets net emoji additions from any origin in two distinct takes qualify. The attribution rule requires net additions from direct typing or explicit keyboard choices in two distinct send-field takes on the same platform, followed by a later request in a send field. Two is an illustrative threshold. Both research policies abstain on an explicit instruction and in conservative line mode. Cleanup off produces no serialized body.

| Policy | Wanted cue present (of 3) | Wanted cue missed | Unwanted cue present (of 8) | Correctly omitted (of 8) |
|---|---:|---:|---:|---:|
| Current behavior | 0 | 3 | 0 | 8 |
| Two takes, any origin | 3 | 0 | 5 | 3 |
| Two directly attributed send-field takes | 2 | 1 | 1 | 7 |

Each policy serialized 11 requests. A twelfth probe had cleanup off and serialized zero requests.

In one early casual chat the attribution rule had just one qualifying take. It withheld a cue the fixture writer wanted. After a second independent choice, it supplied a cue on two casual messages and on one formal contract message in a send field. The contract message provides a concrete reason to defer enabling the rule globally. Work prose in a generic field, an unknown field, a separate Mac, explicit instructions, and the takes after undo and deletion supply additional controls. The fixtures represent one authored workload. The results measure placement of a prompt cue; generated text and individual preferences require separate evidence.

## Background review budget

Only an ambiguous Magic instruction accompanied by an emoji change could be disambiguated by later reviewing that instruction. A missing host actor remains unknowable from a diff. In this fixture, one of four ambiguous Magic takes was subsequently deleted before the simulated idle checkpoint. Three distinct candidates survived. A copied diagnostic event, model acceptance, a cleared field, and a new take on the other platform did not increase that count.

| Trial batch size | Requests ready at this checkpoint | Candidates left waiting | Estimated maximum input bytes per full batch |
|---:|---:|---:|---:|
| 1 | 3 | 0 | 760 |
| 2 | 1 | 1 | 1,039 |
| 3 | 1 | 0 | 1,318 |
| 4 | 0 | 3 | 1,597 |

The experiment assumes one idle checkpoint after these events. Actual idle intervals, model tokens, cache hits and label quality are unmeasured. For rough sizing, allow 480 UTF-8 bytes for shared instructions and a previous brief, 240 bytes for a bounded instruction excerpt per source plus the encoded UUID array. A three-observation trial allows about 1.3 kB of input before API wrapping. At a hypothetical 2–4 bytes per token that is roughly 330–660 input tokens; serialization and tokenizer behavior can change that figure. The fixture used zero model calls. An eventual reviewer would need access to eligible source material under the app's retention policy because the redacted export deliberately omits the words that might resolve an ambiguous request.

## Rerunning with evidence

Run `swift test --filter StyleEvidenceReplayTests/heldOutSessions` for the labelled synthetic comparison. The separate collected-data replay accepts the export described in the device tooling. It orders events by observed time, deduplicates overlapping exports, retracts deleted and uncertain takes, and reports counts by action, context, instruction tag and platform without printing source identifiers. At each available pre-request event it reports whether a shadow cue would have qualified from earlier independent takes on that platform. A recorded opportunity describes local request preparation. A matching result can identify a model change shown in the staged preview. The iPhone staged path records these pre-request opportunities. A buffered take can have a finalization or model result without a staged request row. Truncated captures and skipped or superseded requests can leave either side absent. The redacted log cannot reconstruct the literal request body, count billable requests or grade the user’s preference. A rotation that starts mid-take can omit prior evidence.

An ordinary-use rerun can tell us whether confirmed independent edits occur often enough to justify further work, how often context is missing, and how much genuinely ambiguous review work remains. If attribution is sparse, improve observable coverage before investing in a classifier. If direct evidence is plentiful, the next comparison needs independently characterized casual and formal messages that share the same field type. That evidence would let us test whether a narrower context rule avoids the contract-message error.
