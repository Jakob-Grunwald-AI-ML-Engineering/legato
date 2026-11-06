# Only my voice: measured feasibility spike (#242)

**Subsequent integration:** the app exposes the requested experimental option; see [Only my voice](../../docs/uat/voice-isolation.md). The results below remain the evidence for its accuracy limits.

**Spike recommendation:** Explicit enrollment identifies the intended person more reliably than first-voice or dominant-speaker assumptions, but this CAM++ v2 gate rejects target-speaker windows or admits other-speaker windows too frequently to justify destructive dictation filtering. Three-second accumulation does not resolve the held-out failures. This is a no-go for the measured gate, not a claim that all enrollment approaches are infeasible.

No provider calls, private recordings, microphones, app settings or production dependencies are involved. Provider spend: **€0**. This spike reads downloaded public corpus files locally. It does not transcribe or insert text.

## Run

Requires Apple Silicon macOS, Xcode command-line tools with Swift/CoreML/AVFoundation, and uv. Measured with Apple Swift 6.4.2, Python 3.13.7, M1 Pro (10 cores), 32 GB RAM. Dependencies are system frameworks and Python stdlib; uv.lock contains no third-party Python packages.

```bash
cd spikes/only-my-voice
uv run python prepare.py
uv run python prepare_sentences.py
bash run.sh
```

Explicit preparation downloads about 30 MB of models/digits and the official 346 MB LibriSpeech archive; it extracts only 18 sentence clips. The default run performs no download or provider calls and fails clearly when assets are missing. Assets and binaries stay ignored under `.cache/`; a Python environment stays under `.venv/`. No credentials are needed. CoreML's system compilation caches can make subsequent model loads faster. Do not compare these single-run load times as cold-start guarantees.

An existing official archive can be reused before running the benchmark:

```bash
cd spikes/only-my-voice
uv run python prepare.py
uv run python prepare_sentences.py --archive /absolute/path/test-clean.tar.gz
swiftc -O Sources/main.swift -o .cache/voice-spike
export ONLY_MY_VOICE_OUTPUT_DIR="$PWD/.cache/recomputed"
mkdir -p "$ONLY_MY_VOICE_OUTPUT_DIR"
.cache/voice-spike . - --cpu-only
uv run python evaluate.py "$ONLY_MY_VOICE_OUTPUT_DIR/embeddings-digits-cpu.json" --output-dir .cache/recomputed
.cache/voice-spike . .cache/sentences/manifest.json --cpu-only
uv run python evaluate.py "$ONLY_MY_VOICE_OUTPUT_DIR/embeddings-sentences-cpu.json" --output-dir .cache/recomputed
```

For the optional requested CPU/GPU comparison on digits, use `bash spikes/only-my-voice/run.sh --compare-gpu`. Each run writes to a fresh ignored `.cache/run.*` directory and prints its path, preserving reviewed results. `.cpuAndGPU` requests eligible compute units; it does not establish actual GPU placement. CPU-only was faster in this measurement. iPhone execution, background behavior, energy consumption and thermal behavior remain unmeasured.

`results/scores-*.json` retain every scored window and its six enrollment cosine scores, timing and split, without bulky embedding vectors. `results/summary-*.json` retain thresholds, counts, per-target results and policy comparisons. Ignored `results/embeddings-*.json` allow regeneration of policy comparisons locally. Reviewed results remain unchanged by run.sh. Independently recompute accuracy from the committed scores, offline and without models:

```bash
uv run --offline python evaluate.py results/scores-sentences-cpu.json --output-dir .cache/score-check
```

The evaluator prints a compact per-duration table and the summary file path; full JSON remains in the generated files. It labels the pooled cutoff separately from each duration’s calibrated operating points. Unknown run.sh flags fail with usage before any model work.

Score-only recomputation intentionally reports no ordered-policy simulation (embedding vectors are absent); the core thresholds, trial counts and rates remain reproducible.

## Data and method

- FSDD: six contributed speakers, ten digits each. Take 5 is enrollment, take 6 calibration, take 0 held-out test. Digits are concatenated in numerical order within a speaker/take; windows can cross digit boundaries. These are naturally recorded human voices, not synthetic speech, but concatenated isolated digits are not conversation. Original audio is 8 kHz, resampled to 16 kHz for the model.
- LibriSpeech test-clean: six speakers, one whole sentence clip per split, with **three distinct chapters per speaker**. Enrollment/calibration/test share no clips or chapters. Enrollment is about 10–12 seconds. Held-out clips include one 20-second recording. See `results/sentence-provenance.json` for clip IDs, exact durations, archive and clip checksums. This is read English, not real two-person dictation.
- A normalized enrollment embedding is extracted from each whole enrollment recording. Each calibration/test recording is divided into non-overlapping 0.35, 1, 2 and 3 second windows; trailing incomplete windows are omitted. There is no VAD, so windows may contain pauses. A positive trial compares the window to its own enrolled speaker; five negative trials compare it to the other profiles. Rates count **audio windows**, not words. Negative trials reuse windows across profiles and are not statistically independent.
- The pooled threshold minimizes balanced classification error on calibration only. Ordered-policy comparisons use this same threshold. Additional operating points are calibrated separately for each window duration: minimum balanced error, and the highest threshold retaining at least 99% of calibration target windows. Grid resolution is 0.01 cosine. No threshold uses held-out test scores. Small calibration samples can overfit badly; “99% calibration retention” is not a test guarantee. See worst-target and trial counts in the JSON.
- Ordered-policy probes concatenate two target windows and three other-person windows, in both orders, for all 30 target/other pairs. Enrollment compares against the target profile. Automatic-first-voice compares against the first window. Dominant clustering assigns each window to the closest existing seed above the threshold, or creates a cluster, then retains the largest final cluster. These are simulated ordered-window policies, not Soniox diarization or a complete automatic learning system. Their shared enrollment-calibrated threshold is a simple comparison baseline, not a tuned optimum for window-to-window clustering. Dominant selection requires the complete sequence and is noncausal.

## Findings (2026-11-05)

Sentence CPU-only held-out results, with thresholds selected independently for each duration:

| Window | Balanced: intended retained | Balanced: others rejected | High calibration retention: intended retained | High calibration retention: others rejected |
|---|---:|---:|---:|---:|
| 0.35 s | 148/233 (63.5%) | 943/1165 (80.9%) | 232/233 (99.6%) | 99/1165 (8.5%) |
| 1 s | 69/80 (86.3%) | 384/400 (96.0%) | 79/80 (98.8%) | 257/400 (64.3%) |
| 2 s | 36/40 (90.0%) | 199/200 (99.5%) | 39/40 (97.5%) | 194/200 (97.0%) |
| 3 s | 23/26 (88.5%) | 130/130 (100%) | 23/26 (88.5%) | 130/130 (100%) |

The worst speaker at the two-second high-retention operating point retains only 83.3% of their windows; at three seconds, 75%. Near-perfect pooled other rejection can hide poor target-speaker window retention. At one second, the high calibration-retention threshold admits 35.8% of other-speaker trials. These clean, small fixtures do not establish robustness to noise, cross-device microphones, language variation or overlapping speech.

For ordered sentence windows, enrollment is invariant to who speaks first (100% target retained, 70% others rejected in this deliberately small subset). Automatic-first-voice when the other person starts retains only 5% of target windows and rejects 5.6% of other-person windows. Dominant-cluster selection also follows the wrong person when the other person speaks more. Neither assumption supplies the meaning of “my voice.” Rates use the pooled calibration threshold, hence differ from the per-duration table.

On sentences, requested CPU-only median inference is 8.3/19.5/36.5/51.4 ms for 0.35/1/2/3-second windows, with p95 13.9/21.9/42.7/66.1 ms. Peak process RSS is 171,425,792 bytes (~163.5 MiB), including model loading, profiles and retained trial embeddings. This is not incremental app memory. The first enrollment inference is 238 ms after model loading; the recorded digit run requesting CPU/GPU takes 553 ms for its first enrollment inference after model loading. Timings are single-process observations with shared system caches, not controlled cold-start benchmarks.

A 1/2/3-second gate needs at least that much audio **plus inference** before its first identity decision, even if ASR already has words. It must buffer earlier text/audio or risk exposing wrong-speaker text. This spike does not implement alignment to Soniox provisional/final tokens, reconnect handling, cross-window smoothing, or voting. Longer accumulation improved some tradeoffs but did not validate a safe destructive threshold on held-out chapters.

The rejected-window energy audit (`results/rejected-window-energy.json`) shows the one-/two-/three-second failures contain substantial signal: RMS −22.5 to −26.7 dBFS, with 34–62% of 20 ms frames above −35 dBFS. The 0.35-second failure has much less energy. This is an energy check, not speech annotation, VAD or word scoring; do not translate rejected-window rates into lost-word rates. Optional audit reproduction requires ffmpeg on PATH:

```bash
uv run python audit_failures.py .cache/sentences/manifest.json
```

LibriSpeech chapter separation does not guarantee distinct recording sessions. Training-corpus overlap of the public pretrained encoder was not audited.

## Next decision

Keep #242 open for product acceptance. A further design could map a confidently enrolled identity to a diarizer label and reuse that identity, with conservative uncertain-state buffering and explicit short-take behavior. That is unmeasured here; it must handle label switches, interruptions and overlap. Real, authorized two-person acoustic checks on Mac and iPhone, and word-level replay through the actual insertion path, are still required before shipping a filter. This spike should not add Settings or enrollment UI to imply the feature works.

## Attribution and licenses

- [FSDD](https://github.com/Jakobovski/free-spoken-digit-dataset/tree/26eb9aaf76e81b692f806f9140c2d2777410d7a1), Jakobovski and contributors, [CC BY-SA 4.0](https://creativecommons.org/licenses/by-sa/4.0/). No blanket recording-consent assertion is made beyond its public contribution and licensing. Audio is downloaded, not committed. `results/assets.json` records immutable source URLs and SHA256 hashes.
- [LibriSpeech/OpenSLR 12](https://www.openslr.org/12), Vassil Panayotov, Guoguo Chen, Daniel Povey and Sanjeev Khudanpur, [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/), from LibriVox readings. The provenance manifest identifies the selected source clips. No audio is committed.
- [CAM++ CoreML](https://huggingface.co/FluidInference/campplus-coreml/tree/f316edbc70d9023a94aaf8965538aba4330dc28e), FluidInference conversion of FunASR CAM++, pinned revision `f316edbc70d9023a94aaf8965538aba4330dc28e`. The model card says the upstream model license applies and labels it `other`; this spike downloads models for evaluation and does not bundle or establish redistribution rights. Resolve the model's exact weight license before distribution.
- The scaling, fbank mean subtraction and normalization follow FluidAudio's [CampPlusEmbedder](https://github.com/FluidInference/FluidAudio/blob/ee78635d23d52379117554ba72358b65a0612447/Sources/FluidAudio/Speaker/CampPlusEmbedder.swift), Apache-2.0, copyright FluidInference/FluidAudio contributors. The standalone implementation uses only CoreML and AVFoundation. It deliberately avoids the older v1 implementation in FluidAudio 0.17.7: v2 corrects frontend and dynamic-length issues documented on the model card.
