# Legato #70/#71 isolated evaluation

Evaluation evidence supports a smaller-patch native experiment, not production delivery. Local vocabulary/version alternatives helped 9/18 synthetic repair opportunities; macOS spell-check added offers without improving useful-case coverage in this set. Both issues remain open for native behavior and user usefulness.

Revision `9e113ed85b1d24449028ac200ef71a464d1ee3e0`; macOS 26.6.2 (25G83), Swift 6.4, macOS SDK 27.0. Fixtures: exactly 12 patch scenarios and 24 authored diagnostic opportunities (8 German, 8 English, 8 mixed). Corrected contextual clues were frozen before first ranking; no fixture tuning followed results. Intent is synthetic and supplied through sentence/context or bounded vocabulary, not audio groundtruth. The ranker does not receive evaluation intent labels.

## #70: smaller field edits

Matched successfully applied standard cases P01–P04/P06 (five per variant) show lower Character replacement volume with the scratch contiguous patch. P05 is excluded: all four production baselines correctly retained canonically equivalent decomposed bytes and performed zero operations; the scratch patch normalized bytes, which is not a needed semantic correction.

| Variant | Characters removed | Characters inserted | Nonoverlapping unchanged suffix characters rewritten |
|---|---:|---:|---:|
| field-live | 254 | 256 | 244 |
| field-final | 288 | 290 | 244 |
| proxy-live | 254 | 256 | 244 |
| proxy-final | 254 | 256 | 244 |
| experimental | 10 | 12 | 0 |

For P01, `Send teh report…` → `Send the report…`, actual FieldWriter live and both proxy plans removed/inserted 76/76 Characters, including a 74-Character unchanged tail. FieldWriter final swap replaced 82/82. The scratch patch replaced 2/2 and kept that tail. This adds two modeled cursor moves and per-operation readback. Proxy deletions are interpreted in Character units and grouped; operation counts do not establish native event cost. No visible churn or latency improvement is claimed.

All 164 final records: 56 verified applied, 4 canonical no-ops, 31 safe declines, 37 uncertain landings, 36 explicit unsupported records. These denominators differ by variant and fault boundaries; aggregate operationVolume is diagnostic only and must not be used as a reduction ratio. Uncertain outcomes by variant: experimental 24, field-final 6, field-live 6, proxy-live 1. Safe declines are not successful corrections. After uncertainty the scratch session stops; FieldWriter degrades; the proxy seam has no write-result acknowledgement, so its fault cases are explicitly unsupported. Delayed typewriter timeout is captured as an uncertain plan and is not executed against falsely stale context.

Current TextTarget has no independent caret setter and ProxyOp has no movement operation. Repeated-word ownership, newer ASR suffixes, revision ordering, user edits, sent boundaries and partial-write faults were deterministic replays. Some cases are intentionally unsupported rather than supplied with a fake production baseline. FieldWriter has no sent-boundary operation, and no experimental sent-session coordinator was built.

## #71: alternatives

Actual WordAlternatives/VocabularySource/VersionWordsSource were used in both arms; the macOS arm adds actual SpellCheckerSource(PlatformSpellChecker()). Three repetitions × active/stopped disconnected rank calls × 24 opportunities × 2 arms = 288 records. Quality below counts each stopped opportunity once, not every repetition.

| Arm | Useful @1 / @3, all | Useful @1 / @3, repair-needed | Empty lists | Unnecessary offers | Harmful span offers |
|---|---:|---:|---:|---:|---:|
| Lexical | 9/24 / 9/24 | 9/18 / 9/18 | 13/24 | 0 | 2 |
| macOS spell-check added | 9/24 / 9/24 | 9/18 / 9/18 | 0/24 | 9 across 3 already-correct cases | 2 |

Five useful cases already contained the answer in fixture vocabulary and four in an authored contextual version. Version differences retain the actual `.engine` tag, but are not recognizer n-best or calibrated confidence. Split/merged proposals `zusammenschreiben` and `notebook` would leave an extra neighbouring token under the fixture's single-word replacement policy; they are not credited as useful repairs. No UIKit tap/controller was exercised. Ambiguous cases produced zero lexical offers versus nine macOS offers requiring choice. Another 41 macOS candidates were semantic misses or unassessed, not assertion failures; the bounded acceptable wording set can omit defensible alternatives such as hyphenated “Pull-request”. No lexical-similarity perfection threshold is used.

DE/EN dictionaries were available. Per-arm harness rank median/p95: lexical 0.106/0.670 ms (n=144), macOS 12.681/30.210 ms (n=144). First per-opportunity invocation: 0.115/0.821 and 20.898/36.323 ms (n=24 each); later invocations: 0.085/0.591 and 11.854/22.904 ms (n=120 each). These are sequential Mac calls, not service cold starts, phone latency or end-to-end acceptance timings. SuggestionState produced 48 unique active/stopped observations per arm: active runs suppressed alternatives as expected. Own-edit suppression and request-ID behavior were asserted through the actual state.

## Checks, failures and provenance

Targeted existing tests passed: 215 patch, 75 alternative (including fake-backend reranker tests, no LLM calls), 13 supplemental sent-boundary tests. Scratch boundary checks passed: 3 tests, including 9 parameterized cases. Final runners exit 0 and have zero failed safety/state assertions; that does not mean all scenarios are supported or corrections useful.

Two initial compile failures (missing argument labels, operator whitespace) and the first patch run's two failed P05 caret assertions are retained. The old harness caret oracle assumed precomposed UTF-16 length despite accepting canonical equality. Production correctly retained decomposed bytes and caret. The corrected harness labels canonical no-ops separately and asserts exact retained bytes/caret. This was a harness correction, not a product fix. Subsequent reporting refinements and original outputs are retained in `provenance/harness-failures.md` and `reports/attempt*-*`.

Source inventory: 828 original files; 827 remain unchanged, with only expected stub SwiftPM deletion of Package.resolved. Its original SHA is `2ced537b47986c89db9adf5d5289eac731b7a51c1abc82b8c8f7a76fafca489c`, preserved in provenance. `provenance/artifact-sha256.json` covers harness code, actual runner binaries, frozen fixtures, per-case outputs, summaries, process receipts and logs. `reports/validation.json` and its log are excluded to avoid a self-hash cycle. The compact export excludes source archives, binaries, caches and large logs; original evidence remains in this scratch root.

The preserved SDK probe exit 0 confirms SDK 27.1 can typecheck the retained progressive preset plus alternativeTranscriptions/transcriptionConfidence options and Result.alternatives for arm64e iOS 26.0. Runtime candidate/confidence population and usefulness remain unmeasured. No recognition, phone, experimental UI, model download or LLM execution occurred here.

## Next bounded experiment and open native gaps

For #70, a separately approved native adapter should verify cursor units/restoration, raw suffix preservation, delayed/truncated context, partial writes and readback before attempting a phone comparison. For #71, first verify span/generation guards and manual-choice preservation, then measure actual candidate sources and listening-time row behavior with explicit UI scope. Neither local ranking coverage nor the SDK compile proves actual recognizer candidates/confidence, native tap acceptance, manual-choice precedence, continuous audio or physical-phone behavior. No issue-completion or production-delivery claim follows.

Reproduction commands are in README.md and export/reproduce.sh. Exact executed commands/environments/exits are retained in reports/*-process.json. No full baseline reruns are needed for review.
