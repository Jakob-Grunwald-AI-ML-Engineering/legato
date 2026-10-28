import AnemllCore
import CoreML
import CryptoKit
import Foundation
import LegatoCore
import Synchronization

/// Serial ownership extends through actual worker settlement, including cancellation and cold loading.
public actor ANEMLLBackend: ParityRuntime {
    public nonisolated let id = "anemll-coreml"
    public nonisolated let maxPromptCharacters: Int? = nil
    public nonisolated let folder: URL
    public nonisolated let family: PromptFamily
    public nonisolated let lease = RunLease()
    private var runtime: Runtime?
    private let requiresPreparation: Bool
    private var prepared: (config: YAMLConfig, tokenizer: AnemllCore.Tokenizer)?
    private let event: @Sendable (String, [String: String]) -> Void
    private var metadataDigest: String?
    private var inputCount: Int?
    private var candidate: String?
    private var metrics: InferenceMetrics?
    public var outputCap = 1024
    public var exactBucket: Int?

    private struct Runtime {
        let config: YAMLConfig
        let tokenizer: AnemllCore.Tokenizer
        let manager: InferenceManager
    }
    public struct InferenceMetrics: Sendable {
        public let renderedPromptSHA256: String
        public let inputTokens: Int
        public let outputTokens: Int
        public let modelWasLoaded: Bool
        public let modelLoadMs: Double
        public let tokenizerLoadMs: Double
        public let tokenizationMs: Double
        /// Upstream boundary includes KV reset/setup and prefill, before the decode loop.
        public let prefillMs: Double
        public let firstTokenMs: Double?
        public let decodeMs: Double?
        public let totalMs: Double
        public let contextLength: Int
        public let stopReason: String
        public let sampledPeakBytes: UInt64
    }
    public init(folder: URL, family: PromptFamily, requiresPreparation: Bool = false, event: @escaping @Sendable (String, [String: String]) -> Void = { _, _ in }) {
        self.folder = folder; self.family = family; self.requiresPreparation = requiresPreparation; self.event = event
    }
    public var availability: LLMAvailability {
        FileManager.default.fileExists(atPath: folder.appending(path: "meta.yaml").path)
            ? .available : .unavailable(reason: "Copy the pinned compiled checkpoint and tokenizer into \(folder.path)")
    }
    public func waitUntilSettled() async {
        let lease = lease
        // An unstructured waiter does not inherit caller cancellation and avoids a cancelled-sleep spin.
        await Task.detached {
            while lease.isRunning { try? await Task.sleep(for: .milliseconds(20)) }
        }.value
    }
    public func lastInputTokens() -> Int? { inputCount }
    public func lastCandidate() -> String? { candidate }
    public func isLoaded() -> Bool { runtime != nil }
    public func lastMetrics() -> InferenceMetrics? { metrics }
    public func configure(outputCap: Int, exactBucket: Int?) { self.outputCap = outputCap; self.exactBucket = exactBucket }
    public func cancel() { lease.cancel(); event("cancel.request", [:]) }
    public func unload() throws {
        // Taking ownership fails while a prediction/load is active, even if cancellation was requested.
        try lease.begin(); defer { lease.settle() }
        runtime = nil; prepared = nil; metadataDigest = nil
        event("model.unloaded", [:])
    }
    public func respond(instructions: String, prompt: String) async throws -> String {
        try await respond(instructions: instructions, examples: [], prompt: prompt)
    }
    public func respond(instructions: String, examples: [LLMExample], prompt: String) async throws -> String {
        try await run(instructions: instructions, examples: examples, prompt: prompt, syntheticTotal: nil)
    }
    public func respondSynthetic(totalInputTokens: Int) async throws -> String {
        try await run(instructions: "Continue writing a long numbered list until stopped.", examples: [], prompt: "", syntheticTotal: totalInputTokens)
    }
    private func run(instructions: String, examples: [LLMExample], prompt: String, syntheticTotal: Int?) async throws -> String {
        if requiresPreparation, runtime == nil {
            throw LLMError.unavailable(reason: "Foreground model preparation is required")
        }
        try lease.begin()
        metrics = nil; inputCount = nil; candidate = nil
        defer { lease.settle(); event("worker.settled", [:]) }
        let lease = lease
        return try await withTaskCancellationHandler {
            try lease.check(); try Task.checkCancellation()
            return try await perform(instructions: instructions, examples: examples, prompt: prompt, syntheticTotal: syntheticTotal)
        } onCancel: { lease.cancel() }
    }
    private func perform(instructions: String, examples: [LLMExample], prompt: String, syntheticTotal: Int?) async throws -> String {
        let start = ContinuousClock.now
        let sampler = MemorySampler()
        sampler.sample()
        let sampling = Task.detached {
            while !Task.isCancelled {
                sampler.sample()
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
        defer { sampling.cancel() }
        let tokenizerLoadStart = ContinuousClock.now
        try await prepareTokenizer()
        let tokenizerLoadMs = ms(tokenizerLoadStart)
        guard let prepared else { throw LLMError.failed("Tokenizer unavailable") }
        try lease.check()
        let tokenStart = ContinuousClock.now
        func makeTurns(_ userText: String) -> [ChatTurn] {
            var turns = [ChatTurn("system", instructions)]
            for example in examples { turns += [ChatTurn("user", example.user), ChatTurn("assistant", example.assistant)] }
            turns.append(ChatTurn("user", userText))
            return turns
        }
        let userText: String
        if let syntheticTotal {
            userText = try SyntheticInput.userText(totalTokens: syntheticTotal) { text in
                prepared.tokenizer.rawTokens(PromptRenderer.render(makeTurns(text), family: family)).count
            }
        } else { userText = prompt }
        let turns = makeTurns(userText)
        let rendered = PromptRenderer.render(turns, family: family)
        let tokens = prepared.tokenizer.rawTokens(rendered)
        // The pinned Gemma template accepts a leading system turn and folds it before trimming user text.
        let canonical = try prepared.tokenizer.canonicalChatTokens(
            messages: turns.map { ["role": $0.role, "content": $0.content] }, thinking: false)
        guard tokens == canonical else { throw LLMError.failed("Checkpoint chat template differs from validated renderer; inference refused") }
        inputCount = tokens.count
        try ContextBudget.validate(input: tokens.count, outputCap: outputCap, context: prepared.config.contextLength,
                                   exactBucket: syntheticTotal ?? exactBucket)
        let tokenMs = ms(tokenStart)
        try lease.check(); try Task.checkCancellation()
        // Invalid/infeasible prompts exit before any large MLModel weights or KV state are loaded.
        let modelWasLoaded = runtime != nil
        let loadStart = ContinuousClock.now
        if requiresPreparation, runtime == nil {
            throw LLMError.unavailable(reason: "Foreground model preparation is required")
        }
        try await loadRuntime()
        let loadMs = ms(loadStart)
        guard let runtime else { throw LLMError.failed("No loaded runtime") }
        try lease.check()
        event("prefill.begin", ["inputTokens": String(tokens.count), "outputCap": String(outputCap)])
        let generationStart = ContinuousClock.now
        let times = Mutex((first: Optional<Double>.none, last: Optional<Double>.none))
        let event = event
        let shifted = Mutex(false)
        let lease = lease
        let result = try await runtime.manager.generateResponse(
            initialTokens: tokens, temperature: 0, maxTokens: outputCap,
            eosTokens: runtime.tokenizer.eosTokenIds, tokenizer: runtime.tokenizer,
            onToken: { @Sendable _ in
                let elapsed = Double(generationStart.duration(to: .now) / .milliseconds(1))
                let first = times.withLock { value in
                    let first = value.first == nil
                    if first { value.first = elapsed }
                    value.last = elapsed
                    return first
                }
                if first { event("decode.firstToken", [:]) }
            }, onWindowShift: { @Sendable in shifted.withLock { $0 = true }; lease.cancel() })
        guard !shifted.withLock({ $0 }) else { throw LLMError.contextTooLong }
        try lease.check()
        let observed = times.withLock { $0 }
        let reply = runtime.tokenizer.decode(tokens: result.0, skipSpecialTokens: true)
        guard !reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw LLMError.emptyResponse }
        guard result.2 == "eos_token" || result.2 == "max_tokens" else {
            throw LLMError.failed("Incomplete generation: \(result.2)")
        }
        sampler.sample()
        metrics = InferenceMetrics(renderedPromptSHA256: SHA256.hash(data: Data(rendered.utf8)).map { String(format: "%02x", $0) }.joined(), inputTokens: tokens.count, outputTokens: result.0.count, modelWasLoaded: modelWasLoaded, modelLoadMs: loadMs,
            tokenizerLoadMs: tokenizerLoadMs, tokenizationMs: tokenMs, prefillMs: result.1 * 1000, firstTokenMs: observed.first,
            decodeMs: observed.first.flatMap { first in observed.last.map { $0 - first } }, totalMs: ms(start),
            contextLength: runtime.config.contextLength, stopReason: result.2, sampledPeakBytes: sampler.sampledPeakBytes)
        event("decode.end", ["tokens": String(result.0.count), "stopReason": result.2])
        candidate = reply
        guard result.2 == "eos_token" else { throw LLMError.failed("Output capped; cleanup is incomplete") }
        return reply
    }
    /// Loads weights/tokenizer only: no dummy turn, prefill, or response is generated.
    public func prepare() async throws {
        try lease.begin()
        defer { lease.settle(); event("prepare.settled", [:]) }
        let lease = lease
        try await withTaskCancellationHandler {
            try lease.check(); try Task.checkCancellation()
            try await prepareTokenizer()
            try lease.check(); try Task.checkCancellation()
            try await loadRuntime()
            try lease.check(); try Task.checkCancellation()
        } onCancel: { lease.cancel() }
    }
    private func prepareTokenizer() async throws {
        let metadata = try Data(contentsOf: folder.appending(path: "meta.yaml"))
        let currentDigest = SHA256.hash(data: metadata).map { String(format: "%02x", $0) }.joined()
        if let metadataDigest, metadataDigest != currentDigest {
            throw LLMError.failed("Checkpoint metadata changed while weights/tokenizer are cached; unload before changing artifacts")
        }
        metadataDigest = currentDigest
        if prepared == nil {
            let config = try YAMLConfig.load(from: folder.appending(path: "meta.yaml").path)
            for name in ["config.json", "tokenizer.json", "tokenizer_config.json"] {
                guard FileManager.default.fileExists(atPath: folder.appending(path: name).path) else {
                    throw LLMError.unavailable(reason: "Missing \(name)")
                }
            }
            let tokenizer = try await AnemllCore.Tokenizer(modelPath: folder.path, template: family.rawValue, debugLevel: 0)
            prepared = (config, tokenizer)
        }
    }
    private func loadRuntime() async throws {
        try lease.check(); try Task.checkCancellation()
        if runtime == nil {
            event("model.load.begin", [:])
            guard let prepared else { throw LLMError.failed("Tokenizer unavailable") }
            let config = prepared.config
            let progress = ModelLoadTrace(event: event)
            defer { withExtendedLifetime(progress) {} }
            let loader = ModelLoader(progressDelegate: progress)
            let models = try await withTaskCancellationHandler {
                try await loader.loadModel(from: config, configuration: .init(computeUnits: .cpuAndNeuralEngine))
            } onCancel: { Task { await loader.cancelLoading() } }
            try lease.check()
            let manager = try InferenceManager(
                models: models, contextLength: config.contextLength, batchSize: config.batchSize,
                splitLMHead: config.splitLMHead, debugLevel: 0, v110: config.configVersion == "0.1.1",
                argmaxInModel: config.argmaxInModel, slidingWindow: config.slidingWindow,
                updateMaskPrefill: config.updateMaskPrefill, prefillDynamicSlice: config.prefillDynamicSlice,
                modelPrefix: config.modelPrefix, vocabSize: config.vocabSize, lmHeadChunkSizes: config.lmHeadChunkSizes)
            manager.setSamplingConfig(.greedy)
            let lease = lease
            manager.cancellationCheck = { try lease.check() }
            runtime = Runtime(config: config, tokenizer: prepared.tokenizer, manager: manager)
            event("model.load.end", [:])
        }
    }
    private func ms(_ start: ContinuousClock.Instant) -> Double { Double(start.duration(to: .now) / .milliseconds(1)) }
}


private final class ModelLoadTrace: ModelLoadingProgressDelegate {
    private let event: @Sendable (String, [String: String]) -> Void
    init(event: @escaping @Sendable (String, [String: String]) -> Void) { self.event = event }
    func loadingProgress(percentage: Double, stage: String, detail: String?) {
        event("model.load.progress", ["fraction": String(percentage), "stage": stage, "detail": detail ?? ""])
    }
    func loadingCancelled() { event("model.load.cancelled", [:]) }
    func loadingCompleted(models: LoadedModels) { event("model.load.completed", [:]) }
    func loadingFailed(error: any Error) {
        let info = error as NSError
        event("model.load.failed", ["type": String(describing: type(of: error)), "domain": info.domain, "code": String(info.code)])
    }
}
