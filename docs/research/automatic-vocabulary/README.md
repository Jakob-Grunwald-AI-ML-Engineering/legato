# Automatic vocabulary replay

Two independent corrections can qualify a spelling for a future recognition request. An explicit keyboard selection can influence a relevant suggestion on its first use. The raw word that someone corrected can still be useful in a different context.

The topic-switch replay compares recognition requests before and after business and science topic changes. [Topic-ranking results](topic-ranking.md)

The contextual-style study compares which future cleanup requests receive an emoji preference and explains how to replay internal app diagnostics. [Contextual-style results](contextual-style.md)

## Choosing the first rules

The November 2026 baseline used main revision `812df729`, Swift 6.4.2 and synthetic data. The chronological replay recorded “Email schemas today” → “Email Kemas today” and, in a separate take, “Canvas bitte anrufen” → “Kemas bitte anrufen.” Both records used the same device locale, as the existing capture adapters do when someone switches spoken languages. The original Soniox start message contained no vocabulary terms. Cleanup and Magic received no Kemas suggestion for the later technical passage “Review the database schemas.”

The keyboard comparison starts from a typed “Review database schemas” and queries the production three-slot word selector. The experiment supplies the two candidate spellings directly to compare representations. End-to-end qualification has a separate request replay.

| Representation | First prediction after “database” | First completion of “Kem” | First completion of “Bad” |
|---|---|---|---|
| Typed word pairs alone | schemas | Empty | Empty |
| Kemas and Badhri, with schemas and Canvas as global aliases of Kemas | Empty | Kemas | Badhri |
| Kemas and Badhri as preferred spellings | schemas | Kemas | Badhri |

Automatic spellings can therefore participate in prediction without suppressing the original words. A spelling proposed on screen gains selection evidence only when the user takes it. A tap, delivery of its edit and a subsequent blank chat field represent one choice.

## Offline post-recognition experiment

The shadow comparison uses the existing `TermMatcher` and five later English and German utterances. Two contain incorrect names. Three legitimately contain “schemas” or “Canvas.” Two have missing confidence. The synthetic confidences and illustrative cutoff are inputs to the comparison. The app does not run this experiment during dictation.

| Policy | Existing errors fixed (of 2) | New errors introduced (of 3) |
|---|---:|---:|
| Deliver original text | 0 | 0 |
| Apply the retrieved alias | 2 | 3 |
| Apply the retrieved alias only with confidence below 0.5 | 1 | 1 |

Even the low-confidence rule damaged a correct German reference to Canvas. These observations support keeping substitution offline. A request replay can establish which hints a provider receives. Measuring the resulting recognition or cleanup accuracy would require independent provider output.

Run `swift test --filter AutomaticVocabularyReplayTests` for the fixed offline comparison. To include the synthetic storage and request-preparation sample, set `LEGATO_VOCAB_BENCHMARK=1` for that command. All provider transports used by the replay are local and incur zero labeling or inference charges.

## Candidate measurements

The same two corrections produced `context.terms = ["Kemas"]` in the serialized Soniox configuration. The technical passage still received an empty cleanup vocabulary, and the Magic request contained no Kemas reference. In the quick-send replay the newline arrived 200 ms after the last observed edit. Badhri qualified only after a separate typing action. Replaying that action produced one contribution and removing it removed the hint.

On this Mac the original two-record fixture took 0.75 ms to load the first hint list. The candidate took 1.92 ms and stored the same 780 bytes of correction JSON. With 500 separate synthetic typing actions the candidate took 37.74 ms for a cold hint lookup and 0.10 ms for a cached lookup. The sample occupied 76,390 bytes of JSON across 500 files and 2,048,000 bytes of allocated storage on APFS. These are single-run request-preparation measurements. Histories that invalidate the cache often incur its rebuild cost. Physical-phone latency and provider recognition accuracy remain unmeasured.
