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

extension CoreMLPrompt {
    /// The start of a user turn, up to where its text begins.
    static func userOpening(family: CoreMLPromptFamily) -> String {
        switch family {
        case .qwen3: "<|im_start|>user\n"
        case .gemma3: "<start_of_turn>user\n"
        }
    }

    /// ``continuation(user:family:)`` up to the end of `user`: what follows a reply to open the next turn with
    /// its text so far, not yet closed.
    static func continuationOpening(user: String, family: CoreMLPromptFamily) -> String {
        switch family {
        case .qwen3: "<|im_end|>\n<|im_start|>user\n\(user)"
        case .gemma3: "<end_of_turn>\n<start_of_turn>user\n\(user.trimmingCharacters(in: .whitespacesAndNewlines))"
        }
    }
}

extension CoreMLPrompt {
    /// The rendering of the instructions and examples alone: what every first turn starts with.
    static func head(instructions: String, examples: [LLMExample], family: CoreMLPromptFamily) -> String {
        let sentinel = "\u{1}legato-head\u{1}"
        let full = render(instructions: instructions, examples: examples, prompt: sentinel, family: family)
        let marker = family == .qwen3 ? "<|im_start|>user\n" : "<start_of_turn>user\n"
        guard let prompt = full.range(of: sentinel),
              let turn = full.range(of: marker, options: .backwards, range: full.startIndex..<prompt.lowerBound) else { return "" }
        return String(full[..<turn.lowerBound])
    }
}

/// What a Core ML session turn cost, for probes and logs.
struct CoreMLTurnStats: Sendable, Equatable {
    /// The turn's full token sequence (what a fresh state would have to prefill).
    var prompt: [Int]
    var promptTokens: Int { prompt.count }
    var prefilled: Int
    var prefillSeconds: Double
}

/// A persistent conversation on a ``CoreMLBackend``: ANEMLL's `MLState` and the token prefix it holds are
/// kept between turns, so each turn prefills only what the state does not already hold. The first turn is
/// checked against the checkpoint's own chat template; later turns continue it token by token (the history
/// keeps the empty think block the model actually saw). ``warm()`` prefills the head; a trim rebuilds the
/// tokens from the kept transcript, and the backend reuses their common prefix with the state (at least the
/// head). Another caller on the backend or an error leaves a fresh state; unloading ends the session.
///
/// Turns, counts and trims run one at a time (``LLMTurnGate``); appends do not wait.
actor CoreMLSession: LLMSessionMetrics, LLMSessionPrefillAhead {
    nonisolated let tokenBudget: Int
    private let backend: CoreMLBackend
    let id: UUID
    private let family: CoreMLPromptFamily
    private var transcript = LLMTranscript()
    /// The conversation's tokens through the last reply (its generated tokens, no end marker), or `nil`
    /// when they must be rebuilt from the transcript (first turn, after a trim).
    private var committed: [Int]?
    private var closed = false
    private var gate = LLMTurnGate()
    private(set) var lastTurn: CoreMLTurnStats?
    private(set) var lastWarm: CoreMLPrefill?

    init(backend: CoreMLBackend, id: UUID, family: CoreMLPromptFamily, tokenBudget: Int) {
        self.backend = backend; self.id = id; self.family = family; self.tokenBudget = tokenBudget
    }

    func usage() async throws -> LLMTokenUsage {
        try await exclusive {
            let runtime = try await backend.sessionRuntime(id)
            return try await transcript.usage { try await runtime.encode($0).count }
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
            let before = committed
            let reply = try await turn(request.isEmpty ? schema : request + "\n\n" + schema)
            do { return try LLMStructuredDecoding.decode(Output.self, from: reply) } catch {
                // Not an answer: the transcript forgets it (its text is pending again); the native state's
                // common prefix with the next turn is still reused.
                transcript.revertLastTurn()
                committed = before
                throw error
            }
        }
    }

    func trim(keepingSuffix tokens: Int) async throws {
        try await exclusive {
            let runtime = try await backend.sessionRuntime(id)
            let original = transcript
            var trimmed = original
            guard try await trimmed.trim(keepingSuffix: tokens, count: { try await runtime.encode($0).count }) else { return }
            try trimmed.carryAppends(from: transcript, since: original)
            transcript = trimmed
            committed = nil  // Rebuilt next turn; the backend keeps the common prefix (the head) in the state.
        }
    }

    func warm() async throws {
        try await exclusive {
            guard committed == nil, transcript.turns.isEmpty else { return }
            let head = CoreMLPrompt.head(instructions: transcript.instructions, examples: transcript.examples, family: family)
            guard !head.isEmpty else { return }
            lastWarm = try await backend.sessionPrefill(id) { try await $0.encode(head) }
        }
    }

    /// Prefills `text` as the start of the next user turn, without closing it: the tokens up to the user text
    /// (the committed conversation, or the head on a first turn) plus the text, so the turn that follows reuses
    /// that prefix in the native state and only processes what came after. Tokens at the cut may be re-encoded.
    func prefillAhead(_ text: String) async throws -> (tokens: Int, seconds: Double)? {
        try await exclusive {
            let partial = transcript.message(for: text)
            let committed = committed, family = family
            let instructions = transcript.instructions, examples = transcript.examples, turns = transcript.turns
            let prefill = try await backend.sessionPrefill(id) { runtime in
                if let committed { return committed + (try await runtime.encode(CoreMLPrompt.continuationOpening(user: partial, family: family))) }
                guard turns.isEmpty else {
                    throw LLMError.unavailable(reason: "Prefill ahead after a trim is not supported on Core ML; the transcript is rebuilt on the next turn.")
                }
                let head = CoreMLPrompt.head(instructions: instructions, examples: examples, family: family)
                return try await runtime.encode(head + CoreMLPrompt.userOpening(family: family) + partial)
            }
            return (prefill.prefilled, prefill.seconds)
        }
    }

    func close() async {
        guard !closed else { return }
        closed = true
        await backend.closeSession(id)
    }

    func lastTurnMetrics() -> LLMTurnMetrics? {
        lastTurn.map { LLMTurnMetrics(promptTokens: $0.promptTokens, prefilledTokens: $0.prefilled, prefillSeconds: $0.prefillSeconds) }
    }
    func lastWarmMetrics() -> LLMTurnMetrics? {
        lastWarm.map { LLMTurnMetrics(prefilledTokens: $0.prefilled, prefillSeconds: $0.seconds) }
    }

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
        let plan = TurnPlan(committed: committed, instructions: transcript.instructions, examples: transcript.examples,
                            turns: transcript.turns, user: message, family: family)
        let (tokens, generated) = try await backend.sessionTurn(id) { try await plan.tokens($0) }
        guard !generated.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw LLMError.emptyResponse }
        lastTurn = CoreMLTurnStats(prompt: tokens, prefilled: generated.prefilled, prefillSeconds: generated.prefillSeconds)
        committed = tokens + generated.tokens
        transcript.record(user: message, assistant: generated.text, consumed: consumed)
        return generated.text
    }

    /// Everything a turn's tokens are rendered from, as values, so they render inside the backend's worker.
    private struct TurnPlan: Sendable {
        var committed: [Int]?
        var instructions: String
        var examples: [LLMExample]
        var turns: [LLMTranscript.Turn]
        var user: String
        var family: CoreMLPromptFamily

        /// The committed conversation (or the transcript rebuilt), then the continuation.
        func tokens(_ runtime: any CoreMLDriving) async throws -> [Int] {
            let next = CoreMLPrompt.continuation(user: user, family: family)
            if let committed { return committed + (try await runtime.encode(next)) }
            guard let first = turns.first else {
                return try await runtime.tokens(instructions: instructions, examples: examples, prompt: user)
            }
            var tokens = try await runtime.tokens(instructions: instructions, examples: examples, prompt: first.user)
            tokens += try await runtime.encode(first.assistant)
            for turn in turns.dropFirst() {
                tokens += try await runtime.encode(CoreMLPrompt.continuation(user: turn.user, family: family))
                tokens += try await runtime.encode(turn.assistant)
            }
            return tokens + (try await runtime.encode(next))
        }
    }
}
