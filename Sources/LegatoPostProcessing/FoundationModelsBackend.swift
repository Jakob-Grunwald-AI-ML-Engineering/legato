import Foundation
import LegatoCore

#if canImport(FoundationModels)
import FoundationModels

/// Apple's on-device system language model. The zero-download cleanup default.
///
/// Every call builds a fresh session, so nothing carries over between calls. The system model has a small
/// context window (about 4,000 tokens for prompt and reply together), so callers chunk long input at
/// ``maxPromptCharacters``.
public struct FoundationModelsBackend: LLMBackend, ModelResourceLifecycle {
    public let id = "apple-foundation-models"

    /// Instructions, prompt and reply together, in characters. About 4,000 tokens at roughly 2.5
    /// characters per token for German, with room to spare.
    public let maxPromptCharacters: Int? = 6_000

    private let warmResources = WarmResources()

    private actor WarmResources {
        private var session: LanguageModelSession?
        func prepare() {
            guard session == nil else { return }
            let session = LanguageModelSession(model: .default)
            session.prewarm()
            self.session = session
        }
        func release() { session = nil }
    }

    public init() {}

    /// Requests system-owned resource preparation without generating a reply. This is best effort:
    /// Foundation Models does not expose or guarantee its physical residency.
    public func prewarmResources() async throws {
        try Task.checkCancellation()
        if case .unavailable(let reason) = Self.currentAvailability() { throw LLMError.unavailable(reason: reason) }
        await warmResources.prepare()
        try Task.checkCancellation()
    }

    public func releaseWarmResources() async { await warmResources.release() }

    public var availability: LLMAvailability {
        get async { Self.currentAvailability() }
    }

    static func currentAvailability() -> LLMAvailability {
        switch SystemLanguageModel.default.availability {
        case .available:
            return .available
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible: return .unavailable(reason: "This device does not support Apple Intelligence.")
            case .appleIntelligenceNotEnabled: return .unavailable(reason: "Apple Intelligence is turned off.")
            case .modelNotReady: return .unavailable(reason: "The Apple on-device model is still downloading.")
            @unknown default: return .unavailable(reason: "The Apple on-device model is unavailable.")
            }
        }
    }

    public func respond(instructions: String, prompt: String) async throws -> String {
        try await respond(instructions: instructions, examples: [], prompt: prompt)
    }

    public func respond(instructions: String, examples: [LLMExample], prompt: String) async throws -> String {
        if case .unavailable(let reason) = Self.currentAvailability() {
            throw LLMError.unavailable(reason: reason)
        }
        let session = LanguageModelSession(
            model: .default, tools: [], transcript: Self.transcript(instructions: instructions, examples: examples))
        do {
            let response = try await session.respond(to: prompt, options: GenerationOptions(sampling: .greedy))
            return response.content
        } catch let error as LanguageModelSession.GenerationError {
            throw Self.map(error)
        }
    }

    /// The session's starting transcript: the instructions, then each example as a prompt and its response.
    static func transcript(instructions: String, examples: [LLMExample]) -> Transcript {
        func text(_ content: String) -> [Transcript.Segment] { [.text(Transcript.TextSegment(content: content))] }
        var entries: [Transcript.Entry] = [
            .instructions(Transcript.Instructions(segments: text(instructions), toolDefinitions: []))
        ]
        for example in examples {
            entries.append(.prompt(Transcript.Prompt(segments: text(example.user))))
            entries.append(.response(Transcript.Response(assetIDs: [], segments: text(example.assistant))))
        }
        return Transcript(entries: entries)
    }

    private static func map(_ error: LanguageModelSession.GenerationError) -> LLMError {
        switch error {
        case .guardrailViolation, .refusal: .guardrail
        case .exceededContextWindowSize: .contextTooLong
        case .assetsUnavailable: .unavailable(reason: "The Apple on-device model is unavailable.")
        default: .failed(error.localizedDescription)
        }
    }
}
#endif
