# Independent conversion experiment

This directory contains a synthetic single-decoder-block experiment and a separate launcher for the pinned upstream ANEMLL full-model converter. It contains no trained cleanup model. Python 3.12.10, exact direct dependencies and `uv.lock` pin the environment for Apple Silicon macOS; it is independent of the app's Swift dependencies.

## Recorded result

On an M1 Pro running macOS 26.6.2, the independent Qwen3-0.6B-shaped block exported fixed decode1 and prefill64 MLPrograms in 1.52 s and 2.13 s. Each package was approximately 32.6 MB. The conversion/validation process high-water RSS was 954,056,704 bytes. These are synthetic Mac observations, not iPhone or full-model performance.

Full-geometry numerical validation failed its predeclared state tolerance: `atol=0.005, rtol=0.02`. CPU_ONLY had 508 of 2,097,152 elements outside tolerance (max absolute error 0.03417969); CPU_AND_NE had 10 (max 0.02539062). Earlier output comparisons passed `atol=0.02, rtol=0.02`, but the state failure stops that run; later positions/reset are not thereby validated for the full geometry. Tolerances were not relaxed. See the [raw result](results/synthetic-single-layer-mac.json).

A separate estimated Core ML decode compute plan preferred 151 operations on ANE and 57 on CPU, with 331 unknown. This is anticipated placement, not observed dispatch, iPhone Instruments evidence, or a claim of ANE-only execution. See the [plan](results/synthetic-compute-plan-mac.json).

The original targeted suite passed 21 contracts, including a real Core ML small-geometry prefill/decode/reset check. Three later strict-quantized-opt-in contracts were observed red then green; the affected parity/prefill check passed all 10 tests, with Ruff clean and strict Pyright at zero errors/warnings. The tests first caught a real export defect: a tensor-driven dynamic slice wrote decode position 64 into KV slot 0. The implementation uses explicit position-mask updates and a full static slice assignment instead. Direct buffer `copy_` was rejected by coremltools 9; `MLState.read_state` returned float32 bridge arrays, and reset writes preserve that runtime dtype. The retained regression catches the original corruption; no test or threshold was weakened.

## Reproduce

```bash
uv sync --locked --extra full
uv run --locked --extra full pytest checks -q --basetemp artifacts/pytest-local-run
uv run --locked --extra full ruff check .
uv run --locked --extra full pyright
uv run --locked --extra full python convert.py --geometry tiny --include-ne --output artifacts/tiny-local-run
uv run --locked --extra full python convert.py --include-ne --output artifacts/qwen3-local-run
```

Use a fresh `--basetemp` and output directory per run so earlier diagnostics remain intact. The Core ML regression requires Apple Silicon macOS 15+. Run from this directory. The CLI refuses export when fewer than 3 GiB reserve plus 192 MiB artifact budget are available. The installed base environment occupied 458 MiB; the final full environment including the pinned type checker occupies 743 MiB on this machine. Package-manager cache and external Core ML caches have separate overhead.

`Geometry()` uses the pinned source config's hidden 1024/intermediate 3072, 16 query heads, 8 KV heads, head dimension 128, context 2048, RoPE theta 1000000, RMS epsilon 1e-6. The reference uses independent float32 full-prefix matrix equations; the exported implementation uses 1x1 convolutions and individual attention heads. Both use deterministic synthetic weights (seed 39) and input (seed 1901). The block includes Q/K RMS normalization, RoPE, GQA, input/post-attention RMS normalization, SiLU-gated MLP and residuals. It omits token embeddings, final norm/head, tokenization, 28-layer composition, quantization and language generation. Weights occupy 31,461,888 bytes FP16; two KV states occupy 8,388,608 bytes. A full 28-layer cache at this context would occupy 224 MiB before overhead.

Fixed prefill and decode exports have separate state objects. The Python validation explicitly transfers state values with `read_state`/`write_state`; it does not prove cross-function state aliasing in an iOS runtime. Validation compares a 64-token prefill, positions 64/65/66, 64 single-token predictions against prefill, complete state contents, and replay after reset. The small geometry passes all these checks; the full geometry currently fails state tolerance before later checks complete. No token/s number is meaningful for this artifact.

## Original-weight architecture parity

The [trained-weight regression](results/original-weight-prefix-parity-mac.json) passed all nine selected prefixes (de/en/mixed, token counts 1/8/final). Original HF float32 versus unquantized ANEMLL PyTorch float16 stayed inside the predeclared logit `atol=0.10, rtol=0.02` and matched the exact top1 token. Maximum absolute logit error was 0.0386353. This validates a narrow original-weight architecture/layout path before quantization; it does not validate Core ML lowering, batch prefill, full generated responses or cleanup quality. The prefixes are newly authored nonpersonal spike regressions, not a sealed holdout. The run took 61.47 s with 4.98 GB process high-water RSS at nice 10/four torch threads; subsequent defaults use two threads.

```bash
uv run --locked --extra full python validate_original.py --upstream ../.cache/Anemll-Anemll-f4ad26d --source artifacts/qwen3-06b-full/source
```

Strict Pyright is enabled. Narrow documented exceptions contain incomplete Core ML/PyTorch/HF annotations at the integration boundary; numerical/cache/gate modules remain checked. The current check reports zero errors and warnings. This does not replace the actual Core ML regression.

## Full checkpoint conversion

```bash
uv sync --locked --extra full
uv run --locked --extra full python full_convert.py --upstream ../.cache/Anemll-Anemll-f4ad26d --output artifacts/qwen3-06b-full-local-run
```

An additional FP16 route reuses the verified source without downloading another checkpoint:

```bash
uv run --locked --extra full python full_convert.py --upstream ../.cache/Anemll-Anemll-f4ad26d --precision fp16 --source-existing artifacts/qwen3-06b-full/source --output artifacts/qwen3-06b-fp16
```

The pinned shell parser does not implement its advertised `--no-lut` flag. This runner disables quantization by passing empty strings to the actual `--lut2`/`--lut3` parser options. FP16 and LUT6 outputs have separate directories and evidence; they are not interchangeable memory/quality measurements. The FP16 variant completed in 570.67 s with 7,660,290,048 bytes sampled summed child-process RSS and 4.81 GB summed intermediate file sizes. Summed RSS may double-count shared pages. Its compiled trees total 1,509,661,085 bytes; the complete 31-file install set totals 1,525,607,069 bytes excluding the manifest. The [exact artifact manifest](results/qwen3-06b-fp16-artifact-manifest.json) pins file SHA256/precision and modelValidation=failedNumericGate;prefixTop1Matched. It is explicitly unvalidated experimental material.

The [compiled CPU_AND_NE gate](results/compiled-fp16-ne-parity-mac.json) and [second-prefill cell](results/compiled-fp16-ne-second-batch-mac.json) matched all 15 top1 tokens but failed 9 of 15 numeric rows at the unchanged 0.10/0.02 tolerance (max error 0.686305). The source-matched controller never compares head(prefill-output): the pinned converter deliberately skips its final norm. Instead it checks infer after 64-token and 128-token prefill, using the same shared state across chunks/functions. A two-test regression was observed red then green for this validation rule. The second case includes a nonzero-start batch at 64; its three top1 IDs match, but numeric drift remains above the gate.

CPU_ONLY gives a wrong first-prefix token even with the exact shared-state pattern; an earlier CPU_ONLY validator also exited 139 in its batch phase. That initial controller had the subsequently corrected prefill-output assumption; its missing batch result is not a numerical verdict. Preserve this diagnostic separately from CPU_AND_NE results, and do not claim CPU_ONLY or strict numerical clearance.

```bash
uv run --locked --extra full python validate_coreml.py --compute cpu-and-ne --output artifacts/qwen3-06b-fp16/coreml-parity-ne-reproduction.json
```

Use `--extra full` consistently for full conversion/validation; an environment sync without it can remove optional libraries. The separate [LUT6 conversion](results/full-lut6-conversion-mac.json) completed at 3,740.51 s with 8,240,201,728 bytes sampled summed child-process RSS and 3,789,870,161 bytes of intermediate outputs. Its [strict compiled gate](results/compiled-lut6-ne-parity-mac.json) failed all 15 numeric rows at unchanged atol 0.10/rtol 0.02; 12/15 top1 IDs matched, with max logit error 4.430288. It includes both 64-token and nonzero-start second-prefill transitions, using shared state. Quantized validation requires explicit opt-in; it does not relax any acceptance criterion or define a broader quantized quality pass.

```bash
uv run --locked --extra full python validate_coreml.py --model artifacts/qwen3-06b-full/converted --source artifacts/qwen3-06b-full/source --compute cpu-and-ne --prefill-batches 1 2 --strict-quantized-gate --output artifacts/lut6-ne-reproduction.json
```

The [LUT6 manifest](results/qwen3-06b-lut6-artifact-manifest.json) pins the 31-file, 796,582,149-byte install set and labels it failedStrictNumericGate;prefixTop1Mismatch. Neither converted precision has strict numerical or device clearance.

This separate path downloads Qwen/Qwen3-0.6B revision `c1899de289a04d12100db370d81485cdf75e47ca` and invokes ANEMLL revision `f4ad26d061dc2e426faa19f81c367343bdeb9f0d` for context 2048, batch 64, two chunks, FP16 embeddings, LUT6 (per-channel 4) FFN/head. Use the pinned checkout produced by the parent spike's setup script; changing that checkout requires recording new provenance. The runner verifies its 199-file source dependency closure against the committed GitHub-anchored manifest before output/download/conversion, rejects mismatches and redirects generated Python caches outside the checkout. Historical conversions predate that guard; current post-conversion source verification is recorded separately, without rewriting their launch provenance. The runner records source/converter SHA256 hashes and durable runner/child PIDs, streams checkpoint checksums, samples child-process-family RSS every 0.5 s, and requires 11 GiB free (8 GiB work + 3 GiB reserve). It does not delete caches or kill jobs.

The environment uses torch 2.7.0 while upstream requirements specify 2.5.0; that difference remains in the report. `--skip-check` avoids replacing the locked environment through upstream auto-setup, and `--skip-anemll-dedup` avoids optional Rust-tool downloads. A zero converter exit is recorded as `converted_unvalidated`: independent original-weight/tokenizer/output parity and iPhone execution are still required. Never treat that status as completing #39.

Full conversion writes `conversion.json` before download and at launch, logs upstream output, and records failed exceptions. If monitoring fails while its child still runs, the durable report identifies that PID; inspect it before attempting any restart. Do not run two converters into one output directory.

## Exact-input verdict identity

The [bound FP16 report](results/compiled-fp16-ne-parity-bound-mac.json) and [bound LUT6 report](results/compiled-lut6-ne-parity-bound-mac.json) replace the unbound reports as the manifest-linked verdicts. Before inference they hash the source checkpoint/tokenizer/config, all selected compiled-tree files/YAML, prefix fixture, validator/helper code, lock/runtime versions and selected options. Reports exclude output/manifests to avoid circular identity. Both reruns reproduce the numeric failures; the earlier reports remain retained.

The frozen final gate passed 31 tests (eight upstream NumPy warnings), Ruff, strict Pyright and syntax checks. Six new regression failures were observed before the provenance fixes; a pinned-source positive control also passes. Tests use the setup script's pinned checkout for the converter dependency fixtures. See `artifacts/final-provenance-gate.log` for the complete local gate output.

## Evidence boundary

Tracked phone fixture aggregates retain two foreground Gemma completions with quality failure, two Foundation Models completions with fixture-quality success, MLX CPU compilation failures/timeouts, and separate Gemma preparation/reload failures. Separate Foundation Models and warm Qwen3-1.7B Action Button public fixtures completed with background entry/inference/settlement and quality passed. Qwen cold-background preparation expired and is retained as a diagnostic outside the accepted contract. The user selected model preparation through existing microphone warmup/readiness with the same configured lease retention; only ready-state background cleanup is required. The spike used manual foreground preparation and has not implemented shared mic/model readiness or expiry. Its later foreground model-cold load and warm runs remain distinct. Three foreground synthetic 300/500/800-token input cells deliberately stop at 128 output tokens and carry no cleanup-quality result. These narrow signed-device observations are not an observed ANE dispatch, complete stateful Core ML background matrix, full-device memory, broad cleanup quality or production integration pass. Foundation Models token/phase metrics and system-service memory are unavailable. The research report retains the exact lifecycle, thermal, encoding/parity-validation and failure boundaries. See [the research assessment](../../../docs/research/ane-cleanup.md) for remaining acceptance criteria and conversion estimates.
