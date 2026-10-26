import Foundation

/// A dictionary lookup, asynchronous because the platform checkers live on the main actor.
///
/// Language codes are bare ("de", "en"); an implementation maps them to what its API expects.
public protocol SpellChecking: Sendable {
    /// Whether `word` is spelled correctly in `language` (a word the dictionary knows).
    func isKnown(_ word: String, language: String) async -> Bool
    /// Suggested corrections for `word` in `language`, best first.
    func guesses(for word: String, language: String) async -> [String]
}
