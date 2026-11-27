# Vocabulary ranking across topic changes

The held-out replay recovered both the new science term and the returning client after one completed take. The recency baseline missed them throughout their respective phases. This supports enabling contextual selection for qualified terms. The product effect measured here is which spellings are present when dictation starts.

| Session and policy | Labelled term present | Wrong-topic slots | Science focus delay | Returning business focus delay | Durable name and pin present |
|---|---:|---:|---:|---:|---:|
| Development, recency | 3 / 9 | 288 / 450 | Absent | Absent | Both on 9 / 9 |
| Development, contextual | 5 / 9 | 288 / 450 | 1 take | Absent | Both on 9 / 9 |
| Held-out, recency | 5 / 10 | 320 / 500 | Absent | Absent | Both on 10 / 10 |
| Held-out, contextual | 6 / 10 | 318 / 500 | 1 take | 1 take | Both on 10 / 10 |

In the held-out session, a stale purchasing field preceded the first mention of Lysimeter. The next request included Lysimeter. The return to procurement began with an empty field, and the following request included Varento. The development run did less well when business resumed. Nordkai had already been supplied as a recognition hint and its return mention did not give the next take independent support. The wrong-topic counts also show the limit of this policy. It promotes qualified spellings with specific evidence and still occupies most available slots with the user's longer-term vocabulary.

## Chronological comparison

The replay uses two independent bilingual synthetic work sessions. The development session moves from logistics to atomic physics and back. The held-out session moves from procurement to soil science and back. They use different terms, utterances, timings of topic switches and field cues. Each starts with 62 eligible vocabulary entries covering 20 business terms, 20 science terms, 20 terms from earlier unrelated work, one high-frequency unpinned personal name and one pin. Historical frequency and last-use age follow the same distribution in all three domains. The 50-slot recognition budget forces choices.

Every take has a labelled topic and one expected upcoming term fixed before running the candidate. The current utterance is hidden until after serialization. Some takes start with a relevant field, some with an empty field and some with the preceding topic still visible. The stage-2 recency ranking and the candidate receive identical utterances and fields in the same order. Each arm has its own history. Each observed utterance receives a cue receipt from its own serialized Soniox terms, general context and prior-take background text. The production history learner processes each finalized take before the next request. No speech or text goes to a provider.

A wrong-topic slot contains a term outside the current domain and the two terms designated durable. Target coverage counts requests containing the labelled word. Switch delay counts completed takes into that phase before its first focus term appears in the serialized list. Zero means the first request had it, and absent means it never appeared during that phase. The returning business focus term was also the first business focus term. Separate controls inspect actual serialized cleanup and Magic messages. These metrics describe request contents. The supplied speech is fixed across arms.

## Selection and controls

Explicit pins and manual terms already admitted by the baseline keep their positions. The remaining slots alternate between the contextual ranking and the existing decayed score ranking. Recent takes contribute at most once per spelling per take, weighted by distance and divided by the term's historical score. Direct field matches can lead the contextual ranking. The evidence window uses the existing five-take, two-hour bounds. A recognizer cue or cleanup-generated spelling alone cannot supply independent support.

Two corrections in separate dictations still produce Kemas in the Soniox configuration. With Kemas also present in the supplied field context, the separate draft “Review the database schemas” received an empty cleanup vocabulary and its serialized Magic user message contained no Kemas. For the draft “Kemas and Badhri are attending,” the baseline serialized `["Kemas", "Badhri"]`. A prior finalized take containing an uncued Badhri changed the cleanup request to `["Badhri", "Kemas"]`. The quick chat-send fixture retained the Badhri edit, gained qualification from independent typing, and retracted it when that observation was deleted. The existing post-recognition shadow comparison still fixed two errors and introduced three when applying retrieved aliases.

## Request preparation and storage

The debug Swift replay ran on an Apple Silicon Mac with Swift 6.4.2. For each fixture the benchmark added 500 expired history entries, started a fresh request reader, and held the background history read until its first serialized request completed. At that point the contextual reader could use the recency fallback. Warm times are medians of eleven subsequent serializations after the in-memory window finished loading. The measurement includes parsing the resulting request for the offline transport. The background load is timed separately and overlaps normal app startup.

| Session and policy | Cold request | Warm median | Context hydration | Fixture JSON and JSONL |
|---|---:|---:|---:|---:|
| Development, recency | 2.89 ms | 2.05 ms | — | 105,476 B |
| Development, contextual | 3.55 ms | 2.78 ms | 5.26 ms | 105,475 B |
| Held-out, recency | 1.42 ms | 1.26 ms | — | 105,687 B |
| Held-out, contextual | 2.24 ms | 2.21 ms | 4.32 ms | 106,086 B |

The contextual window lives in memory. The held-out histories differed by 399 bytes across existing files as the two policies supplied different cues to later observations. The benchmark includes local request preparation, ordinary history and evidence persistence. It excludes model processing and audio capture. Provider calls and labeling cost were zero. Speech recognition accuracy, generated cleanup quality and physical-phone timing remain unmeasured.

Run `LEGATO_VOCAB_BENCHMARK=1 swift test --disable-index-store --filter TopicVocabularyReplayTests` for the comparison and timing sample. Run `swift test --filter AutomaticVocabularyReplayTests` for the correction, cleanup, keyboard and shadow controls.
