# Background cleanup prototype (#39)

A separate iPhone host, keyboard and recording AppIntent compose the production `MicSource → AppleSpeechEngine → DictationSession → LLMCleanupStage → keyboard insertion` components; device proof so far is fixture-only, with the microphone/ASR/insertion flow still unverified in this spike. Nothing changes the shipping app or its dependencies. The App Group, URL scheme, Darwin notification and data containers are independent. This is a measurement harness, not production backend integration proof.

## Prepare and build

Run from this directory:

```bash
bash scripts/setup.sh --dry-run
bash scripts/setup.sh --prepare
bash scripts/test-bootstrap.sh
bash scripts/test-contracts.sh
bash scripts/build.sh Debug
bash scripts/build.sh Release <physical-device-udid>
bash scripts/check-isolation.sh
```

Setup downloads only pinned ANEMLL source, verifies the archive, applies three versioned patches and records tool/patch hashes in `.cache/build-provenance.txt`. It refuses unexpected source state and reserves 3 GiB. The real combined dependency compatibility build succeeded using ANEMLL `f4ad26d…`, its `anemll-swift-cli` package and Legato's exact swift-transformers 1.3.5. The patches pin that requirement, provide a synchronized cancellation hook at every direct prediction site, and expose raw/canonical tokenization without extra BOS. An iOS build checks real APIs; stubs and simulator runs prove no ANE behavior.

Repository pin: Xcode 26.6; this machine currently has Xcode 27.1 (27A9275) only. Actual build versions are recorded. Deployment remains iOS 26.0. No iOS 27 inference entitlement is requested. XcodeGen must be 2.46.0. All remote dependency revisions are locked in `Package.resolved`; builds reuse `~/Library/Caches/legato/SourcePackages`.

## Install and stage a model

The build command does not install. After the signed Release app is ready:

```bash
bash scripts/device-run.sh <udid> install
bash scripts/device-run.sh <udid> launch
```

Use this app's `Documents/Models/` only. Compiled ANEMLL directories, `meta.yaml`, `config.json`, `tokenizer.json` and `tokenizer_config.json` live together in `gemma3-1b/`, `qwen3-1.7b/` or the explicitly unvalidated experimental `qwen3-0.6b/` conversion folder. The FP16 and LUT6 conversions completed but failed their strict numeric gates; preserve their failed-validation labels and exact manifests when staging (see [research assessment](../../docs/research/ane-cleanup.md)). Preserve every compiled directory and YAML field. The app never downloads weights. `models.json` records exact checkpoints and licence evidence; metadata saying MIT does not replace original Gemma terms. Upstream has only a README MIT claim in the inspected archive; no upstream source or model weights are committed here.

MLX baselines use `Documents/Models/mlx/<spec.folderName>/`, matching the pinned shipping catalog. Qwen1.7B on iPhone is explicitly a spike experiment; it is macOS-only in the shipping catalog. Gemma's MLX QAT and ANEMLL weights differ, so their quality comparison is not numerical export parity.

## Guided physical runs

1. Open ANE Cleanup Spike and allow microphone/speech access once. The phone shows status/progress and Cancel; model choices and foreground runs are controlled from the computer. Keep the app open for foreground checks. Debug output is wiring evidence only; detached Release runs are timing candidates.
2. The controller supplies backend/model/fixture/cap/bucket arguments. Natural cleanup uses the default 1024 output cap; 128 is explicitly a different cell. Capped replies remain incomplete even when a guard would accept them.
3. Run once with cold weights and at least three warm repeats using `--spike-repeat 4` or the warm fixture URL. `anecleanup39://unload` releases the selected cached model without restarting the app. A fresh process is process cold; neither operation implies cold OS/compiler caches.
4. For the keyboard recording path, enable **ANE Spike Keyboard** and Full Access in iOS Settings. Arm for the finite 60-second window, return to a text field in another app, select this keyboard, and press Start/Stop. Speak, then stop. Final text is copied and published for the spike keyboard to insert and acknowledge. This is **foreground-armed background recording/inference**; no background cold start is claimed.
5. For genuine Action Button starts, select this app's **Toggle spike dictation** shortcut, leave the app in the background and press to start/stop. Refused starts are failures with no silent foreground retry. Setup-required foreground continuation is explicitly logged.
6. The separate **Run spike fixture** shortcut and keyboard fixture button run deterministic inference with the actual app state logged. These are fixture triggers, separate from the microphone-stop test. The completion assertion is bounded, and expiry/cancellation requests stop before the next prediction. An in-flight Core ML prediction may finish before settlement; no new run or unload can overlap it.
7. Collect a separate Instruments capture for placement, then rerun detached for timing. Record locked-screen, expiration and interruption failures as such; never replace them with a successful fallback row.

The full cleanup prompt retains its instructions, all eleven examples and vocabulary. Exact bucket selection refuses a mismatch in **total rendered tokenizer tokens**, without trimming examples. An unchanged prompt can make small buckets infeasible. `.cpuAndNeuralEngine` permits those devices; it does not establish actual ANE use. Every inference checks rendered token equality against the checkpoint's actual chat template; Qwen thinking off uses the checkpoint's empty `<think>` suffix, and Gemma maps assistant to model while folding system instructions into the first user turn. Extra BOS is disabled for already rendered strings.

## Evidence and limits

`Documents/Results/measurements.jsonl` holds durable started headers and final fixture rows. `events.jsonl` correlates lifecycle, trigger, load, prefill, tokens, cancellation and settlement by run ID. Operational events contain counts/state, not dictated text. The private app history contains real transcripts; pulled artifacts remain gitignored. Only synthetic/nonpersonal fixture evidence should be published.

```bash
bash scripts/pull-results.sh <udid>
bash scripts/device-run.sh <udid> profile
```

The profiling command requests the installed instruments named `Core ML`, `Neural Engine` and `Points of Interest`. Trace overhead is not detached timing evidence. Correlate termination/jetsam logs with pid, timestamp and run ID; missing completion is not proof of jetsam.

`prefillMs` is the upstream `generateResponse` boundary: KV reset/setup plus prefill until the decode loop, not kernel-only prefill. `firstTokenMs` starts at generation entry; model load and tokenization are separate fields. Decode callbacks are actual token IDs and exclude EOS; derive rate as `(outputTokens - 1) / (decodeMs / 1000)` only for more than one token. Sampled peak physical footprint uses 50 ms sampling and is not an external high-water/jetsam measurement. MLX's public backend and Foundation Models expose only full-string latency here; token/phase fields remain absent (N/A).

Contract checks compile the pure shared Swift source directly with `swiftc` to avoid a second heavy macOS dependency build. They demonstrated meaningful RED then GREEN for context overflow, the upstream two-token context margin, role/thinking formatting, classification and cancellation/settlement. The synchronized cancellation lifecycle is tested with simulated in-flight prediction boundaries; actual prefill/decode cancellation still needs device proof. The real-package signed app build validates integration separately.

Qwen3-0.6B FP16/LUT6 conversion execution is complete; strict numerical clearance remains unmet and both artifacts are experimental/unvalidated. Remaining work includes the ready-state device/quality matrix, observed ANE placement, shared microphone warmup integration and further cancellation/expiry/jetsam evidence. The [research assessment](../../docs/research/ane-cleanup.md) records the provisional baseline and exact gaps; #39 remains open.

## Observed fixture comparison

The [final research comparison](../../docs/research/ane-cleanup.md#final-short-fixture-comparison) and [public aggregate](conversion/results/phone-short-fixture-comparison.json) cover three short German/English/mixed fixtures: Foundation Models 3/3, Qwen3-1.7B 3/3, Gemma3-1B 1/3, experimental Qwen3-0.6B LUT6 0/3. German repeats and synthetic cells do not count in that denominator; it is a small non-statistical set. All four German Action Button runs completed fully background, but Gemma/experimental 0.6 failed cleanup quality. The 0.6 artifact retains its failed numeric gate, so device quality is conversion-confounded; it is not numerical clearance. Actual ANE placement remains unproved.

Warm German foreground/background end-to-end seconds were FM 0.889970/2.279675 (system-managed residency unknown), Qwen1.7 3.165297/3.551058, Gemma 12.977075/13.461008 and experimental 0.6 1.991020/2.370125. No cold load is included. Gemma tokenization includes two encodes/template parity; Apple service memory is not host-process memory. Remaining work includes Gemma 300/500/800 synthetic buckets, repeated background bucket cells, MLX CPU baseline, broader quality, actual ANE dispatch, conversion parity and shared microphone warmup/retention integration. There is no shipping backend change.

## Permission callback regression

The first installed snapshot crashed during the speech permission request. Device crash reports identify `_dispatch_assert_queue_fail → swift_task_checkIsolatedSwift → SpikeHost.setup` on a TCC background queue. This is a Swift actor-isolation failure before model inference. The fix uses a nonisolated permission bridge and explicitly `@Sendable` Objective-C callbacks; model-token callbacks also explicitly use `@Sendable`.

```bash
bash scripts/test-permission-callback.sh
```

The regression uses a tiny Objective-C completion dispatched on a global queue and a Swift 6 MainActor caller. The fixed bridge passes. `--reproduce-unsafe` preserves the old callback pattern and intentionally traps with exit 133; it is a local diagnostic reproduction, not a normal green check. Confirm the installed app's setup flow independently on the phone.

For detached, explicitly foreground fixture automation, pass app launch arguments `--spike-run-fixture --spike-backend anemll --spike-model gemma3-1b --spike-fixture de-short-01-time --spike-cap 1024`. Add `--spike-synthetic --spike-bucket 300` for a clearly labelled synthetic timing cell. The app waits for actual active state before running and records `cliForegroundFixture`; these commands provide no background-start evidence. Synthetic input uses exact token counts including its own template/instructions, has no cleanup examples and produces no cleanup quality score. Natural cleanup fixture runs keep the standard eleven-shot prompt intact.

Each final fixture row now includes the source build ID, model metadata SHA256, optional conversion manifest SHA256, actual YAML quantization fields, tokenizer/checkpoint revision, semantic/rendered-prompt fingerprints where available, device/OS/power/thermal state and explicit cache condition. Changing metadata while a model/tokenizer is cached is refused until unload. The source build ID and patch hashes are recorded in `.cache/build-Release-provenance.txt`; preserve that alongside device results.


## Controller commands and cold preparation

There are no device pickers or manual foreground test controls. The computer owns the configuration and sequence; the user is needed for initial permissions and the requested real keyboard/Action Button background interactions.

CLI controls: `--spike-backend`, `--spike-model`, `--spike-fixture`, `--spike-locale`, `--spike-cap`, `--spike-bucket`, `--spike-synthetic`, and `--spike-repeat` (1–10). The fixture URL accepts the corresponding query keys `backend`, `model`, `fixture`, `locale`, `cap`, `bucket`, `synthetic` and `repeat`. A single controller lease serializes configuration changes, cache release and the complete run batch. `anecleanup39://cancel` requests cancellation and still waits for worker settlement. URL control brings the app forward and is never background-start evidence.

Only a model-cold fixture that is actually active in the foreground receives a 300-second whole-fixture deadline, allowing tokenizer/model preparation and first Core ML hardware compilation to settle. Warm foreground fixtures and all inactive/background starts retain 60 seconds. UIKit background expiration remains independent and cancels either operation when its execution allowance ends. Each row records `fixtureDeadlineSeconds`; the extended preparation allowance is not a performance result. Progress events identify upstream loading stages and the last completed embeddings/head/FFN boundary.

The observed 60-second foreground cancellation remains retained as failed preparation evidence. Source audit found synchronous `MLModel(contentsOf:)` calls followed by cancellation checks at progress boundaries, rather than a cyclic actor wait. Cancellation can therefore settle after the current model construction returns; increasing the foreground budget does not promise interruptible loading or unlimited background runtime.

The spike CPU baseline explicitly calls public `MLX.compile(enable: false)` before model construction. This process-global policy is confined to the isolated host, which has no MLX GPU mode; shipping code and shared checkouts are untouched. Rows record `cpuCompilation = "disabled; interpreted MLX ops"`. A detached iPhone run with CPU streams alone failed with `[Compiled::eval_cpu] CPU compilation not supported on the platform`; a passing build does not prove the workaround on-device. After the same phone fixture rerun, verify its exact run ID using `scripts/check-cpu-baseline.sh measurements.jsonl <run-id>`; this checks execution completion independently of cleanup quality.

ANEMLL `tokenizationMs` includes manual prompt rendering, a full raw encode, native chat-template rendering plus a second full encode, token-array equality and context validation. Metadata hashing and cached-tokenizer loading are outside this interval. Warm repeated input still performs both encodes; do not call that interval pure tokenizer kernel time or subtract it from end-to-end latency. No validated-input cache is enabled.

A deadline or runtime expiry stops the whole repeat batch. Backend ownership spans every public `respond` invocation, including cleanup work that outlives the production pipeline's latency deadline. The spike waits for owned invocations before releasing the run. MLX's String/stream API exposes no native evaluation-task join to this host: after cancellation, the process is quarantined even if that public API returns, and a row explicitly records the unresolved native-worker boundary. Further runs, model unloads and switches are refused until the controller restarts only the isolated spike process; a public API return is never labelled native settlement proof. The same conservative policy applies to cancelled Foundation Models calls.

Voice phase/token metrics require an actual backend invocation owned by that run; empty ASR cannot inherit a previous call's metrics. Background fixture eligibility covers lifecycle through final settlement, with the final state and any foreground-interruption timestamp recorded. Returning to the background after a foreground interruption does not restore eligibility; such fixture completions are labelled `foregroundInterrupted`.

## Instruments capture limitation observed on the phone

The [capture-gap record](results/instruments-actual-capture-gap.json) separates completed transport controls from real-inference capture attempts. With a bounded public read-only `devicectl device info displays --stream` subscription held open, all-process five-second Time Profiler and Neural Engine controls finalized successfully. A completed Neural Engine control declared `ane-hw-intervals`; no fixture ran during that control, so it establishes no model placement.

Both actual warm Qwen fixture calls completed successfully, but the combined Core ML/Neural Engine/Points of Interest capture and the Neural Engine-only fallback failed to finalize after reaching their recording limits. Host logs repeatedly reported missing compatible device support symbols, and host samples showed symbolication waits. The unfinalized traces and logs remain private. Neither attempt supplies exported process/model-attributed ANE dispatch evidence; their fixture latencies are instrumented observations, not detached benchmarks. Recorder cleanup required separately authorized signals; no phone install or restart occurred during these attempts.

`device-run.sh profile` remains the earlier attempted attach command, not a proven end-to-end profiling workflow. A future controlled retry can hold `xcrun devicectl device info displays --device <udid> --stream --timeout 90` in one terminal, then run `xcrun xctrace record --device <udid> --instrument 'Neural Engine' --all-processes --time-limit 20s --output <unique-private-path>.trace` in another. Trigger one explicitly instrumented fixture only after recording starts. The display hold improved short transport controls but did not solve finalization during actual inference. Require successful recorder exit, a finalized TOC, and process/model/time-correlated event rows before claiming placement. A recording time limit does not bound host postprocessing; preserve and report an unfinished capture rather than counting it as proof.

Converted artifact rows additionally read `modelValidation` from the actual model folder's `artifact-manifest.json` and record that file's exact `artifactManifestSHA256`. The experimental LUT6 0.6B manifest reports `failedStrictNumericGate;prefixTop1Mismatch`; FP16 has a different label and hash. These fields carry existing artifact evidence, not a new acceptance decision or production-readiness claim. Missing manifests leave both fields absent; readable malformed manifests retain their byte hash without a validation label. Verify with `bash scripts/test-artifact-provenance.sh`.
