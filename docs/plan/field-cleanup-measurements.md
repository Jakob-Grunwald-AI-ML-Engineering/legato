# Field cleanup and pause evidence

Measured offline on 2026-11-16 from the existing November streaming-dictation spike recordings. No provider requests were made. Raw speech and audio remain private and are not part of this document.

## Corpus and method

The local source is `~/Library/Caches/legato/spikes/streaming-dictation/rt/nf4-ep1/*.json`: 13 real dictations, 1,350.09 seconds, 2,010 raw final words. These are recorded Soniox v6 responses, not authored fixtures. The existing spike report describes one English-speaking speaker, one machine/network and real-time audio replay; it does not establish representative multilingual performance. The 1,789 words in that report refer to a cleaned reference, not this raw final-token count.

Corpus fingerprint: SHA-256 `c29de401f28f2a0bbc4539cbad654d7ddffb06853c98e6bac97b009fcd1b5b4d`, computed by concatenating each filename's UTF-8 bytes followed by its exact file bytes, in filename order. PCM fingerprint: SHA-256 `2854bfde8f5eec7c5f8b5bee86391a4ebd5ae349d26f10bca30f0228f1af055e`, computed by the same filename-plus-content method over matching PCM files. The standalone script below implements the original spike's word-grouping and sentence-counting conventions; it does not import or require the old spike checkout. Final tokens accumulate once, provider `<end>`/`<fin>` tokens are excluded from words, and whitespace-leading tokens begin words. Quantiles below use sorted index `floor((n-1)*q)`.

## Chunk candidates

The corpus has 150 punctuation-delimited sentences: length p50 10 words, p90 28, maximum 63. The following windows were selected as comparison candidates, then measured on the recorded final-word sequences. They are not optimized values. A window advances by size minus overlap, stops at the clip end, and includes the final short window. Audio span is last-word end minus first-word start, including intervening silence.

| Window / overlap (words) | Windows across corpus | Extra input from overlap | Audio span p50 / p90 |
| --- | ---: | ---: | ---: |
| 40 / 8 | 67 | 21.5% | 19.80 / 30.48 s |
| 60 / 12 | 46 | 19.7% | 30.60 / 40.98 s |
| 80 / 16 | 37 | 19.1% | 39.78 / 55.50 s |

The implementation selects the 60-word window with 12 words of overlap as a first policy: compared with 40/8 it reduces this replay's window count from 67 to 46, at the cost of increasing median audio span from 19.80 to 30.60 seconds. It is not an optimality claim. Its 12-word overlap remains an estimate: this analysis does not demonstrate sufficient semantic context, cleanup quality, or the absence of oscillating rewrites. The replay uses final raw words, not an evolving field with typed text or model-produced edits. Counts therefore describe the candidate windows, not actual production request counts. Keep the whole-take stop pass until runtime evidence supports removing it.

## Pause evidence

Across 1,997 adjacent-word intervals, the timestamp gap is p50 0.12 seconds, p90 0.66 seconds and maximum 29.46 seconds. There are 527 gaps of at least 0.3 seconds, 260 of at least 0.5, 193 of at least 0.7, 126 of at least 1.0 and 60 of at least 1.5 seconds. These are descriptive bins, not validated pause thresholds.

For each of 102 recorded semantic endpoints, arrival time was compared with the immediately preceding final word's audio end and the next final word's audio start (clip duration when there was no next word). Endpoint delay after the previous word ended was p50 0.582 seconds, p90 0.785 and maximum 3.053. Remaining silence at endpoint arrival was p50 0.848 seconds; 26 of 102 endpoints arrived after the next spoken word had already started. This measures lag against provider word timestamps, not independently annotated acoustic truth.

The original spike report measured initial word display lag at p50 0.86 seconds and p90 0.99 for this configuration. Consequently, neither a delayed endpoint nor absence of newly displayed words proves the microphone is presently quiet. Endpoint and timestamp-gap signals must remain distinct from microphone activity; changing the segmenter's existing gap changes segmentation and is not a justified substitute for a pause scheduling policy.

## Remaining measurements

- No acoustic speech/silence annotations or validated microphone-level threshold were found. PCM exists, but amplitude alone has not been classified against actual speech or background noise.
- No cleanup model was run on these candidate windows. Overlap quality, field-boundary behavior and long-take stop-pass redundancy remain unverified.
- No Mac jump/edit/return latency was measured by this analysis. Measure the actual queue's in-flight unit and speech-resumption delay in the built application.
- This evidence does not establish physical iPhone jump reliability or authorize its pause-time edits; those remain #294 work.

## Acoustic gate calibration

The matching PCM files are 16 kHz mono signed 16-bit little-endian recordings. For each 20 ms frame, compute RMS relative to 32768 and convert to dBFS. At each endpoint arrival, require every frame in a trailing quiet window below the candidate threshold. The table reports released endpoints and those arriving inside a final-word timestamp interval. A resumed word that already ended is not counted as currently speaking, so this differs deliberately from the 26 late endpoints above.

| Threshold | Quiet window | Released / 102 | Inside a word interval |
| --- | ---: | ---: | ---: |
| -60 dBFS | 200 ms | 10 | 0 |
| -55 dBFS | 100 ms | 48 | 1 |
| -55 dBFS | 200 ms | 40 | 0 |
| -55 dBFS | 300 ms | 33 | 0 |
| -50 dBFS | 200 ms | 64 | 1 |
| -50 dBFS | 500 ms | 32 | 0 |

Endpoint plus 200 ms below -55 dBFS is a measured conservative candidate on this corpus. It is not a universal silence threshold or independent validation: parameters were compared and selected on the same recordings, and provider word intervals are weak acoustic labels. Standalone RMS at that threshold/window falsely labels 39.22 seconds inside word intervals as quiet; require both signals and revoke eligibility immediately on microphone activity. No minimum remaining silence or future speech guarantee follows from a currently quiet frame. Microphone gain, background noise and other speakers/devices remain untested.

Reproduce the aggregate analysis without network calls or text output:

```bash
python3 scripts/dev/measure-field-cleanup.py "$HOME/Library/Caches/legato/spikes/streaming-dictation"
```

The script prints response and PCM corpus fingerprints, chunk candidate counts and spans, endpoint delays and the full acoustic candidate table. It requires Python 3.12 or newer and only the standard library. The private corpus must already exist; no recordings are generated or downloaded.
