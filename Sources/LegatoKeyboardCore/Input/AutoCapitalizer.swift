import Foundation

/// Mirrors `UITextAutocapitalizationType` (same raw values) without importing UIKit.
public enum AutoCapitalizationType: Int, Sendable {
    case none = 0, words, sentences, allCharacters
}

public enum AutoCapitalizer {
    /// Whether the next letter should be uppercase.
    public static func shouldCapitalize(_ type: AutoCapitalizationType, context: TextContext) -> Bool {
        switch type {
        case .none:
            return false
        case .allCharacters:
            return true
        case .words:
            guard context.wordPrefix.isEmpty else { return false }
            return context.lastCharacter.map(\.isWhitespace) ?? true
        case .sentences:
            return context.wordPrefix.isEmpty && context.isSentenceStart
        }
    }
}
