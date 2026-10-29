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
    func residentTokenCounter(spec: MLXModelSpec, folder: URL) async -> (@Sendable (String) async -> Int)? { nil }
}

extension MLXChatGenerator {
    /// The tokenizer of the model when it is already loaded; never loads it.
    func residentTokenCounter(spec: MLXModelSpec, folder: URL) async -> (@Sendable (String) async -> Int)? {
        guard await MLXModelCache.shared.residentFolders.contains(folder.standardizedFileURL.path),
              let container = try? await MLXModelCache.shared.container(for: spec, folder: folder) else { return nil }
        return { await container.tokenizer.encode(text: $0, addSpecialTokens: false).count }
    }

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
/// ``MLXBackend/respond(instructions:examples:prompt:)``. Counting never loads the model: without a live chat
/// it uses the resident model's tokenizer, or an estimate when the model is not resident.
///
/// Turns, counts and trims run one at a time (``LLMTurnGate``); appends do not wait.
actor MLXSession: LLMSessionMetrics {
    nonisolated let tokenBudget: Int
    private let backend: MLXBackend
    private var transcript = LLMTranscript()
    private var live: (any MLXChatTurning)?
    private var closed = false
    private var gate = LLMTurnGate()
    private(set) var lastTurn: MLXTurnStats?
    /// Seconds from the start of the last turn's generation to its first text chunk (session probe, #95).
    private(set) var lastFirstChunkSeconds: Double?

    init(backend: MLXBackend, tokenBudget: Int) { self.backend = backend; self.tokenBudget = tokenBudget }

    func usage() async throws -> LLMTokenUsage {
        try await exclusive {
            let count = await counter()
            return await transcript.usage { await count($0) }
        }
    }

    func append(_ chunk: LLMSessionChunk) async throws {
        try checkOpen()
        try transcript.append(chunk)
    }

    func respond(to request: String) async throws -> String {
        try await exclusive { try await turn(request) }
    }

    func respondStructured<Output: LLMStructuredOutput>(_ type: Output.Type, to request: String) async throws -> Output {
        try await exclusive {
            let schema = LLMStructuredDecoding.instruction(for: Output.llmSchema)
            let reply = try await turn(request.isEmpty ? schema : request + "\n\n" + schema)
            do { return try LLMStructuredDecoding.decode(Output.self, from: reply) } catch {
                // Not an answer: the transcript forgets it (its text is pending again) and the chat, whose
                // cache holds it, is rebuilt from the transcript next turn.
                transcript.revertLastTurn()
                live = nil
                throw error
            }
        }
    }

    func trim(keepingSuffix tokens: Int) async throws {
        try await exclusive {
            let count = await counter()
            let original = transcript
            var trimmed = original
            guard await trimmed.trim(keepingSuffix: tokens, count: { await count($0) }) else { return }
            try trimmed.carryAppends(from: transcript, since: original)
            transcript = trimmed
            live = nil
        }
    }

    /// Opens the chat on the transcript so far (the head). mlx-swift-lm prefills only with a generation, so
    /// the head is processed with the first turn; this loads nothing that is not resident already.
    func warm() async throws {
        try await exclusive { _ = try await chat() }
    }

    func close() async { closed = true; live = nil }

    func lastTurnMetrics() -> LLMTurnMetrics? {
        lastTurn.map { LLMTurnMetrics(promptTokens: $0.prefilled + $0.cached, prefilledTokens: $0.prefilled, prefillSeconds: $0.prefillSeconds) }
    }
    func lastWarmMetrics() -> LLMTurnMetrics? { nil }

    private func checkOpen() throws { if closed { throw LLMSessionError.closed } }

    private func exclusive<T: Sendable>(_ body: () async throws -> T) async throws -> T {
        try checkOpen()
        if !gate.enter() { await withCheckedContinuation { gate.wait($0) } }
        defer { gate.leave() }
        try checkOpen()
        return try await body()
    }

    private func turn(_ request: String) async throws -> String {
        let consumed = transcript.pending
        let message = transcript.message(for: request)
        let chat = try await chat()
        do {
            try Task.checkCancellation()
            let device = await backend.currentDevice()
            var reply = ""
            let started = ContinuousClock.now
            lastFirstChunkSeconds = nil
            for try await event in chat.stream(message, device: device) {
                switch event {
                case .chunk(let text):
                    if lastFirstChunkSeconds == nil {
                        let elapsed = ContinuousClock.now - started
                        lastFirstChunkSeconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
                    }
                    reply += text
                case .info(let stats): lastTurn = stats
                }
                try Task.checkCancellation()
                if device == .gpu, await !backend.gpuUsable() {
                    throw LLMError.unavailable(reason: "The GPU is no longer usable (the app left the foreground).")
                }
            }
            try checkOpen()
            guard !reply.allSatisfy(\.isWhitespace) else { throw LLMError.emptyResponse }
            transcript.record(user: message, assistant: reply, consumed: consumed)
            return reply
        } catch {
            live = nil  // The chat's cache may hold a partial turn; the next turn restores from the transcript.
            throw error
        }
    }

    /// The live chat's tokenizer, else the resident model's, else about three characters per token.
    private func counter() async -> @Sendable (String) async -> Int {
        if let live { return { await live.tokenCount($0) } }
        if let resident = await backend.residentTokenCounter() { return resident }
        return { ($0.utf8.count + 2) / 3 }
    }

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
