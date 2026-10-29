# Contextual iOS keyboard suggestions

Research: 2026-10-29, issue #4. Recommendation: retain tap-only insertion, match native **correction emphasis**, and compare broader-context local models before choosing an engine. The contextual suggestion backend remains unchanged; the correction treatment and native-style glyph motion are implemented separately.

## Native behavior observed

A separate scratch UIKit app enabled native autocorrection and selected English/German through its own text field's public input-mode override. Software keys were tapped; hardware typing was avoided because it changes simulator keyboard behavior.

- English `teh`: the literal appeared quoted on the left; `the` remained on a pale rounded center capsule while idle, without a finger touching it.
- English `hell`: the center correction `he’ll` also received the capsule. After `hello`, the row showed quoted `hello`, `hello’s`, and `hellos` without that capsule.
- German `udn`: the center `und` received the same persistent capsule, alongside quoted `udn` and `Usbekistan`.
- Native space accepted the highlighted English correction. Legato should retain the requested explicit-tap behavior while borrowing its appearance.

This establishes a correction-candidate treatment, separate from the temporary underline on an already-corrected word described by [Apple Support](https://support.apple.com/en-ie/104995). It does **not** expose a probability or justify treating every first-ranked candidate as confident. Recommend a capsule for the proposed correction action, distinguished from ordinary completion and touch-down feedback.

The first simulator recording showed glyph changes and fading without establishing per-letter scaling. A later physical iPhone recording confirmed new letters growing and fading in from left to right, with their ink bottoms stable while retained letters slide. Legato now follows that motion; its 0.85 initial scale and 180 ms ease-out are approximations, because the capture does not reveal Apple's hidden starting scale or exact easing. The [native rows follow-up](../validation/keyboard-native-rows-2026-10-29.md) retains the reference clip, simulator implementation clip, measurements and remaining verification limits.

Scratch evidence: `/tmp/legato-4-suggestion-research/`, including `native-english.mp4`, screenshots, `NativeSuggestions.app` and `NativeHost.swift`. Captures used simulator `BF601895-00FF-449A-9AF1-12FCE1DB811A`; it was returned to geometry verification.

Preserved exact screenshot crops show the idle [English correction row](ios-keyboard-suggestions/native-english-correction-row.png) and [German correction row](ios-keyboard-suggestions/native-german-correction-row.png), each cropped to `1206x175+0+1610` without retouching. The 54-second video remains scratch-only.

## Existing context is discarded

`SuggestionController.swift` extracts only one previous word. `WordPairModel.swift` reads `previous.last`, despite accepting `[String]`; it is a bigram, not a sentence model. Supplying a longer array alone changes nothing. `WordSuggester.swift` prioritizes vocabulary, then pairs, then dictionary completions; earlier sources can fill all slots. A contextual model needs a broader candidate pool and ranking opportunity, not merely an extra fallback after three slots fill.

[UITextChecker](https://developer.apple.com/documentation/uikit/uitextchecker) supplies completion/guess strings without confidence or QuickType candidate objects. Its text/range API permits comparing full-context versus isolated-word calls, but promises no semantic contextual ranking. `UILexicon` supplies supplementary words/shortcuts/names, not Apple's learned prediction model. Apple's [custom-keyboard guide](https://developer.apple.com/library/archive/documentation/General/Conceptual/ExtensibilityPG/CustomKeyboard.html) provides no ready-made autocorrection/suggestion implementation API. Native candidates and animations therefore require Legato's own implementation.

Apple announced an [on-device transformer for word prediction](https://www.apple.com/uk/newsroom/2023/06/ios-17-makes-iphone-more-personal-and-intuitive/) in iOS 17. That supports researching contextual neural prediction, but does not establish that QuickType uses public Foundation Models or a general chat model.

## Ranked local options

1. **Compact contextual LM versus a bounded 3–5-gram baseline.** Initially rerank a capped candidate pool; require a licensed German/English model and extension resource checks. N-grams are cheap but miss distant meaning. Google's [mobile keyboard prediction research](https://research.google/pubs/federated-learning-for-mobile-keyboard-prediction/) supports the neural model class, not Legato performance or redistributable weights. No suitable bilingual artifact was established. SmolLM2-135M is an [English diagnostic control](https://huggingface.co/HuggingFaceTB/SmolLM2-135M), not a bilingual recommendation.
2. **Apple Foundation Models as an experimental comparator.** A compile-only `-application-extension` probe passed for iOS 26 using the iPhoneOS 27.1 SDK. This establishes compiler acceptance, not extension runtime or memory safety. [Availability](https://developer.apple.com/documentation/foundationmodels/systemlanguagemodel/availability-swift.property) depends on eligibility, Apple Intelligence and assets. Use only the explicit on-device model; respect its [context budget](https://developer.apple.com/documentation/foundationmodels/managing-the-context-window) and [one-request-per-session rule](https://developer.apple.com/documentation/foundationmodels/languagemodelsession/error/concurrentrequests).
3. **Existing Qwen3 0.6B Core ML as a heavier host comparator.** `CoreMLModels.swift` pins `stemwats/anemll-Qwen3-0.6B-ctx4096-lut8_v0.3.4` at `1eb386120ff45628b308e9027cb1567e185b431d`: approximately 961 MB, 4,096 tokens. Reuse existing preparation/cancellation/settlement in an isolated foreground experiment. The [Qwen model card](https://huggingface.co/Qwen/Qwen3-0.6B) supports multilingual investigation, not keyboard suitability. Do not link it into the extension before measuring feasibility.

Apple warns that [keyboard memory limits vary by device](https://developer.apple.com/documentation/uikit/creating-a-custom-keyboard) and exceeding them terminates the extension. Avoid an assumed universal budget. Core ML/quantization does not itself prove Neural Engine execution or lower latency; [Apple's performance guidance](https://apple.github.io/coremltools/docs-guides/source/opt-quantization-perf.html) calls for measuring the actual path.

## Host and safety boundaries

The existing App Group/Darwin link handles dictation, microphone arming, refine and choices. Its active heartbeat depends on a run, preparation, lease or meeting; refine allows 20 seconds. It has no speculative request deadline, cancellation/coalescing or field revision contract. Notifications transport data while processes can execute; they do not wake a dead app or grant background execution. Suggestions must never activate audio or foreground-hop to make a host model available. A host comparator should fall back immediately when unavailable.

Bind each tap to its displayed candidate, field, context revision, original text and replacement span; revalidate before insertion. Cancel obsolete work and reject stale replies. A result arriving between touch-down/up must not change the chosen word. Space, punctuation, return and pauses must not accept suggestions.

## Next comparison

A bounded Mac host probe found `SystemLanguageModel.default` **available** on macOS 26.6.2. Six synthetic cases used fresh processes/sessions, greedy decoding, 128 output tokens, no prewarm, and a 30-second whole-process limit. All completed. The plain-text JSON protocol failed all six times because responses included forbidden markdown fences. Diagnostic fence removal exposed these actual candidate triplets:

| Earlier context; shared ending/prefix | Candidates | Time |
| --- | --- | --- |
| Sailor; `the port ` | port, ship, boat | 4.703 s |
| Developer; `the port ` | configured, port, developer | 0.863 s |
| Bakery/flour/eggs; `a ba` | bagel, bake, bakehouse | 7.442 s |
| Cave/wings; `a ba` | bat, bathtub, bathtub | 0.969 s |
| Boat workshop; `neuen Mo` | Mooring, Moos, Mohn | 0.958 s |
| Astronomy; `neuen Mo` | Mond, Mondfinsternis, Mondlandschaft | 0.986 s |

Five diagnostic rows contain three distinct, alphabetic, prefix-matching strings; that is not semantic success. Several repeat prior words or fit the sentence poorly; the cave row duplicates `bathtub`, and `Mooring` ignores the requested German. Structured-generation reruns on the same six contexts avoided markdown but only one row satisfied the three-distinct-word/prefix checks; others contained empty values or fragments such as `ba/k/e` and `Mo/on/ster`. Its first request took 7.874 s; subsequent requests took 0.669–0.691 s. Plain and structured runs used different output protocols, so their timing is not an isolated schema-cost comparison.

These are first-observed/subsequent timings, not controlled cold/warm distributions: model residency was not reset. Even the shortest observed response exceeds the proposed 150 ms contextual-update target. This prompt/protocol probe supports further bounded comparison, not shipping this model as a keyboard predictor. [Exact synthetic inputs, raw outputs and timings](ios-keyboard-suggestions/mac-foundation-models-probe.json) and both standalone Swift sources are preserved beside the screenshots. No iPhone extension, memory, energy, cancellation settlement or Qwen comparison was measured.

Next compare frozen paired contexts across current bigram, bounded n-gram, compact neural and feasible local models. Separate candidate-pool recall, ranking usefulness and free-generation errors.

Measure cold/warm keystroke-to-visible-row p50/p95, cancellation-to-idle, stale output, baseline/peak/retained memory and energy during identical typing replays. Proposed starting budgets: baseline row within 50 ms after debounce; contextual updates within 150 ms after a short pause. These are discussion targets, not achieved results. Use physical devices for the decision; [Apple explicitly cautions against simulator performance conclusions](https://developer.apple.com/videos/play/wwdc2025/259/).

Reproduce the successful compile check:

```sh
xcrun swiftc -typecheck -application-extension -target arm64-apple-ios26.0 -sdk /Applications/Xcode.app/Contents/Developer/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS27.1.sdk -module-cache-path /tmp/legato-4-suggestion-research/module-cache /tmp/legato-4-suggestion-research/FoundationExtensionProbe.swift
```

The next decisive step is a better constrained candidate/reranking protocol and a throwaway keyboard extension on supported hardware, with bounded output and cancellation logging. Host measurements do not establish iPhone extension latency or availability.
