# Local cleanup while Legato is in the iOS background

Research date: 2026-10-26. Follow-up to [local fine-tuning research](local-fine-tuning.md). Scope: implementation research only; no model execution, device test, conversion, entitlement change or spike.

## Conclusion

**Local cleanup in the background is a credible implementation goal. GPU execution is one conditional path, not a requirement for every local LLM.** The earlier blanket wording that MLX needs the GPU was too broad. Legato currently chooses to skip its MLX backend in the background; this does not prove local cleanup impossible.

For a custom, potentially fine-tuned Qwen3 model, first investigate a CPU execution path in the existing MLX stack. GPU acceleration can be an optional capability for eligible user-started jobs. Core ML/Neural Engine is a separate conversion path. Keep Apple Foundation Models as a system-managed comparison where available. None of these has been benchmarked here.

## What Superwhisper establishes

Superwhisper publishes local cleanup weights, but its public platform statements do not establish the iOS compute backend. The [S1 launch](https://superwhisper.com/blog/s1) describes local processing on a laptop or phone; its [detailed language-model documentation](https://superwhisper.com/docs/models/language) lists S1-mini on macOS and Windows. Record that discrepancy rather than conclude either iOS availability or impossibility.

Its [voice-model documentation](https://superwhisper.com/docs/models/voice) names GPU runtimes for particular desktop transcription models. That does not identify the cleanup LLM's execution device on iPhone. The [iOS setup](https://superwhisper.com/docs/get-started/ios) and [iOS 26.4 keyboard-flow explanation](https://superwhisper.com/docs/common-issues/ios-26-keyboard-changes) establish a keyboard/main-app workflow, including manual return after opening the app; they do not disclose CPU/GPU/Neural Engine dispatch.

No public first-party iOS application source or technical description confirming background GPU cleanup was found. These implementation options are proposals for Legato, not claims about Superwhisper's private architecture.

## Execution paths

| Path | How it could work | Main limitation | Position |
|---|---|---|---|
| Custom LLM on CPU | Host app finishes dictation, obtains permitted completion time and generates with an explicitly CPU-only runtime | Complete operator coverage, memory, latency and expiration need verification | First custom-model path to investigate |
| Custom LLM on GPU | Start an eligible continued-processing job in the foreground; request GPU resources with the capability, then continue when backgrounded | Device support is runtime-dependent; background-only starts are not equivalent | Optional acceleration, not the baseline for every trigger |
| Core ML on CPU/Neural Engine | Convert/export a suitable cleanup model and choose compute units excluding GPU | Conversion/KV-cache/quantization/adapter parity and OS-specific ANE permissions | Separate optimization project |
| Apple system model | Use the existing Foundation Models backend with proper background runtime and availability handling | Eligibility, quality and system rate limits; not the custom Qwen adapter | Comparison/fallback |
| Foreground cleanup | Bring the app forward and execute normally | Visible app hop, then manual return on current keyboard flow | Explicit fallback where needed |

### CPU: supported building blocks in the exact dependency

[Package.resolved](../../Package.resolved) pins mlx-swift 0.32.3 at `19601207e9a0de51e03ee6ec0c3c5f3784275075`. Its [Device.swift](https://github.com/ml-explore/mlx-swift/blob/19601207e9a0de51e03ee6ec0c3c5f3784275075/Source/MLX/Device.swift) exposes CPU devices and synchronous/asynchronous `Device.withDefaultDevice(.cpu)`. Device choice is scoped through streams/task-local state.

The bundled MLX core contains [CPU quantized matrix multiplication](https://github.com/ml-explore/mlx/blob/1f8e74e3f12f31365464a6867c6579f0e9b29d85/mlx/backend/cpu/quantized.cpp), including 4-bit/group-64 dispatch. This is stronger evidence than merely knowing MLX has a CPU enum, but it is still not a completed Qwen3 inference test.

The pinned [ChatSession](https://github.com/ml-explore/mlx-swift-lm/blob/3b339ad6e3b3f44c8121ecff5131c7fd55e075e6/Libraries/MLXLMCommon/ChatSession.swift) uses ordinary tasks, and [Evaluate.swift](https://github.com/ml-explore/mlx-swift-lm/blob/3b339ad6e3b3f44c8121ecff5131c7fd55e075e6/Libraries/MLXLMCommon/Evaluate.swift) explicitly preserves task-local values for its generation worker; neither inspected file forces a GPU device. That strengthens the CPU-scoped approach. A candidate implementation must still cover model initialization, adapter loading, KV-cache allocation and every generation worker/stream, not just wrap the outer Swift call in a CPU scope. Audit explicit GPU streams and task-local propagation. Serialize changes of execution path and handle existing resident caches deliberately. Switching a configuration flag after GPU work was submitted is not a safe recovery strategy.

If the existing MLX generation layer cannot cleanly support this, [llama.cpp](https://github.com/ggml-org/llama.cpp/blob/master/docs/build.md) documents CPU execution and disabling Metal. That would add a runtime and an artifact/adapter compatibility burden. It is a fallback research option, not a reason to replace MLX before checking its actual limitations.

### GPU: permission and runtime are separate

Apple's [Metal background guide](https://developer.apple.com/documentation/metal/preparing-your-metal-app-to-run-in-the-background) says ordinary background command submission is restricted. A microphone session or extra CPU runtime does not itself grant GPU permission.

Apple's [continued-processing guide](https://developer.apple.com/documentation/backgroundtasks/performing-long-running-tasks-on-ios-and-ipados) provides an iOS 26 path for GPU work: a foreground, user-initiated job, the Background GPU Access capability, and runtime GPU support. The app must report progress and handle expiration/cancellation. Apple's [DTS clarification](https://developer.apple.com/forums/thread/794072) says there is no published supported-device list; use `BGTaskScheduler.supportedResources.contains(.gpu)`.

Do not equate an Action Button or Live Activity interaction handled entirely in the background with the documented foreground start. A foreground-started dictation/processing flow may qualify; the exact scope and lifetime of the grant remain a device-check question. A grant for one job is not persistent GPU access for later recordings.

### Core ML and system-model alternatives

[MLComputeUnits](https://developer.apple.com/documentation/coreml/mlcomputeunits) distinguishes CPU-only, CPU/GPU and CPU/Neural Engine configurations. Choosing `.cpuAndNeuralEngine` excludes GPU, but converting the existing MLX weights into a performant stateful Core ML language model is additional work. It does not automatically preserve an MLX adapter's deployment format.

Current [Background Inference documentation](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.background-tasks.continued-processing.inference) says Neural Engine background use requires an entitlement. Its [DocC availability metadata](https://developer.apple.com/tutorials/data/documentation/bundleresources/entitlements/com.apple.developer.background-tasks.continued-processing.inference.json) introduces that key at **iOS 27.0**. Do not retroactively use that restriction to describe iOS 26, or promise unrestricted ANE execution across future OS versions.

Apple explicitly discusses background system-model calls and possible rate limiting in its [WWDC26 lab](https://developer.apple.com/videos/play/wwdc2026/8016/) around 19:04. This supports investigating the Foundation Models fallback; it is not proof of Legato behavior on its particular iOS 26.6 deployment. System-managed inference and custom MLX dispatch are different execution paths.

## How this fits Legato

At the inspected checkout, [CleanupRegistry](../../Sources/LegatoMLX/CleanupRegistry.swift) uses a background-state predicate to skip MLX and falls through to Foundation Models or deterministic processing. [MLXBackend](../../Sources/LegatoMLX/MLXBackend.swift) does not select a CPU execution path. Moreover, the app targets currently have no call sites for `CleanupRegistry` or `PostProcessingPipeline`: package support exists, but end-to-end cleanup wiring is still work.

A concrete implementation would:

1. Finish ASR in the main app process and retain the raw result before attempting cleanup. The keyboard remains an input/display client.
2. Acquire/check permitted completion time before starting potentially long work. Apple's [background-time guide](https://developer.apple.com/documentation/uikit/extending-your-app-s-background-execution-time) requires an expiration handler and prompt release. A task assertion prevents suspension for a bounded period; it grants neither GPU permission nor unlimited time.
3. Select an execution path based on actual device/job capability and model support. Preserve a CPU-only route for background-only starts; use GPU only while a valid execution grant or foreground access exists.
4. Run bounded cleanup, then publish one accepted final result consistently to history, Live Activity and insertion/copy delivery. Preserve original text on timeout, failure or guard rejection. Cancellation must stop generation rather than leave expensive work consuming the expired budget.
5. Avoid keeping fictitious audio playing/recording merely to claim indefinite runtime. Verify the legitimate recording-to-cleanup handoff for each trigger instead.

For a later decisive check, use an actual app host, without a debugger keeping it alive: foreground-to-host-app transition, Action Button background start/stop, keyboard return, locked screen, and expiration. Record chosen backend/device, actual GPU permission, completion time, peak memory and fallback output. Compare full end-to-end text, including host insertion, not just a successful model API call.

## Overnight training remains a separate question

Short cleanup inference has a different budget and execution context from unattended adapter training. CPU kernel availability makes phone-local work worth investigating, but says nothing yet about backpropagation memory, optimizer state, total energy or checkpoint/resume behavior. Scheduled overnight processing remains system-controlled and interruptible. The user-started GPU continuation API does not establish an automatic nightly GPU training mechanism.

The useful change in recommendation is to keep **CPU-based on-phone personalization and background custom cleanup open**, rather than rule them out because the current backend uses GPU defaults. Their resource use and product quality remain unmeasured.
