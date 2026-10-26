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
}

/// The real generator: mlx-swift-lm's `ChatSession` over the cached container.
///
/// MLX errors are caught with a scoped handler and thrown, instead of the default handler that ends the
/// process (an error raised on Metal's own completion threads is outside any task and still cannot be caught).
struct MLXChatGenerator: MLXGenerating {
    func load(spec: MLXModelSpec, folder: URL, device: ComputeDevice) async throws {
        try await MLX.withError {
            switch device {
            case .gpu: _ = try await MLXModelCache.shared.container(for: spec, folder: folder)
            case .cpu:
                _ = try await Device.withDefaultDevice(.cpu) {
                    try await MLXModelCache.shared.container(for: spec, folder: folder)
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

/// The first MLX error raised during a generation, thrown at the next chunk.
private final class MLXErrorRecorder: Sendable {
    private let first = Mutex<String?>(nil)

    var record: @Sendable (String) -> Void {
        { [self] message in self.first.withLock { if $0 == nil { $0 = message } } }
    }

    func check() throws {
        if let message = first.withLock({ $0 }) { throw LLMError.failed("MLX: \(message)") }
    }
}

/// An installed MLX model as a cleanup (or later summary) backend.
///
/// Runs greedy decoding with Qwen3's thinking mode off. Each call uses a fresh chat session, so nothing
/// carries over between calls. MLX array work needs the Metal shaders that only an Xcode build produces.
///
/// On ``ComputeDevice/cpu`` the load and the generation run with the CPU as the task's default device, so
/// no GPU work is submitted (the phone's background). The loaded model is shared with the GPU backend: MLX
/// arrays live in unified memory and any device computes on them, and the weights load on the CPU stream
/// either way, so one resident copy serves both and a device switch reloads nothing.
public final class MLXBackend: LLMBackend {
    public let spec: MLXModelSpec
    public let folder: URL
    public let device: ComputeDevice
    private let canUseGPU: @Sendable () async -> Bool
    private let generator: any MLXGenerating

    public var id: String { device == .gpu ? "mlx:\(spec.repo)" : "mlx-cpu:\(spec.repo)" }

    /// Instructions, prompt and reply together, in characters; small models drift on long input.
    public let maxPromptCharacters: Int? = 4_000

    /// - Parameters:
    ///   - device: where the model runs while the GPU is usable; ``ComputeDevice/cpu`` always runs on the CPU.
    ///   - canUseGPU: whether GPU work may be submitted now (`false`: the phone app is in the background).
    public convenience init(
        spec: MLXModelSpec, folder: URL, device: ComputeDevice = .gpu,
        canUseGPU: @escaping @Sendable () async -> Bool = CleanupRegistry.defaultCanUseGPU
    ) {
        self.init(spec: spec, folder: folder, device: device, canUseGPU: canUseGPU, generator: MLXChatGenerator())
    }

    init(
        spec: MLXModelSpec, folder: URL, device: ComputeDevice, canUseGPU: @escaping @Sendable () async -> Bool,
        generator: any MLXGenerating
    ) {
        self.spec = spec
        self.folder = folder
        self.device = device
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
    static func chatMessages(examples: [LLMExample], prompt: String) -> [Chat.Message] {
        examples.flatMap { [Chat.Message.user($0.user), Chat.Message.assistant($0.assistant)] } + [.user(prompt)]
    }
}
