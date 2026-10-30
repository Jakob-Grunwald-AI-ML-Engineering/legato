import Foundation
import LegatoCore

#if canImport(FoundationModels)
import FoundationModels

/// One live system-model conversation: the seam the session tests replace.
protocol FoundationModelsTurning: AnyObject, Sendable {
    func respond(to prompt: String) async throws -> String
    /// Guided generation: the reply is generated against `schema` and returned as its JSON.
    func respondJSON(to prompt: String, schema: GenerationSchema) async throws -> String
    /// Loads the model and caches the session's transcript, and `promptPrefix` (how the next prompt starts),
    /// ahead of that prompt. Returns at once; the system works in the background.
    func prewarm(promptPrefix: String?)
}

/// A `LanguageModelSession`, confined to the owning ``FoundationModelsSession`` actor.
final class SystemModelTurns: FoundationModelsTurning, @unchecked Sendable {
    let session: LanguageModelSession
    init(transcript: Transcript) { session = LanguageModelSession(model: .default, tools: [], transcript: transcript) }
    func respond(to prompt: String) async throws -> String {
        try await session.respond(to: prompt, options: GenerationOptions(sampling: .greedy)).content
    }
    func respondJSON(to prompt: String, schema: GenerationSchema) async throws -> String {
        try await session.respond(to: prompt, schema: schema, includeSchemaInPrompt: true,
                                  options: GenerationOptions(sampling: .greedy)).content.jsonString
    }
    func prewarm(promptPrefix: String?) { session.prewarm(promptPrefix: promptPrefix.map { Prompt($0) }) }
}

/// A persistent Foundation Models conversation: one `LanguageModelSession` serves every turn (the system
/// keeps its transcript and cached state), until a trim or an error replaces it with a fresh session built
/// from the kept transcript. Structured replies use guided generation against the schema, then the same
/// strict decoder as every backend. The schema goes into the prompt (`includeSchemaInPrompt`), so it is
/// counted: with each structured turn in the history, and once more in the head as room for the next one.
///
/// Turns, counts and trims run one at a time (``LLMTurnGate``); appends do not wait.
actor FoundationModelsSession: LLMSession {
    nonisolated let tokenBudget: Int
    private let count: @Sendable (String) async throws -> Int
    private let makeTurns: @Sendable (Transcript) -> any FoundationModelsTurning
    private var transcript = LLMTranscript()
    private var live: (any FoundationModelsTurning)?
    private var closed = false
    private var gate = LLMTurnGate()
    /// ``warm()`` was asked for: a trim reopens and prewarms the rebuilt system session right away.
    private var keepsWarm = false
    /// The schema text of the latest structured turn: reserved in the head for the next one.
    private var schemaReserve = ""

    init(tokenBudget: Int, count: @escaping @Sendable (String) async throws -> Int,
         makeTurns: @escaping @Sendable (Transcript) -> any FoundationModelsTurning) {
        self.tokenBudget = tokenBudget; self.count = count; self.makeTurns = makeTurns
    }

    func usage() async throws -> LLMTokenUsage {
        try await exclusive { try await currentUsage() }
    }

    func append(_ chunk: LLMSessionChunk) async throws {
        try checkOpen()
        try transcript.append(chunk)
    }

    func respond(to request: String) async throws -> String {
        try await exclusive { try await turn(request, counted: "") { try await $0.respond(to: $1) } }
    }

    func respondStructured<Output: LLMStructuredOutput>(_ type: Output.Type, to request: String) async throws -> Output {
        try await exclusive {
            let schema = try Self.generationSchema(for: Output.llmSchema)
            let schemaText = LLMStructuredDecoding.jsonSchema(Output.llmSchema)
            schemaReserve = schemaText
            let json = try await turn(request, counted: schemaText) { try await $0.respondJSON(to: $1, schema: schema) }
            do { return try LLMStructuredDecoding.decode(Output.self, from: json) } catch {
                transcript.revertLastTurn()
                live = nil  // The system transcript contains the rejected reply; rebuild from valid turns.
                throw error
            }
        }
    }

    func trim(keepingSuffix tokens: Int) async throws {
        try await exclusive {
            let original = transcript
            var trimmed = original
            let didTrim = try await trimmed.trim(keepingSuffix: tokens, count: count)
            try checkOpen()  // Token counting may have suspended while close() invalidated the session.
            guard didTrim else { return }
            try trimmed.carryAppends(from: transcript, since: original)
            transcript = trimmed
            live = nil
            if keepsWarm { openWarm() }
        }
    }

    /// Opens the system session on the transcript so far (the head) and prewarms it, with the pending text
    /// as the prompt prefix. Kept warm from then on: a trim reopens and prewarms the kept transcript.
    func warm() async throws {
        try await exclusive {
            keepsWarm = true
            guard live == nil else { return }
            openWarm()
        }
    }

    private func openWarm() {
        let turns = makeTurns(Self.transcript(transcript))
        turns.prewarm(promptPrefix: transcript.pending.isEmpty ? nil : transcript.pending)
        live = turns
    }

    func close() async { closed = true; live = nil }

    private func checkOpen() throws { if closed { throw LLMSessionError.closed } }

    private func exclusive<T: Sendable>(_ body: () async throws -> T) async throws -> T {
        try checkOpen()
        if !gate.enter() { await withCheckedContinuation { gate.wait($0) } }
        defer { gate.leave() }
        try checkOpen()
        return try await body()
    }

    private func currentUsage() async throws -> LLMTokenUsage {
        var usage = try await transcript.usage(count: count)
        if !schemaReserve.isEmpty { usage.head += try await count(schemaReserve) }
        return usage
    }

    private func turn(_ request: String, counted: String,
                      _ send: (any FoundationModelsTurning, String) async throws -> String) async throws -> String {
        let consumed = transcript.pending
        let message = transcript.message(for: request)
        let turns: any FoundationModelsTurning
        if let live { turns = live } else {
            turns = makeTurns(Self.transcript(transcript))
            live = turns
        }
        do {
            let reply = try await send(turns, message)
            try checkOpen()
            transcript.record(user: message, assistant: reply, consumed: consumed, counted: counted)
            return reply
        } catch let error as LanguageModelSession.GenerationError {
            live = nil  // The system session's transcript is unknown now; the next turn rebuilds it.
            if case .decodingFailure = error { throw LLMSessionError.invalidStructuredOutput(error.localizedDescription) }
            throw FoundationModelsBackend.map(error)
        } catch {
            live = nil
            throw error
        }
    }

    /// The system session's starting transcript: instructions, examples and kept turns as prompts and
    /// responses (the pending text goes with the next prompt).
    static func transcript(_ transcript: LLMTranscript) -> Transcript {
        let examples = transcript.examples + transcript.turns.map { LLMExample(user: $0.user, assistant: $0.assistant) }
        return FoundationModelsBackend.transcript(instructions: transcript.instructions, examples: examples)
    }

    static func generationSchema(for schema: LLMSchema) throws -> GenerationSchema {
        try GenerationSchema(root: dynamic(schema), dependencies: [])
    }

    private static func dynamic(_ schema: LLMSchema) -> DynamicGenerationSchema {
        switch schema {
        case .string: DynamicGenerationSchema(type: String.self)
        case .integer: DynamicGenerationSchema(type: Int.self)
        case .array(let element, _): DynamicGenerationSchema(arrayOf: dynamic(element))
        case .object(let name, let description, let properties):
            DynamicGenerationSchema(name: name, description: description, properties: properties.map { property in
                let description: String? = switch property.schema {
                case .string(let text), .integer(let text), .array(_, let text), .object(_, let text, _): text
                }
                return DynamicGenerationSchema.Property(name: property.name, description: description, schema: dynamic(property.schema))
            })
        }
    }
}
#endif
