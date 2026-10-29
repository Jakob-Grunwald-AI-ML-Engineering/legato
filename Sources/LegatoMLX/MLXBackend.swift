import Foundation
import HuggingFace
import LegatoCore
import MLX
import LegatoModels
import MLXLLM
import MLXLMCommon
import Synchronization
import Tokenizers

/// Keeps the loaded model, so warming at install time and the first cleanup call share one load. Holds
/// one model at a time (about 1 GB resident): picking another one releases the previous.
actor MLXModelCache {
    static let shared = MLXModelCache()

    private let cache = RecentModelCache<ModelContainer>(capacity: 1)

    /// Loads the model from `folder` (once). Never downloads: the downloader below refuses.
    func container(for spec: MLXModelSpec, folder: URL) async throws -> ModelContainer {
        try await cache.model(at: folder) {
            try await LLMModelFactory.shared.loadContainer(
                from: NoDownloads(), using: TransformersTokenizerLoader(),
                configuration: ModelConfiguration(directory: folder, extraEOSTokens: spec.extraEOSTokens))
        }
    }

    func evict(folder: URL) async {
        await cache.evict(folder: folder)
        halfPrecision.removeAll()
    }

    /// Containers whose bfloat16 parameters were already cast to float32 (see ``containerForCPU(spec:folder:)``).
    private var halfPrecision: Set<ObjectIdentifier> = []

    /// The model of `folder` for CPU work: its bfloat16 parameters (quantization scales and biases, norms) cast
    /// once to float32. MLX's CPU kernels have no SIMD path for bfloat16, so a bfloat16 quantized matmul runs
    /// one scalar multiply-add at a time (Qwen3 1.7B 4-bit never finished its first prefill in 11 minutes on a
    /// Mac); float32 takes the vectorised path (about 4 tokens a second, prefill and decode alike, one core).
    /// Not float16: Qwen3's activations overflow it and the reply is noise. The packed 4-bit weights stay as
    /// they are; scales and biases double (about +110 MB for the 1.7B) and so does the KV cache. Call it with
    /// the CPU as the task's default device. The cast copy is the one resident copy, so GPU work on it runs in
    /// float32 too.
    func containerForCPU(spec: MLXModelSpec, folder: URL) async throws -> ModelContainer {
        let container = try await container(for: spec, folder: folder)
        let id = ObjectIdentifier(container)
        guard !halfPrecision.contains(id) else { return container }
        #if canImport(Cmlx)  // the real MLX; the CI stub has no arrays
            await container.perform { (context: ModelContext) in
                let model = context.model
                let cast = model.parameters().mapValues { $0.dtype == .bfloat16 ? $0.asType(.float32) : $0 }
                model.update(parameters: cast)
                eval(model)
            }
        #endif
        halfPrecision.insert(id)
        return container
    }

    var residentFolders: [String] { get async { await cache.residentFolders } }
}

/// A downloader that always refuses: models load from disk only.
private struct NoDownloads: MLXLMCommon.Downloader {
    func download(
        id: String, revision: String?, matching patterns: [String], useLatest: Bool,
        progressHandler: @Sendable @escaping (Progress) -> Void
    ) async throws -> URL {
        throw LLMError.unavailable(reason: "\(id) is not downloaded")
    }
}

/// swift-transformers tokenizers behind mlx-swift-lm's `TokenizerLoader` (what the `MLXHuggingFace` macros
/// would expand to, written out so the build needs no macro plugin).
struct TransformersTokenizerLoader: MLXLMCommon.TokenizerLoader {
    func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer {
        TokenizerBridge(try await AutoTokenizer.from(modelFolder: directory))
    }
}

private struct TokenizerBridge: MLXLMCommon.Tokenizer {
    private let upstream: any Tokenizers.Tokenizer

    init(_ upstream: any Tokenizers.Tokenizer) { self.upstream = upstream }

    func encode(text: String, addSpecialTokens: Bool) -> [Int] {
        upstream.encode(text: text, addSpecialTokens: addSpecialTokens)
    }

    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
        upstream.decode(tokens: tokenIds, skipSpecialTokens: skipSpecialTokens)
    }

    func convertTokenToId(_ token: String) -> Int? { upstream.convertTokenToId(token) }
    func convertIdToToken(_ id: Int) -> String? { upstream.convertIdToToken(id) }

    var bosToken: String? { upstream.bosToken }
    var eosToken: String? { upstream.eosToken }
    var unknownToken: String? { upstream.unknownToken }

    func applyChatTemplate(
        messages: [[String: any Sendable]], tools: [[String: any Sendable]]?,
        additionalContext: [String: any Sendable]?
    ) throws -> [Int] {
        do {
            return try upstream.applyChatTemplate(messages: messages, tools: tools, additionalContext: additionalContext)
        } catch Tokenizers.TokenizerError.missingChatTemplate {
            throw MLXLMCommon.TokenizerError.missingChatTemplate
        }
    }
}

/// Where an MLX model computes.
public enum ComputeDevice: String, Sendable, Equatable, CaseIterable {
    /// Metal: fast, foreground only on the phone (iOS refuses GPU work from a background app).
    case gpu
    /// The CPU: slower, allowed in the background.
    case cpu

    /// "GPU" / "CPU", for Settings.
    public var label: String { rawValue.uppercased() }
}

/// Runs the loaded model: the seam the tests replace. `device` is where the work runs.
protocol MLXGenerating: Sendable {
    /// Loads the model from `folder` (once) with `device` as the default device.
    func load(spec: MLXModelSpec, folder: URL, device: ComputeDevice) async throws
    /// The reply to `prompt`, chunk by chunk, generated on `device`. Ending the iteration early stops the
    /// generation.
    func stream(
        spec: MLXModelSpec, folder: URL, instructions: String, examples: [LLMExample], prompt: String,
        device: ComputeDevice
    ) async throws -> AsyncThrowingStream<String, any Error>
    /// A persistent chat over the loaded model, starting from `instructions` and `history` (see
    /// ``MLXSession``). The default refuses.
    func makeChat(spec: MLXModelSpec, folder: URL, instructions: String, history: [Chat.Message]) async throws -> any MLXChatTurning
    /// A token counter over the model if it is already loaded, else nil. Never loads. The default: nil.
    func residentTokenCounter(spec: MLXModelSpec, folder: URL) async -> (@Sendable (String) async -> Int)?
    /// A chat that owns its KV cache (prefill ahead, prompt lookup; spike #95). The default refuses.
    func makeIncrementalChat(spec: MLXModelSpec, folder: URL, options: MLXIncrementalChat.Options) async throws -> MLXIncrementalChat
}

extension MLXGenerating {
    func makeIncrementalChat(spec: MLXModelSpec, folder: URL, options: MLXIncrementalChat.Options) async throws -> MLXIncrementalChat {
        throw LLMError.unavailable(reason: "This MLX generator has no incremental chat.")
    }
}

/// How an MLX session runs its turns.
public enum MLXEngine: Sendable, Equatable {
    /// mlx-swift-lm's `ChatSession`.
    case chatSession
    /// ``MLXIncrementalChat``: its own KV cache, so text can be prefilled ahead of the request
    /// (``MLXProbeSupport/prefillAhead(_:text:)``); `draft` decodes with prompt lookup.
    case incremental(draft: Bool)
}

/// The real generator: mlx-swift-lm's `ChatSession` over the cached container.
///
/// MLX errors are caught with a scoped handler and thrown, instead of the default handler that ends the
/// process (an error raised on Metal's own completion threads is outside any task and still cannot be caught).
struct MLXChatGenerator: MLXGenerating {
    func makeIncrementalChat(spec: MLXModelSpec, folder: URL, options: MLXIncrementalChat.Options) async throws -> MLXIncrementalChat {
        #if canImport(Cmlx)
            let container = try await MLXModelCache.shared.container(for: spec, folder: folder)
            return await MLXIncrementalChat.make(container: container, spec: spec, options: options)
        #else
            throw LLMError.unavailable(reason: "MLX is not built in.")
        #endif
    }

    func load(spec: MLXModelSpec, folder: URL, device: ComputeDevice) async throws {
        MLXCompile.prepare(for: device)
        try await MLX.withError {
            switch device {
            case .gpu: _ = try await MLXModelCache.shared.container(for: spec, folder: folder)
            case .cpu:
                _ = try await Device.withDefaultDevice(.cpu) {
                    try await MLXModelCache.shared.containerForCPU(spec: spec, folder: folder)
                }
            }
        }
    }

    func stream(
        spec: MLXModelSpec, folder: URL, instructions: String, examples: [LLMExample], prompt: String,
        device: ComputeDevice
    ) async throws -> AsyncThrowingStream<String, any Error> {
        let container = try await MLXModelCache.shared.container(for: spec, folder: folder)
        let session = ChatSession(
            container,
            instructions: instructions,
            generateParameters: GenerateParameters(maxTokens: 1_024, temperature: 0),
            additionalContext: ["enable_thinking": false])
        let messages = MLXBackend.chatMessages(examples: examples, prompt: prompt)
        MLXCompile.prepare(for: device)
        let errors = MLXErrorRecorder()
        // The generation task starts inside `streamResponse` and inherits the default device and the error
        // handler from here.
        let upstream = MLX.withErrorHandler(errors.record) {
            switch device {
            case .gpu: session.streamResponse(to: messages)
            case .cpu: Device.withDefaultDevice(.cpu) { session.streamResponse(to: messages) }
            }
        }
        return AsyncThrowingStream { continuation in
            let relay = Task {
                do {
                    for try await chunk in upstream {
                        try errors.check()
                        continuation.yield(chunk)
                    }
                    try errors.check()
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            // Dropping the stream cancels the relay, which ends `upstream` and so the generation.
            continuation.onTermination = { _ in relay.cancel() }
        }
    }
}


/// An installed MLX model as a cleanup (or later summary) backend.
///
/// Runs greedy decoding with Qwen3's thinking mode off. Each `respond` call uses a fresh chat session, so
/// nothing carries over between calls; ``makeSession()`` keeps one chat session (and its KV cache) across
/// turns. MLX array work needs the Metal shaders that only an Xcode build produces.
///
/// On ``ComputeDevice/cpu`` the load and the generation run with the CPU as the task's default device, so
/// no GPU work is submitted (the phone's background), and with MLX compile off where the CPU cannot run
/// compiled kernels (iOS, see ``MLXCompile``), on a float32 copy of the model's bfloat16 parameters (see
/// ``MLXModelCache/containerForCPU(spec:folder:)``). The loaded model is shared with the GPU backend: MLX
/// arrays live in unified memory and any device computes on them, and the weights load on the CPU stream
/// either way, so one resident copy serves both and a device switch reloads nothing.
public final class MLXBackend: LLMBackend, ModelResourceLifecycle {
    public let spec: MLXModelSpec
    public let folder: URL
    public let device: ComputeDevice
    public let engine: MLXEngine
    private let canUseGPU: @Sendable () async -> Bool
    private let generator: any MLXGenerating

    public var id: String { device == .gpu ? "mlx:\(spec.repo)" : "mlx-cpu:\(spec.repo)" }

    /// Instructions, prompt and reply together, in characters; small models drift on long input.
    public let maxPromptCharacters: Int? = 4_000

    /// The context a session keeps (tokens, reply included): the small-model window, not the checkpoint's.
    static let sessionWindow = 4_096
    /// ``sessionWindow``, for hosts that size a context share (spike #95).
    public static var contextWindow: Int { sessionWindow }
    /// Tokens a reply may take.
    static let replyLimit = 1_024
    /// Sessions handed out; releasing the model ends them.
    private let sessions = LLMSessionSet()

    public func prewarmResources() async throws {
        try Task.checkCancellation()
        guard MLXInstaller.isComplete(folder: folder) else {
            throw LLMError.unavailable(reason: "The selected model is not installed")
        }
        let gpuAllowed = await canUseGPU()
        try Task.checkCancellation()
        let usableDevice: ComputeDevice = device == .gpu && gpuAllowed ? .gpu : .cpu
        try await generator.load(spec: spec, folder: folder, device: usableDevice)
        try Task.checkCancellation()
    }

    public func releaseWarmResources() async {
        await sessions.closeAll()
        // Dropping the cache's reference does not join or destroy a native generation worker.
        await MLXModelCache.shared.evict(folder: folder)
    }

    /// A persistent session: one `ChatSession` and its KV cache across turns. Releasing the model ends it.
    public func makeSession() async throws -> any LLMSession {
        guard MLXInstaller.isComplete(folder: folder) else {
            throw LLMError.unavailable(reason: "\(spec.displayName) is not downloaded.")
        }
        let session = MLXSession(backend: self, tokenBudget: Self.sessionWindow - Self.replyLimit)
        await sessions.insert(session)
        return session
    }

    func makeIncrementalChat(_ options: MLXIncrementalChat.Options) async throws -> MLXIncrementalChat {
        try await generator.load(spec: spec, folder: folder, device: await currentDevice())
        return try await generator.makeIncrementalChat(spec: spec, folder: folder, options: options)
    }

    /// The incremental chat's options when the sessions use one.
    var incrementalOptions: MLXIncrementalChat.Options? {
        guard case .incremental(let draft) = engine else { return nil }
        return MLXIncrementalChat.Options(draft: draft)
    }

    func makeChat(instructions: String, history: [Chat.Message]) async throws -> any MLXChatTurning {
        try await generator.load(spec: spec, folder: folder, device: await currentDevice())
        return try await generator.makeChat(spec: spec, folder: folder, instructions: instructions, history: history)
    }

    func gpuUsable() async -> Bool { await canUseGPU() }

    func residentTokenCounter() async -> (@Sendable (String) async -> Int)? {
        await generator.residentTokenCounter(spec: spec, folder: folder)
    }

    /// - Parameters:
    ///   - device: where the model runs while the GPU is usable; ``ComputeDevice/cpu`` always runs on the CPU.
    ///   - canUseGPU: whether GPU work may be submitted now (`false`: the phone app is in the background).
    public convenience init(
        spec: MLXModelSpec, folder: URL, device: ComputeDevice = .gpu,
        canUseGPU: @escaping @Sendable () async -> Bool = CleanupRegistry.defaultCanUseGPU, engine: MLXEngine = .chatSession
    ) {
        self.init(spec: spec, folder: folder, device: device, canUseGPU: canUseGPU, generator: MLXChatGenerator(), engine: engine)
    }

    init(
        spec: MLXModelSpec, folder: URL, device: ComputeDevice, canUseGPU: @escaping @Sendable () async -> Bool,
        generator: any MLXGenerating, engine: MLXEngine = .chatSession
    ) {
        self.spec = spec
        self.folder = folder
        self.device = device
        self.engine = engine
        self.canUseGPU = canUseGPU
        self.generator = generator
    }

    public var availability: LLMAvailability {
        get async {
            MLXInstaller.isComplete(folder: folder)
                ? .available : .unavailable(reason: "\(spec.displayName) is not downloaded.")
        }
    }

    public func respond(instructions: String, prompt: String) async throws -> String {
        try await respond(instructions: instructions, examples: [], prompt: prompt)
    }

    /// Decides the device at the load and again at the generation (the app may have left the foreground in
    /// between), and checks before every further token: a cancelled call (a stage past its time limit) stops,
    /// and a GPU generation stops once the GPU is no longer usable, so no more work is submitted.
    public func respond(instructions: String, examples: [LLMExample], prompt: String) async throws -> String {
        guard MLXInstaller.isComplete(folder: folder) else {
            throw LLMError.unavailable(reason: "\(spec.displayName) is not downloaded.")
        }
        try Task.checkCancellation()
        try await generator.load(spec: spec, folder: folder, device: await currentDevice())
        try Task.checkCancellation()
        let device = await currentDevice()
        var reply = ""
        for try await chunk in try await generator.stream(
            spec: spec, folder: folder, instructions: instructions, examples: examples, prompt: prompt, device: device)
        {
            reply += chunk
            try Task.checkCancellation()
            if device == .gpu, await !canUseGPU() {
                throw LLMError.unavailable(reason: "The GPU is no longer usable (the app left the foreground).")
            }
        }
        try Task.checkCancellation()
        guard !reply.allSatisfy(\.isWhitespace) else { throw LLMError.emptyResponse }
        return reply
    }

    /// Where the next load or generation runs: the CPU for a CPU backend or while the GPU is not usable.
    func currentDevice() async -> ComputeDevice {
        guard device == .gpu else { return .cpu }
        return await canUseGPU() ? .gpu : .cpu
    }

    /// The conversation after the system instructions: each example as a user turn and the answer to it,
    /// then the prompt.
    static func chatMessages(examples: [LLMExample], prompt: String?) -> [Chat.Message] {
        examples.flatMap { [Chat.Message.user($0.user), Chat.Message.assistant($0.assistant)] } + (prompt.map { [.user($0)] } ?? [])
    }
}
