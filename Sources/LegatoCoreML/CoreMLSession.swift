import Foundation
import LegatoCore

extension CoreMLPrompt {
    /// What follows a generated reply to open the next user turn: the reply's end marker, the user turn and
    /// the generation prompt. Appended as tokens after the reply's own generated tokens, so the token
    /// sequence of turn N starts with exactly what turn N-1 left in the native state.
    static func continuation(user: String, family: CoreMLPromptFamily) -> String {
        switch family {
        case .qwen3:
            "<|im_end|>\n<|im_start|>user\n\(user)<|im_end|>\n<|im_start|>assistant\n<think>\n\n</think>\n\n"
        case .gemma3:
            "<end_of_turn>\n<start_of_turn>user\n\(user.trimmingCharacters(in: .whitespacesAndNewlines))<end_of_turn>\n<start_of_turn>model\n"
        }
    }
}

/// What a Core ML session turn cost, for probes and logs.
struct CoreMLTurnStats: Sendable, Equatable {
    var promptTokens: Int
    var prefilled: Int
    var prefillSeconds: Double
}

/// A persistent conversation on a ``CoreMLBackend``: ANEMLL's `MLState` and the token prefix it holds are
/// kept between turns, so each turn prefills only its new tokens. The first turn is checked against the
/// checkpoint's own chat template; later turns continue it token by token (the history keeps the empty
/// think block the model actually saw). A trim, a prefix mismatch, another caller on the backend or any
/// error starts the next turn from a fresh state; unloading the backend ends the session.
actor CoreMLSession: LLMSession {
    nonisolated let tokenBudget: Int
    private let backend: CoreMLBackend
    private let id: UUID
    private let family: CoreMLPromptFamily
    private var transcript = LLMTranscript()
    /// The conversation's tokens through the last reply (its generated tokens, no end marker), or `nil`
    /// when they must be rebuilt from the transcript (first turn, after a trim).
    private var committed: [Int]?
    private var closed = false
    private(set) var lastTurn: CoreMLTurnStats?

    init(backend: CoreMLBackend, id: UUID, family: CoreMLPromptFamily, tokenBudget: Int) {
        self.backend = backend; self.id = id; self.family = family; self.tokenBudget = tokenBudget
    }

    func usage() async throws -> LLMTokenUsage {
        try checkOpen()
        let runtime = try await backend.sessionRuntime(id)
        return try await transcript.usage { try await runtime.encode($0).count }
    }

    func append(_ chunk: LLMSessionChunk) async throws {
        try checkOpen()
        try transcript.append(chunk)
    }

    func respond(to request: String) async throws -> String {
        try checkOpen()
        let message = transcript.message(for: request)
        let tokens = try await turnTokens(user: message)
        let generated = try await backend.sessionTurn(id, tokens: tokens)
        guard !generated.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw LLMError.emptyResponse }
        lastTurn = CoreMLTurnStats(promptTokens: tokens.count, prefilled: generated.prefilled, prefillSeconds: generated.prefillSeconds)
        committed = tokens + generated.tokens
        transcript.record(user: message, assistant: generated.text)
        return generated.text
    }

    func respondStructured<Output: LLMStructuredOutput>(_ type: Output.Type, to request: String) async throws -> Output {
        let schema = LLMStructuredDecoding.instruction(for: Output.llmSchema)
        let reply = try await respond(to: request.isEmpty ? schema : request + "\n\n" + schema)
        return try LLMStructuredDecoding.decode(Output.self, from: reply)
    }

    func trim(keepingSuffix tokens: Int) async throws {
        try checkOpen()
        let runtime = try await backend.sessionRuntime(id)
        var trimmed = transcript  // One caller at a time (the contract), so no append interleaves here.
        guard try await trimmed.trim(keepingSuffix: tokens, count: { try await runtime.encode($0).count }) else { return }
        transcript = trimmed
        committed = nil
        await backend.resetSession(id)
    }

    func close() async {
        guard !closed else { return }
        closed = true
        await backend.closeSession(id)
    }

    private func checkOpen() throws { if closed { throw LLMSessionError.closed } }

    /// The full token sequence of the next turn: the committed conversation, then the continuation.
    private func turnTokens(user: String) async throws -> [Int] {
        let runtime = try await backend.sessionRuntime(id)
        if let committed { return committed + (try await runtime.encode(CoreMLPrompt.continuation(user: user, family: family))) }
        let turns = transcript.turns
        guard let first = turns.first else {
            return try await runtime.tokens(instructions: transcript.instructions, examples: transcript.examples, prompt: user)
        }
        var tokens = try await runtime.tokens(instructions: transcript.instructions, examples: transcript.examples, prompt: first.user)
        tokens += try await runtime.encode(first.assistant)
        for turn in turns.dropFirst() {
            tokens += try await runtime.encode(CoreMLPrompt.continuation(user: turn.user, family: family))
            tokens += try await runtime.encode(turn.assistant)
        }
        committed = tokens
        return tokens + (try await runtime.encode(CoreMLPrompt.continuation(user: user, family: family)))
    }
}
