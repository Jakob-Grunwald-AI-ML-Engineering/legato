import Foundation

/// How strongly cleanup rewrites a transcript.
public enum CleanupStyle: String, Sendable, Equatable, CaseIterable, Codable {
    /// Punctuation, casing, spelling, written forms and misrecognitions; every word stays
    /// (``CleanupPrompt/standard`` under the strict ``CleanupGuard``).
    case verbatim
    /// Also drops fillers and false starts, applies spoken self-corrections and fixes grammar, keeping the
    /// meaning (``CleanupPrompt/message`` under ``CleanupGuard/message``).
    case message

    public var prompt: CleanupPrompt {
        switch self {
        case .verbatim: .standard
        case .message: .message
        }
    }

    public var cleanupGuard: CleanupGuard {
        switch self {
        case .verbatim: CleanupGuard()
        case .message: .message
        }
    }
}

extension CleanupPrompt {
    /// The standard prompt plus a short message-style addition. Same examples, user message and reader.
    public static let message = CleanupPrompt(
        name: "message",
        instructions: { locale, vocabulary in
            standard.instructions(locale, vocabulary) + "\n" + messageAddition
        },
        examples: { locale in standard.examples(locale) },
        userMessage: { text, locale, vocabulary in standard.userMessage(text, locale, vocabulary) },
        extractText: { reply in standard.extractText(reply) })

    static let messageAddition = """
        This is a message, so also: drop filler words (um, uh, äh, like, you know, halt) and false starts, apply the speaker's own corrections ("Friday, no wait, Thursday" becomes "Thursday"), and fix the grammar. Keep the meaning; add nothing.
        """
}
