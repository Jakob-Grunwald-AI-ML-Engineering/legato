import Foundation
import HuggingFace
import LegatoCore
import MLX
import LegatoModels
import MLXLLM
import MLXLMCommon
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

    public var id: String { device == .gpu ? "mlx:\(spec.repo)" : "mlx-cpu:\(spec.repo)" }

    /// Instructions, prompt and reply together, in characters; small models drift on long input.
    public let maxPromptCharacters: Int? = 4_000

    public init(spec: MLXModelSpec, folder: URL, device: ComputeDevice = .gpu) {
        self.spec = spec
        self.folder = folder
        self.device = device
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

    public func respond(instructions: String, examples: [LLMExample], prompt: String) async throws -> String {
        guard MLXInstaller.isComplete(folder: folder) else {
            throw LLMError.unavailable(reason: "\(spec.displayName) is not downloaded.")
        }
        switch device {
        case .gpu:
            return try await generate(instructions: instructions, examples: examples, prompt: prompt)
        case .cpu:
            return try await Device.withDefaultDevice(.cpu) {
                try await generate(instructions: instructions, examples: examples, prompt: prompt)
            }
        }
    }

    private func generate(instructions: String, examples: [LLMExample], prompt: String) async throws -> String {
        let container = try await MLXModelCache.shared.container(for: spec, folder: folder)
        let session = ChatSession(
            container,
            instructions: instructions,
            generateParameters: GenerateParameters(maxTokens: 1_024, temperature: 0),
            additionalContext: ["enable_thinking": false])
        let reply = try await session.respond(to: Self.chatMessages(examples: examples, prompt: prompt))
        guard !reply.allSatisfy(\.isWhitespace) else { throw LLMError.emptyResponse }
        return reply
    }

    /// The conversation after the system instructions: each example as a user turn and the answer to it,
    /// then the prompt.
    static func chatMessages(examples: [LLMExample], prompt: String) -> [Chat.Message] {
        examples.flatMap { [Chat.Message.user($0.user), Chat.Message.assistant($0.assistant)] } + [.user(prompt)]
    }
}
