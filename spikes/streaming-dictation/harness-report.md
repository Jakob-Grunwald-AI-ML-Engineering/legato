# Streaming dictation spike: harness results

Question: can raw STT stream straight into the field (Apple-dictation style) with only single words flipping later? Measured on 13 real dictations (22.5 min, 1789 reference words, all English, none silent or synthetic). Aggregates only; clip text stays in `~/Library/Caches/legato/spikes/streaming-dictation/`. Re-run: see the end.

## Recommendation

- **Stream raw `stt-rt-v6` into the field; the raw stream itself is stable enough.** Words that change after first display: 1.5 to 1.6% of final words in every config. Flips behind the head (not just the last word growing): 2.4 to 3.8 words/min, of which only about 1.6 to 1.9 words/min change lexically. A typical flip reaches 3 to 4 words (about 3 s) behind the head, p90 4 to 5.7 s (nf6-ep1: 12 words).
- **Config choice barely matters for flips or lag.** Endpointing on shows slightly more flips behind the head (nf4: 3.8 vs 2.4/min), so endpointing off with the 4000 ms default is the quietest option; 6000 ms did not help (nf6-ep0: 2.9/min, ep1: 3.2/min vs 3.8). Treat these differences as within noise at 13 clips.
- **Time to first display is about 0.9 s after the word ends (p90 1.0 s)** in every config; time to final differs a lot: p50 5.3 s with endpointing, 6.0 s without (p90 6.6 to 6.8 s). After end of audio plus a `finalize`, the last words are final in about 0.4 s (p50).
- **Endpointing on gives more sentence breaks** (6.7 vs 6.1 sentences/min, 13.4 vs 14.5 words per sentence, 4.5 `<end>` tokens/min). Of 161 breaks, 127 coincide (within 600 ms); 23 appear only with endpointing on and 11 only with it off. So endpointing mostly adds extra breaks; it does not move them.
- **Add a post-pass as a separate, visible step, not part of the stream.** If a post-pass is wanted, Sonnet cleanup of the final text is the best trade: WER 6.4 to 7.3% vs 16.7% raw, final text about 2.7 to 3.1 s after audio end (p90 about 4 s), about 10 to 12% of words change on the field (9.5 to 10.5 words/min, 16 to 17% counting case/punctuation). Haiku is cheaper and quicker but less reliable (see caveats). Async re-transcription alone changes only about 4.5% of words but is slow (p50 4.8 s, p90 7.5 s after audio end) and gains little against this reference (13.7%).
- Flip budget by post-pass is large compared with the raw stream's own flips, because cleanup removes fillers and repeated words and adds punctuation and capitals. Applying it in place would be a visible rewrite, not "individual words flipping"; an alternative is to apply it only to finished sentences or on take end.

## Method (short)

- Each clip streamed in real time (100 ms chunks, wall-clock paced, plus 300 ms tail silence, then `finalize` and an empty frame) over the 4 configs `max_non_final_tokens_duration_ms` in {4000, 6000} x endpoint detection {on, off}. Config otherwise mirrors `SonioxConfig.swift` (de/en hints, language identification, Note mode context). Soniox accepted 6000 ms.
- Stream replay: field text = all finals so far + current non-finals. A "flip" is a change to words already shown (replace, delete, mid-text insert). Appending words, a partial last word completing, or punctuation appended to the last word are not flips. "Behind head" = a flip that touches more than the last word shown.
- Post-passes use the app's `dictation-take-cleanup.md` prompt in the app's whole-take input shape (no recent takes, empty field, no vocabulary; Soniox low-confidence marks not used). Haiku 5.5 and Sonnet 5.5 at low effort; reference Opus 5.5 at medium effort. Reference = `stt-async-v6` text, cleaned by Opus.
- WER: lowercase, punctuation stripped, words compared; micro-averaged over all clips.
- Latency = end of the real audio to final text (RT: `<fin>` token; cleanup adds the LLM call time; async: upload, transcribe and fetch wall time, started at the clip start in parallel with the RT run).

## Results

Clips: 13, audio 22.5 min, reference words 1789

### Real-time stream behaviour (pooled over clips)

| config | flips/min (all) | flips/min behind head | lexical behind head/min | reach p50/p90 (words) | reach p50/p90 (s) | final words changed after first display | first-display lag p50/p90 (s) | stable-form lag p50/p90 (s) | per-word final lag p50/p90 (s) | end-of-audio to final p50/p90 (s) |
|---|---|---|---|---|---|---|---|---|---|---|
| nf4-ep1 | 4.5 | 3.8 | 1.9 | 4/9 | 3.5/5.7 | 1.6% | 0.86/0.99 | 0.94/1.01 | 5.34/6.64 | 0.43/0.51 |
| nf4-ep0 | 3.3 | 2.4 | 1.9 | 3/7 | 3.1/3.9 | 1.6% | 0.87/0.99 | 0.95/1.03 | 6.00/6.79 | 0.42/0.49 |
| nf6-ep1 | 3.9 | 3.2 | 1.7 | 4/12 | 3.6/5.3 | 1.5% | 0.87/0.99 | 0.95/1.03 | 5.31/6.64 | 0.42/0.48 |
| nf6-ep0 | 4.0 | 2.9 | 1.6 | 2/6 | 2.8/5.7 | 1.6% | 0.87/1.00 | 0.95/1.04 | 6.01/6.81 | 0.43/0.50 |

### Sentences and endpoints

| config | sentences/min | mean words/sentence | `<end>` tokens/min |
|---|---|---|---|
| nf4-ep1 | 6.7 | 13.4 | 4.5 |
| nf4-ep0 | 6.1 | 14.5 | 0.0 |
| nf6-ep1 | 6.8 | 13.1 | 4.6 |
| nf6-ep0 | 6.3 | 14.2 | 0.0 |

Sentence-break agreement, endpointing on vs off (breaks within 600 ms):

| pair | matched | only endpointing on | only endpointing off |
|---|---|---|---|
| nf4: ep1 vs ep0 | 127 | 23 | 11 |
| nf6: ep1 vs ep0 | 130 | 23 | 11 |

### Arms (reference = async + Opus cleanup; biased toward async arms)

| arm | WER vs ref | latency to final p50/p90 (s) | flip budget: lexical words changed (% of RT-final words) | incl. case/punctuation | post-pass cost (USD / audio hour) |
|---|---|---|---|---|---|
| nf4-ep1 none | 16.7% | 0.4/0.5 | 0.0% (0.0/min) | 0.0% | 0.00 |
| nf4-ep1 + haiku | 8.4% | 2.2/5.1 | 14.6% (13.0/min) | 21.0% | 0.01 |
| nf4-ep1 + sonnet | 7.3% | 2.7/4.0 | 10.6% (9.5/min) | 16.0% | 0.20 |
| nf4-ep1 + async | 13.7% | 4.8/7.5 | 4.3% (3.9/min) | 9.9% | 0.20 |
| nf4-ep1 + async + haiku | 7.4% | 6.6/12.0 | 20.3% (18.1/min) | 27.7% | 0.21 |
| nf4-ep0 none | 17.0% | 0.4/0.5 | 0.0% (0.0/min) | 0.0% | 0.00 |
| nf4-ep0 + haiku | 12.3% | 1.9/5.3 | 17.2% (15.2/min) | 22.7% | 0.01 |
| nf4-ep0 + sonnet | 6.4% | 3.1/4.1 | 11.4% (10.1/min) | 16.3% | 0.20 |
| nf4-ep0 + async | 13.7% | 4.8/7.5 | 4.6% (4.0/min) | 9.6% | 0.20 |
| nf4-ep0 + async + haiku | 7.4% | 6.6/12.0 | 20.2% (18.0/min) | 27.4% | 0.21 |
| nf6-ep1 none | 16.7% | 0.4/0.5 | 0.0% (0.0/min) | 0.0% | 0.00 |
| nf6-ep1 + haiku | 9.2% | 2.1/6.5 | 13.2% (11.8/min) | 19.6% | 0.02 |
| nf6-ep1 + sonnet | 6.6% | 2.7/3.8 | 11.5% (10.3/min) | 17.0% | 0.20 |
| nf6-ep1 + async | 13.7% | 4.8/7.5 | 4.3% (3.8/min) | 9.8% | 0.20 |
| nf6-ep1 + async + haiku | 7.4% | 6.6/12.0 | 20.2% (18.1/min) | 27.5% | 0.21 |
| nf6-ep0 none | 17.0% | 0.4/0.5 | 0.0% (0.0/min) | 0.0% | 0.00 |
| nf6-ep0 + haiku | 13.1% | 2.1/6.9 | 18.8% (16.7/min) | 25.2% | 0.01 |
| nf6-ep0 + sonnet | 6.4% | 3.0/4.2 | 11.8% (10.5/min) | 16.9% | 0.19 |
| nf6-ep0 + async | 13.7% | 4.8/7.5 | 4.6% (4.0/min) | 9.5% | 0.20 |
| nf6-ep0 + async + haiku | 7.4% | 6.6/12.0 | 20.2% (18.0/min) | 27.3% | 0.21 |

RT streaming cost (all arms add it once): about 0.20 USD / audio hour (assumed rate). Reference Opus pass: 0.242 USD total.

## Caveats

- **The reference biases toward async arms**: it is async text plus an Opus cleanup, so every cleanup arm and the async arm look closer to it than raw RT. Raw RT WER (16.7 to 17.0%) is inflated further because the reference has fillers, repeats and false starts removed while raw text keeps them; it is not a pure recognition error rate.
- **Haiku is uneven on long takes without sentence breaks**: with endpointing off, Haiku WER is 12.3 to 13.1% against Sonnet's 6.4%, with word counts similar (so rewording, not truncation) on the longer clips; with endpointing on it is 8.4 to 9.2%. Not investigated further.
- 13 clips from one speaker, one machine and one network; the long clips dominate the pooled numbers (the seven clips over 110 s hold most words). Differences of a few tenths of a flip per minute between configs are not meaningful.
- Four concurrent websockets per clip: running three clips at once (12 connections) made Soniox close connections (code 1000); the final run used one clip at a time.
- Costs: Soniox per-hour rates are assumptions ($0.20/h each for real-time and async, rounded up), not read from the pricing page. LLM costs come from reported token usage at the listed prices. Whole run (4 RT configs, async, all cleanup arms, reference) was an estimated EUR 2.5 upper bound, with actual LLM spend under USD 1 in total (the post-pass cost column is USD per audio hour of dictation, excluding the real-time stream cost of about 0.20).
- Latency of the async arm excludes any real-world upload time of a long recording from a phone.
- Illustrative flip pattern (paraphrased): a non-final word is shown, then swapped for a similar-sounding word a few seconds later once more context has arrived; sentence-initial capitals and trailing punctuation settle at the same time.

## Re-run

```
cd spikes/streaming-dictation/harness
uv run python -m streaming_spike.run run --clips 2CF7        # smoke run
uv run python -m streaming_spike.run run --parallel 1        # full run (about 25 min wall, resumes from cache)
uv run python -m streaming_spike.run report                  # tables
```
Keys: `SONIOX_API_KEY` / `ANTHROPIC_API_KEY` from env or the keys file; estimate guard aborts above EUR 5.

## Product rule: walk lazily (Jakob, 2026-11-08)

Walking moves the host's visible cursor, so the product walks only when it must:
- Seed the shadow from the free before/after-cursor context; no walk at session start.
- Apply every Legato edit to the shadow directly; no read-back.
- Drift check: compare the proxy's window around the cursor with the shadow after each edit; walk only the mismatched stretch.
- Full-field walk only when an instruction targets the whole field without a selection (once, with a "reading" state). With a selection, use `selectedText`.
- Far edits move the cursor to the edit point and back without reading in between.
