import Foundation

/// Whether an ``LLMBackend`` can answer right now.
public enum LLMAvailability: Sendable, Hashable {
    case available
    /// Not usable; the reason is for display and logs (for example "model not downloaded").
    case unavailable(reason: String)

    public var isAvailable: Bool { self == .available }
}

/// Why an ``LLMBackend`` did not produce text.
public enum LLMError: Error, Sendable, Hashable {
    /// The backend is not usable; see ``LLMBackend/availability``.
    case unavailable(reason: String)
    /// The backend's safety system refused the input or the output.
    case guardrail
    /// The prompt does not fit the backend's context window.
    case contextTooLong
    /// The backend answered with nothing.
    case emptyResponse
    /// Any other backend failure; the message is for logs.
    case failed(String)
}

/// One example exchange shown to the model before the real request: what the user sent and the answer the
/// model should give to it.
public struct LLMExample: Sendable, Hashable {
    public var user: String
    public var assistant: String

    public init(user: String, assistant: String) {
        self.user = user
        self.assistant = assistant
    }
}

/// A language model that answers one self-contained request. Cleanup uses it now; summaries reuse it.
///
/// Every call is independent: no conversation state carries over between calls.
public protocol LLMBackend: Sendable {
    /// Stable identifier, recorded next to anything the backend produced.
    var id: String { get }

    /// Whether ``respond(instructions:prompt:)`` can run now. Cheap; never downloads.
    var availability: LLMAvailability { get async }

    /// A safe upper bound for `instructions` plus `prompt`, in characters, or `nil` when unknown.
    /// Callers chunk long input to stay below it.
    var maxPromptCharacters: Int? { get }

    /// Answers `prompt` under `instructions` and returns the model's text.
    ///
    /// - Throws: ``LLMError``; other errors are backend-specific.
    func respond(instructions: String, prompt: String) async throws -> String

    /// Like ``respond(instructions:prompt:)``, with `examples` shown first as earlier turns of the chat: each
    /// a user message and the model's answer to it. Chat models follow examples given as turns more closely
    /// than examples written into the instructions.
    ///
    /// The default folds the examples into `instructions`, so a backend that cannot send turns still works.
    func respond(instructions: String, examples: [LLMExample], prompt: String) async throws -> String
}

extension LLMBackend {
    public func respond(instructions: String, examples: [LLMExample], prompt: String) async throws -> String {
        guard !examples.isEmpty else { return try await respond(instructions: instructions, prompt: prompt) }
        let shown = examples.map { "Input:\n\($0.user)\nOutput:\n\($0.assistant)" }.joined(separator: "\n\n")
        return try await respond(instructions: instructions + "\n\nExamples:\n\n" + shown, prompt: prompt)
    }
}
