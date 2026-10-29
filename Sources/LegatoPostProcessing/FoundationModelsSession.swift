import Foundation
import LegatoCore

#if canImport(FoundationModels)
import FoundationModels

/// One live system-model conversation: the seam the session tests replace.
protocol FoundationModelsTurning: AnyObject, Sendable {
    func respond(to prompt: String) async throws -> String
    /// Guided generation: the reply is generated against `schema` and returned as its JSON.
    func respondJSON(to prompt: String, schema: GenerationSchema) async throws -> String
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
}

/// A persistent Foundation Models conversation: one `LanguageModelSession` serves every turn (the system
/// keeps its transcript and cached state), until a trim or an error replaces it with a fresh session built
/// from the kept transcript. Structured replies use guided generation against the schema, then the same
/// strict decoder as every backend.
actor FoundationModelsSession: LLMSession {
    nonisolated let tokenBudget: Int
    private let count: @Sendable (String) async throws -> Int
    private let makeTurns: @Sendable (Transcript) -> any FoundationModelsTurning
    private var transcript = LLMTranscript()
    private var live: (any FoundationModelsTurning)?
    private var closed = false

    init(tokenBudget: Int, count: @escaping @Sendable (String) async throws -> Int,
         makeTurns: @escaping @Sendable (Transcript) -> any FoundationModelsTurning) {
        self.tokenBudget = tokenBudget; self.count = count; self.makeTurns = makeTurns
    }

    func usage() async throws -> LLMTokenUsage {
        try checkOpen()
        return try await transcript.usage(count: count)
    }

    func append(_ chunk: LLMSessionChunk) async throws {
        try checkOpen()
        try transcript.append(chunk)
    }

    func respond(to request: String) async throws -> String {
        try await turn(request) { try await $0.respond(to: $1) }
    }

    func respondStructured<Output: LLMStructuredOutput>(_ type: Output.Type, to request: String) async throws -> Output {
        let schema = try Self.generationSchema(for: Output.llmSchema)
        let json = try await turn(request) { try await $0.respondJSON(to: $1, schema: schema) }
        return try LLMStructuredDecoding.decode(Output.self, from: json)
    }

    func trim(keepingSuffix tokens: Int) async throws {
        try checkOpen()
        var trimmed = transcript  // One caller at a time (the contract), so no append interleaves here.
        guard try await trimmed.trim(keepingSuffix: tokens, count: count) else { return }
        transcript = trimmed
        live = nil
    }

    func close() async { closed = true; live = nil }

    private func checkOpen() throws { if closed { throw LLMSessionError.closed } }

    private func turn(_ request: String, _ send: (any FoundationModelsTurning, String) async throws -> String) async throws -> String {
        try checkOpen()
        let message = transcript.message(for: request)
        let turns: any FoundationModelsTurning
        if let live { turns = live } else {
            turns = makeTurns(Self.transcript(transcript))
            live = turns
        }
        do {
            let reply = try await send(turns, message)
            try checkOpen()
            transcript.record(user: message, assistant: reply)
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
