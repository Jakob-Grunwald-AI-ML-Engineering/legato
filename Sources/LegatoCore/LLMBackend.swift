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
}
