import Foundation
import LegatoCore
import MLX
import MLXLMCommon
import Synchronization

/// What one MLX session turn cost, as mlx-swift-lm reports it.
struct MLXTurnStats: Sendable, Equatable {
    /// Prompt tokens prefilled this turn.
    var prefilled: Int
    /// Prompt tokens served from the session's KV cache instead.
    var cached: Int
    var prefillSeconds: Double
}

enum MLXTurnEvent: Sendable {
    case chunk(String)
    case info(MLXTurnStats)
}

/// One live `ChatSession` (with its KV cache): the seam the session tests replace.
protocol MLXChatTurning: AnyObject, Sendable {
    /// The reply to `message` as the next user turn, generated on `device`; ending the iteration early
    /// stops the generation.
    func stream(_ message: String, device: ComputeDevice) -> AsyncThrowingStream<MLXTurnEvent, any Error>
    func tokenCount(_ text: String) async -> Int
}

extension MLXGenerating {
    func makeChat(spec: MLXModelSpec, folder: URL, instructions: String, history: [Chat.Message]) async throws -> any MLXChatTurning {
        throw LLMError.unavailable(reason: "This MLX generator cannot keep a session.")
    }
}

extension MLXChatGenerator {
    func makeChat(spec: MLXModelSpec, folder: URL, instructions: String, history: [Chat.Message]) async throws -> any MLXChatTurning {
        let container = try await MLXModelCache.shared.container(for: spec, folder: folder)
        return MLXChat(container: container, session: ChatSession(
            container, instructions: instructions, history: history,
            generateParameters: GenerateParameters(maxTokens: MLXBackend.replyLimit, temperature: 0),
            additionalContext: ["enable_thinking": false]))
    }
}

/// mlx-swift-lm's `ChatSession`: it keeps the KV cache of everything it already processed and prefills
/// only what a new turn adds (it re-renders the chat template and reuses the longest exact token prefix).
final class MLXChat: MLXChatTurning, @unchecked Sendable {
    private let container: ModelContainer
    private let session: ChatSession
    init(container: ModelContainer, session: ChatSession) { self.container = container; self.session = session }

    func tokenCount(_ text: String) async -> Int {
        await container.tokenizer.encode(text: text, addSpecialTokens: false).count
    }

    func stream(_ message: String, device: ComputeDevice) -> AsyncThrowingStream<MLXTurnEvent, any Error> {
        let errors = MLXErrorRecorder()
        let session = session
        // The generation task starts inside `streamDetails` and inherits the default device and the error
        // handler from here (as in `MLXChatGenerator.stream`).
        let upstream = MLX.withErrorHandler(errors.record) {
            switch device {
            case .gpu: session.streamDetails(to: [.user(message)])
            case .cpu: Device.withDefaultDevice(.cpu) { session.streamDetails(to: [.user(message)]) }
            }
        }
        return AsyncThrowingStream { continuation in
            let relay = Task {
                do {
                    for try await item in upstream {
                        try errors.check()
                        switch item {
                        case .chunk(let text): continuation.yield(.chunk(text))
                        case .info(let info):
                            continuation.yield(.info(MLXTurnStats(prefilled: info.promptTokenCount,
                                cached: info.cachedPromptTokenCount, prefillSeconds: info.promptTime)))
                        default: break
                        }
                    }
                    try errors.check()
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in relay.cancel() }
        }
    }
}

/// A persistent MLX conversation: one `ChatSession` (and its KV cache) serves every turn until a trim or an
/// error replaces it with a fresh one restored from the kept transcript. Devices are decided per turn as in
/// ``MLXBackend/respond(instructions:examples:prompt:)``.
actor MLXSession: LLMSession {
    nonisolated let tokenBudget: Int
    private let backend: MLXBackend
    private var transcript = LLMTranscript()
    private var live: (any MLXChatTurning)?
    private var closed = false
    private(set) var lastTurn: MLXTurnStats?

    init(backend: MLXBackend, tokenBudget: Int) { self.backend = backend; self.tokenBudget = tokenBudget }

    func usage() async throws -> LLMTokenUsage {
        try checkOpen()
        let chat = try await chat()
        return await transcript.usage { await chat.tokenCount($0) }
    }

    func append(_ chunk: LLMSessionChunk) async throws {
        try checkOpen()
        try transcript.append(chunk)
    }

    func respond(to request: String) async throws -> String {
        try checkOpen()
        let message = transcript.message(for: request)
        let chat = try await chat()
        do {
            try Task.checkCancellation()
            let device = await backend.currentDevice()
            var reply = ""
            for try await event in chat.stream(message, device: device) {
                switch event {
                case .chunk(let text): reply += text
                case .info(let stats): lastTurn = stats
                }
                try Task.checkCancellation()
                if device == .gpu, await !backend.gpuUsable() {
                    throw LLMError.unavailable(reason: "The GPU is no longer usable (the app left the foreground).")
                }
            }
            try checkOpen()
            guard !reply.allSatisfy(\.isWhitespace) else { throw LLMError.emptyResponse }
            transcript.record(user: message, assistant: reply)
            return reply
        } catch {
            live = nil  // The chat's cache may hold a partial turn; the next turn restores from the transcript.
            throw error
        }
    }

    func respondStructured<Output: LLMStructuredOutput>(_ type: Output.Type, to request: String) async throws -> Output {
        let schema = LLMStructuredDecoding.instruction(for: Output.llmSchema)
        let reply = try await respond(to: request.isEmpty ? schema : request + "\n\n" + schema)
        return try LLMStructuredDecoding.decode(Output.self, from: reply)
    }

    func trim(keepingSuffix tokens: Int) async throws {
        try checkOpen()
        let chat = try await chat()
        var trimmed = transcript  // One caller at a time (the contract), so no append interleaves here.
        guard await trimmed.trim(keepingSuffix: tokens, count: { await chat.tokenCount($0) }) else { return }
        transcript = trimmed
        live = nil
    }

    func close() async { closed = true; live = nil }

    private func checkOpen() throws { if closed { throw LLMSessionError.closed } }

    private func chat() async throws -> any MLXChatTurning {
        if let live { return live }
        let history = MLXBackend.chatMessages(
            examples: transcript.examples + transcript.turns.map { LLMExample(user: $0.user, assistant: $0.assistant) },
            prompt: nil)
        let chat = try await backend.makeChat(instructions: transcript.instructions, history: history)
        live = chat
        return chat
    }
}

/// The first MLX error raised during a generation, thrown at the next chunk.
final class MLXErrorRecorder: Sendable {
    private let first = Mutex<String?>(nil)

    var record: @Sendable (String) -> Void {
        { [self] message in self.first.withLock { if $0 == nil { $0 = message } } }
    }

    func check() throws {
        if let message = first.withLock({ $0 }) { throw LLMError.failed("MLX: \(message)") }
    }
}
