# Local fine-tuning for Legato

Research date: 2026-10-26. Scope: the research portion of [#20](https://github.com/Jakob-Grunwald-AI-ML-Engineering/legato/issues/20), with [#19](https://github.com/Jakob-Grunwald-AI-ML-Engineering/legato/issues/19) and [#22](https://github.com/Jakob-Grunwald-AI-ML-Engineering/legato/issues/22) as product context. No model conversion, training, inference experiment, or device spike was run. This does not complete #20's experiment criterion.

## Decision

**Go for a later, bounded cleanup-LLM experiment; defer speech-model training; avoid building a new dependency on Apple's current custom-adapter toolkit.** MLX QLoRA on Qwen3 0.6B is the strongest first candidate because Legato already supports that model family on both platforms. Train on the Mac and transfer only the adapter privately to the phone. Keep current prompting as the default; use prompting with explicitly supplied vocabulary as the no-training comparison before claiming an adaptation advantage.

Separate two hypotheses:

- **Task specialization:** can a small bilingual model learn faithful Message-mode cleanup, self-corrections, number normalization, and structure better than the current prompt?
- **Personalization:** after that, do one person's approved corrections improve their results beyond the same model plus a vocabulary?

A task fine-tune beating today's prompt would not establish that personal fine-tuning is worthwhile. Names and frequently changing terms belong in an editable vocabulary first.

## What the repository establishes

Inspected checkout: `e866e8e`. [Package.swift](../../Package.swift) pins FluidAudio 0.17.7 and mlx-swift-lm 3.32.3. [MLXModels.swift](../../Sources/LegatoMLX/MLXModels.swift) offers Qwen3 0.6B at about 351 MB on iOS/macOS, Qwen3 1.7B at about 984 MB on macOS only, and Gemma 3 1B at about 772 MB on both. These are catalog download sizes, not peak memory measurements.

The current prompt records Qwen3 1.7B improving from 31% to 44% on the 16 held-out strict-cleanup fixtures after prompt tuning. The repository has 32 dev and 16 held-out cases; these are regression material, not a sufficient personalized training corpus. These are historical results recorded in code, not rerun in this research. See [CleanupPrompt.swift](../../Sources/LegatoPostProcessing/CleanupPrompt.swift) and the [eval harness](../../Tests/LegatoPostProcessingTests/Eval/CleanupPromptEvalTests.swift).

Important integration boundaries:

- [CleanupRegistry](../../Sources/LegatoMLX/CleanupRegistry.swift) falls back from MLX while the iOS app is in the background. A trained adapter does not change that. It may improve Mac and foreground-phone cleanup without improving background Action Button dictation.
- The default pipeline grants each stage four seconds. The direct eval times cleanup without applying that deadline. A better offline score must therefore be followed by pipeline timeout/fallback measurements.
- The current guard limits word drift to 25%, rejects missing sentences and long unmatched runs, and collapses number runs without checking numeric value. It is neither a Message-mode meaning checker nor a guarantee against changed amounts.
- The current [history schema](../../Sources/LegatoCore/History.swift) has text, locale, engine and duration; it does not contain aligned raw-ASR/approved-correction pairs or retained audio. A history entry alone is not a supervised training example.
- The cleanup stage accepts vocabulary and the eval supplies fixture terms, but production `CleanupRegistry` passes none and `NemotronEngine` does not call `setCustomVocabulary`. App vocabulary integration remains #19's work; an experimental vocabulary baseline must supply its terms explicitly.
- MLX's backend currently loads a base model without a personal adapter. Library support is available; app wiring and private adapter lifecycle remain work.

## Options

| Option | Data and training | Deployment, memory and size | Assessment |
|---|---|---|---|
| Prompt + vocabulary, no training | Approved terms and examples; no optimizer | Current backends; vocabulary storage is small; ordinary inference cost remains | Baseline and first choice for names/jargon |
| MLX LoRA/QLoRA | Mac-local paired text examples; Python mlx-lm or Swift training support | Existing Qwen base plus a small adapter; phone inference still needs foreground GPU and device memory proof | Best candidate for a later cleanup experiment |
| Foundation Models custom adapter | Apple's rough guidance: 100–1,000 basic-task or 5,000+ complex-task examples; Mac 32 GB+ or Linux GPU | About 160 MB per adapter, tied to one system-model version; deployment entitlement | Avoid as a new long-term dependency under the current toolkit notice |
| S1-mini | Already trained task specialist; local conversion would be a separate experiment | Qwen3 0.6B architecture, official BF16/GGUF artifacts; English-only declared support | Useful English comparator, not a verified bilingual solution |
| FluidAudio vocabulary biasing | A term list, no training pairs or weight updates | Decoder biasing in the existing speech stack | Preferred first speech-personalization path |
| NeMo speech fine-tune + Core ML conversion | Audio aligned to verbatim transcripts; a separate conversion and validation project | Training compute and full reconverted speech assets; no established drop-in phone adapter path | Later, if vocabulary cannot address a measured acoustic problem |
| Core ML on-device speech updates | Requires an explicitly updatable supported model | No documented update path for Legato's supplied ASR bundles | No-go for these existing assets; not a claim that all Core ML personalization is impossible |

### MLX: feasible route, unmeasured benefit

The official [MLX LM guide](https://github.com/ml-explore/mlx-lm/blob/4cfc6478473b0668ede3eb0cc93f2a9181a15052/mlx_lm/LORA.md) supports LoRA, quantized-base QLoRA, adapter inference and fusion. It accepts chat/completion JSONL and supports completion-only loss with prompt masking. Its older family list omits Qwen3, but the [Qwen3 implementation](https://github.com/ml-explore/mlx-lm/blob/4cfc6478473b0668ede3eb0cc93f2a9181a15052/mlx_lm/models/qwen3.py) exists; the pinned Swift [Qwen3 model](https://github.com/ml-explore/mlx-swift-lm/blob/3.32.3/Libraries/MLXLLM/Models/Qwen3.swift) conforms to `LoRAModel`.

Swift 3.32.3's [LoRAContainer](https://github.com/ml-explore/mlx-swift-lm/blob/3.32.3/Libraries/MLXLMCommon/Adapters/LoRA/LoRAContainer.swift) explicitly reads Python-compatible `adapter_config.json` and `adapters.safetensors`. Both the target layer set and rank/scale must match. This is source-backed feasibility, not proof that a particular newly trained adapter works in Legato.

A useful size estimate: rank 8 on q/v projections of the last 16 Qwen3 0.6B layers gives 655,360 parameters, about **2.5 MiB at FP32**, excluding metadata. Calculation: `16 × 8 × ((1024 + 2048) + (1024 + 1024)) × 4 bytes`, from the [base config](https://huggingface.co/Qwen/Qwen3-0.6B/blob/main/config.json). Rank 16 doubles it. Adapting more projections increases it; actual saved dtype determines bytes. Adapter size is not training RAM or inference peak RAM.

Prefer a separate adapter initially: it preserves the exact quantized base, permits a direct base/adapter comparison and supports removal. Fusion followed by quantization is a new artifact whose quality must be rechecked, not assumed identical.

**Compute:** local Mac training is supported. No reliable task-specific wall time, peak RAM, phone training budget, or quality gain was established. Use short sequences, batch size 1 and limited layers as memory controls; measure tokens/second and peak memory before approving a longer run. Phone training is not the initial product path. A Mac-trained adapter still requires a private transfer mechanism; locality does not automatically provide synchronization.

**Privacy/licence:** Qwen3 0.6B's [model card](https://huggingface.co/Qwen/Qwen3-0.6B) declares Apache-2.0. Preserve applicable model/code notices and record the exact base revision. Keep personal corrections and derived adapters local/private; an adapter can retain personal information. Do not upload personal data or enable cloud experiment tracking by default. Terms remain deletable in vocabulary; deleting a training row does not remove its influence from an existing adapter, so reset/retrain must be available.

### S1-mini: task reference, English comparator

[S1-mini's model card](https://huggingface.co/superwhisper/s1-mini) declares English support, Qwen3 0.6B ancestry, a specific system prompt/control line, thinking disabled and plain-text output. Its intended behavior includes removing fillers and applying corrections. An empty output can be valid for filler-only input. Its vendor English benchmark cannot predict Legato's German/mixed-language results.

Conversion to MLX is plausible from the shared architecture, but was not attempted. It needs its own prompt format rather than Legato's eleven few-shots. Legato currently treats empty output as failure in both the backend and pipeline, which matters for a fair future comparison.

The actual [licence](https://huggingface.co/superwhisper/s1-mini/blob/main/LICENSE) is Apache-2.0 **plus an additional naming term** requiring continued identification as **“S1-mini” by “Superwhisper”**, with that capitalization, including integrations and derivatives. Preserve licence/NOTICE and modification notices. Do not describe it as plain Apache-2.0. Any derivative branding must retain identification as “S1-mini” by “Superwhisper”. Commercial use is described by the publisher, but shipping remains part of #7's asset-level audit.

### Apple Foundation Models adapters: lifecycle blocks the recommendation

Apple's [adapter page](https://developer.apple.com/apple-intelligence/foundation-models-adapter) currently says toolkit **26.0.0 is the last release and incompatible with OS 27 and later**. It also specifies one adapter per exact system-model version, a 32 GB Apple-silicon Mac or Linux GPU for training, approximately 160 MB per adapter, Developer Program access and terms for toolkit download, and an entitlement for deployment. Local training/testing does not require that entitlement. Its rough dataset guidance is 100–1,000 examples for basic tasks and 5,000+ for complex ones.

This makes the earlier plan to simply retrain across future OS releases incomplete: a compatible successor must exist first. Retain ordinary Foundation Models prompting as a baseline/fallback; the notice concerns this custom-adapter toolkit. No toolkit was downloaded, entitlement requested, or restricted training-asset licence accepted. The toolkit's training assets are not an open distributable replacement for Apple's system model. No Legato training-time or quality estimate is available.

## Speech: vocabulary before weight updates

In the pinned FluidAudio release, [NemotronVocabularyBias.swift](https://github.com/FluidInference/FluidAudio/blob/v0.17.7/Sources/FluidAudio/ASR/Parakeet/Streaming/Nemotron/NemotronVocabularyBias.swift) implements `setCustomVocabulary` on the multilingual streaming manager. It applies token bonuses during greedy RNN-T decoding, without changing weights or loading a separate CTC model. Partial term matches survive chunk boundaries. It may require a logits-producing decoder instead of the faster argmax-only path, so latency must be measured. Bias can over-fire, and aliases are emitted as their own surfaces rather than automatically becoming the canonical spelling.

Parakeet's [vocabulary path](https://github.com/FluidInference/FluidAudio/blob/v0.17.7/Documentation/ASR/CustomVocabulary.md) instead uses a separate 97.5 MB CTC encoder for evidence-based rescoring. That download is not its total resident-memory cost. The docs flag false replacements for short colliding terms and limitations across streaming chunks. These limitations must not be transferred to Nemotron's different implementation.

Actual speech training needs consented audio paired with faithful verbatim transcripts. NVIDIA documents [NeMo ASR fine-tuning](https://docs.nvidia.com/nemo/speech/nightly/asr/fine_tuning.html) and a [Nemotron 3.5 recipe](https://huggingface.co/blog/nvidia/fine-tuning-nemotron-35-asr); FluidAudio documents a [conversion pipeline](https://github.com/FluidInference/FluidAudio/blob/main/Documentation/ModelConversion.md). The latter is current upstream guidance, not a conversion executed against Legato's pinned assets. Neither establishes that a custom checkpoint exports unchanged through all streaming states, tokenizer/vocabulary pruning, quantization and Apple Neural Engine execution. A lightweight training adapter does not imply a lightweight deployable Core ML adapter: budget for newly exported speech assets until demonstrated otherwise.

Mac-only NeMo training, iPhone training, training time/VRAM, necessary audio hours and quality gain are **unestablished for Legato**. NVIDIA's large language-adaptation dataset examples are not personal-dictation minimums. A future speech experiment should first reproduce unchanged-checkpoint conversion parity and demonstrate a remaining acoustic problem after hotwords; do not train just to repair cleanup formatting.

Apple's [ML Program comparison](https://github.com/apple/coremltools/blob/main/docs-guides/source/comparing-ml-programs-and-neural-networks.md) explicitly lists on-device updates as unsupported for ML Programs. FluidAudio's documented export uses that format. The generic existence of `MLUpdateTask` therefore does not make the supplied ASR assets trainable on iPhone. A separately designed updatable head would be a new architecture.

The [multilingual Nemotron 3.5 conversion](https://huggingface.co/FluidInference/Nemotron-3.5-ASR-Streaming-Multilingual-0.6b-CoreML) and [NVIDIA base](https://huggingface.co/nvidia/nemotron-3.5-asr-streaming-0.6b) identify OpenMDW-1.1; [Parakeet v3](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3) identifies CC-BY-4.0. These are separate from FluidAudio's software licence. Preserve the distinction in #7; audit each exact converted artifact and any newly distributed fine-tune.

## Data and evaluation

The proposed starting dataset sizes below are **planning budgets, not proven sufficiency thresholds**:

1. For task specialization, curate roughly 500–2,000 paired examples across German, English and mixed speech, then use a learning curve rather than assuming more data fixes the task.
2. For personalization, add a distinct experiment with approximately 100–300 explicitly approved corrections from one consenting user, split chronologically. Compare the task model plus vocabulary against that same model plus vocabulary and the personal adapter.
3. Maintain unchanged-text examples alongside edits, including meaningful hesitation, quoted commands, questions and ambiguous words. A cleanup model must neither answer transcript questions nor obey instructions embedded in dictated content.

Each example should retain raw ASR, approved written target, mode, locale, optional vocabulary/context, engine and prompt/model versions, provenance and approval. Preserve a separate verbatim transcript when collecting audio for ASR: Message-mode targets intentionally remove disfluencies and are unsuitable ASR ground truth.

Cover numbers, German compounds/dates/times, names absent/present in vocabulary, code-switching, negation, corrected names/amounts, lists, emails, filler-only input, long passages and corrections crossing chunk boundaries. Include contradictions where the correction replaces an earlier fact and cases where a hesitation must not erase one.

Do not train on the existing held-out fixtures. They were already used to compare prompts, so treat them as a legacy regression set and create a **new, sealed test set** before selecting training settings. Split by original dictation/session/source template and time; related synthetic variants must stay together. Synthetic pairs can bootstrap training, but independent real dictations and human-approved targets must determine whether the model helps. Do not ask the same model to invent the data, define success and judge itself.

The current scorer checks required/forbidden strings, word distance and the strict guard. It cannot fairly establish Message-mode quality. Measure:

- Blinded human preference and manual correction effort, accepting equivalent faithful wording.
- Spoken-correction success and preservation of intended names, numbers, negation and all remaining propositions.
- Invented facts, unintended deletions, instruction following, translation and unwanted answers.
- Per-language and per-length results, including raw candidate output and actual fallback output.
- End-to-end p50/p95 latency, timeout/fallback frequency, cold load, peak memory and minimum-phone behavior with speech loaded.

Freeze the rubric and promotion criteria before the test set is opened. Higher training accuracy or lower loss alone is not a go decision.

## A later experiment, if requested

First compare current prompting with an explicitly supplied, frozen vocabulary baseline, an appropriately prompted S1-mini English comparator, and a task-adapted Qwen3 0.6B on identical frozen inputs. Qwen3 1.7B is a Mac quality comparator; Foundation Models is included only where actually available. Do not substitute missing baselines with invented scores.

A reasonable bounded starting design is rank 8, last 16 q/v layers, completion-only loss, batch size 1, capped sequence length, with a short measured pilot before a fixed training budget. These are candidate settings, not a tested recipe. Pin runtime/package versions, base/adapter revisions, seed, tokenizer/chat template, data manifests, layer keys, rank/scale and device/OS. Train for Message mode without repurposing the strict Verbatim guard as its success criterion.

Only proceed to phone integration if the adapter improves a fresh bilingual evaluation over prompting plus vocabulary without increasing serious meaning errors. Then verify Python-to-Swift parity, real pipeline deadlines and one actual foreground-phone run. Background use remains a separate architecture constraint. Personalization comes afterward and must show incremental benefit. Until those checks run, the recommendation is **promising research direction, no demonstrated Legato gain**.
