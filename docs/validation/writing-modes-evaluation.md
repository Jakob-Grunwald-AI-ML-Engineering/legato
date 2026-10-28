# Writing-mode evaluation

**Quality is not validated.** Independent review of four frozen runs at `698d0043e7a98552331b5a1a03a2aa5419152e9d` found useful outputs alongside material semantic failures. Small wording errors are distinguished from factual corruption, language changes, operational fallback and checker mistakes. Automatic success is not a quality judgment.

## Method and provenance

On 2026-10-28, an independent Codex reviewer who did not author the prompts or fixtures inspected all 64 synthetic input/contract/raw-candidate/delivered-output records. The corpus contains 16 development and 16 separately authored sealed validation cases, each used on both backends. Prompts were frozen before validation; this review performed no tuning, model calls, builds or tests.

The contract is conservative Voice; liberal, natural Message with Off/Subtle/Expressive emoji; and structured Markdown/Prompt that writes instructions and questions without executing or answering them. Contextual ASR repair is allowed because the transcript is not ground truth. Added facts, altered numeric values, lost negation, unsupported certainty and translation of intentional language switches remain failures. Optional emoji need not appear. The application deliberately uses `.promptLed` without a lexical veto; this review does not propose changing that choice.

Both standalone runners use linked production `LLMCleanupStage`, `style.prompt(emoji:)` and `PostProcessingPipeline`, outside SwiftTesting. Recorded compile/runtime hash inventories agree in all four runs. Selected actual prompt/backend source and object hashes were independently checked; CoreML build receipt and link-map provenance were inspected. The compact [results artifact](writing-modes-results.json) retains original evidence SHA-256 values, binary/fixture identities, model and deadline metadata, every fixture contract, actual chunk user messages, raw candidates, deliveries, flags and per-case review notes. Full prompt requests and exhaustive inventories remain in the original evidence.

| Backend | Exact identity and execution boundary | Applied deadline |
| --- | --- | --- |
| Apple Foundation Models | `foundation-models`, real Apple `FoundationModelsBackend`; linked external FluidAudio dependency is stubbed and unused on this route. Apple does not expose the system model weight revision. Runner SHA-256 `94e84878307e65e5b6efcc47ff6fee686f3c59772b01ae76f193ac1329488a37`. | Explicit existing user setting **10s**; product default **4s**, unchanged. |
| Core ML | `coreml-qwen3-1.7b-lut6`; repository `anemll/anemll-Qwen-Qwen3-1.7B-ctx2048_0.3.5`, revision `0977a61d00e39118aab5ed1e510f1d228df5eefd`; installed receipt SHA-256 `d18fee75634ebcac2976c92a574e5f53245e4d0129842ea077585fbd3f82df13`. Real vendored `LegatoANEMLL` from native DerivedData objects, not a stub. Runner SHA-256 `fed53acb6f6fb23edfbb3990a185fdcdef8057f4db82aad4a0856c7b41824de2`. | Backend default **8s**, unchanged. |

Recorded runtime: macOS `26.6.2 (25G83)`, arm64 macOS target and Apple Swift `6.4 (swiftlang-6.4.0.34.1 clang-2100.3.34.1)`. Local Xcode 27.1 was used as fallback from the repository's 26.6 pin. CoreML requests `.cpuAndNeuralEngine`; actual ANE placement is unverified. These are synthetic backend/pipeline runs, not ASR accuracy, physical-iPhone or whole-app model-delivery proof. A prepared owner does not establish physical residency. CoreML exposes complete responses only; cancelled partial tokens are unavailable.

## Measured results

| Run | Cases | Generated deliveries | Timeout/raw fallbacks | Automatically flagged cases / individual checks |
| --- | ---: | ---: | ---: | ---: |
| FM development | 16 | 9 | 7 | 3 / 3 |
| FM sealed validation | 16 | 14 | 2 | 4 / 4 |
| CoreML development | 16 | 15 | 1 | 6 / 6 |
| CoreML sealed validation | 16 | 15 | 1 | 4 / 5 |
| Total | 64 | 53 | 11 | 17 / 18 |

Counts describe automatic and operational outcomes, not semantic pass rates. All four runs completed 16 cases, report zero unavailable cases and zero application guard rejections, and settled every case and backend release. All four original summaries retain `validatedQuality: false`. Earlier 4s SwiftTesting failures and standalone cold fallback evidence are separate and are not pooled into this table.

### Material failures

- **Wrong final numeric value in both sealed runs:** `validation-voice-correction` dictates compartment 48, then explicitly corrects it to 84. FM delivers “Fach 48 nicht 84”; CoreML delivers “Fach 84, nein, ich meinte 48.” Both reverse the correction. CoreML development instead retains the original 23-to-32 correction verbatim: incomplete cleanup, not the same numeric reversal.
- **Unrelated content:** CoreML `validation-voice-context` transforms English baking/kneading/dough into unrelated German containing “Maus” and “Backe.” FM leaves the contextually erroneous “doe” unrepaired. Permitted contextual repair would be “dough.” CoreML development similarly retains “Marsche” and changes informal address to “Sie.”
- **Quantity changes referent:** FM `dev-voice-facts` turns “not seventeen [folders]” into “nicht mit 17 Uhr.” The automatic checks miss this semantic error.
- **Intentional language switches lost:** both backends translate mixed-language Message content; CoreML also translates a Voice passage and both translate the German question in the development injection case. Some such outputs satisfy all automatic anchors.
- **Added action:** FM `validation-markdown-list` delivers “Erstelle die Schablone ausrichten,” introducing creation instead of simply aligning the template. Automatic checks miss the addition and malformed wording.
- **Emoji fidelity:** FM `validation-message-dictated-emoji` substitutes sparkling heart 💖 for the requested red heart. CoreML development preserves ❤️ but puts it before the message despite “after.”

Smaller defects include Message-mode fillers and unrestructured spoken repairs, minor casing, and FM validation adding “unforgettable” to “made my evening.” CoreML development weakens thanks for helping paint into thanks “for the painting.” These observations are distinct from the critical numeric and unrelated-content failures.

### Checker mistakes and candidate/delivery differences

The red-heart anchor falsely reports `required-1` for correctly delivered ❤️ in FM development, CoreML development and CoreML validation. CoreML development still has a real placement defect. FM validation's 💖 is a genuine type mismatch, not this false positive. FM development's `required-2` on the mixed Message is also a false positive: “Please don't test it yet” preserves the prohibition, although translation remains a real failure. These are four individual false-positive flags across the four runs, not four wholly acceptable cases.

FM emits extra sibling `<text>` blocks in several candidates. The delivered first block correctly excludes the contradictory locker correction and unsolicited readiness statement. These are raw model defects, not delivered semantic failures. FM development's plant-thanks candidate is acceptable but late; actual delivery retains the unprocessed source. A late candidate never retroactively converts a timeout into successful cleanup. The serious-message development timeout also records a backend guardrail error; no hidden candidate can be assessed.

### Positive observations and coverage limits

Individual cases preserve conversational rhythm, uncertainty, names, negation and times; produce useful short lists and paragraphs; and maintain a serious supportive tone. Embedded prompt attacks remain written content without disclosure or answering in the sampled deliveries. Optional zero-emoji results are acceptable, but these few examples do not establish reliable differentiation between Subtle and Expressive.

**Every long Markdown case times out: four of four.** Delivered source preserves the observations and final correction, but no successful long transformation or cross-chunk assembly is demonstrated. No long-input quality claim follows from regex anchors matching preserved source. The 11 operational fallbacks likewise do not demonstrate writing-mode quality.

## Final-tree and integration boundaries

The measured tree is `698d004`. Subsequent literal closing-tag parsing and Markdown chunk-join formatting fixes are outside these frozen measurements. Prompt bytes remaining unchanged does not prove unchanged extraction or assembled delivery. A subsequent replay through the fixed production stage verified 64 exact requests, 54 raw-response extractions, 53 generated deliveries and 53 scorer results unchanged. Eleven operational cases were excluded; their original timeout/error outcomes remain unchanged. This is deterministic delivery replay, not a new native generation or latency measurement. The [replay report](writing-modes-replay.json) records source/binary hashes and commands; the [adapter source](writing-modes-replay.swift) is retained for reproducibility.

Separately reported integration checks include 1,831 affected tests passing after the formatting review fixes, a real macOS build, an iOS build with stub dependencies, and UI verification of settings/persistence. The independent reviewer did not rerun those checks. They support their respective integration surfaces and do not certify model semantics or real iPhone model delivery.

## Original evidence

- FM development: `/tmp/legato-writing-standalone/runs/dev-69694091-1457-4B90-A64E-3D6063205556/evidence.json`
- FM sealed validation: `/tmp/legato-writing-standalone/runs/validation-B2891F21-DEBE-45EA-91AE-B9083AB6BAB0/evidence.json`
- CoreML development: `/tmp/legato-writing-standalone/coreml/runs/dev-92A4FFDA-F16F-42BA-8D2A-234C580FB864/evidence.json`
- CoreML sealed validation: `/tmp/legato-writing-standalone/coreml/runs/validation-C3C443FE-A853-486A-97A0-941210229A3C/evidence.json`

These temporary paths identify the original local evidence; the companion compact JSON carries the reviewed case records and SHA-256 identities for portability.

Native settings evidence: [macOS Message](writing-modes-mac-message.png) and [iOS simulator Message](writing-modes-ios-message.png). Mode changes, Message-only emoji visibility and preferences surviving restart were exercised in isolated test applications. These screenshots precede the parser-only review fixes.

## Verification commands

The affected final-tree gate passed 1,831 tests; the formatting regressions were observed failing before their fixes. Full suites are reserved for the merge queue.

```bash
LEGATO_STUB_DEPS=1 swift test --filter 'Legato(PostProcessing|AppServices|Core|Vocabulary|KeyboardCore|Mac)Tests'
bash scripts/ci/release.sh mac-build
LEGATO_STUB_DEPS=1 bash scripts/ci/release.sh check
```

The opt-in `CleanupWritingModeEvalTests` suite is the committed model-evaluation entry point. It requires `LEGATO_REAL_ENGINE=1`, an explicit `LEGATO_WRITING_ROOT` for installed Core ML models, a `LEGATO_WRITING_MODELS` selector and a separate `LEGATO_WRITING_SPLIT=dev` or `validation`; `LEGATO_WRITING_TIMEOUT_SECONDS=10` selects the existing configurable timeout. Xcode receives these as `TEST_RUNNER_LEGATO_*`. SwiftTesting exhibited cancellation/settlement failures in the attempted FM runs, so the measured runs above used linked-production standalone runners with bounded settlement. Those failures remain separate from successful standalone deliveries. Do not treat a skipped or unavailable model as coverage.
