import Foundation

/// A dictionary lookup, asynchronous because the platform checkers live on the main actor.
///
/// Language codes are bare ("de", "en"); an implementation maps them to what its API expects.
public protocol SpellChecking: Sendable {
    /// Whether `word` is spelled correctly in `language` (a word the dictionary knows).
    func isKnown(_ word: String, language: String) async -> Bool
    /// Suggested corrections for `word` in `language`, best first.
    func guesses(for word: String, language: String) async -> [String]
    /// For each distinct word of `words`, the subset of `languages` whose dictionary knows it (empty when none
    /// does). One call checks a whole text, so a platform checker can hop to the main actor once.
    func knownLanguages(for words: [String], languages: [String]) async -> [String: Set<String>]
}

extension SpellChecking {
    /// The batch lookup as a loop over ``isKnown(_:language:)``.
    public func knownLanguages(for words: [String], languages: [String]) async -> [String: Set<String>] {
        var out: [String: Set<String>] = [:]
        for word in words where out[word] == nil {
            var known = Set<String>()
            for language in languages {
                if await isKnown(word, language: language) { known.insert(language) }
            }
            out[word] = known
        }
        return out
    }

    /// ``knownLanguages(for:languages:)`` where a capitalised word that is not all caps (a German noun, the
    /// start of a sentence) also counts as known in the languages that know its lowercase form.
    func knownLanguagesFolding(_ words: [String], languages: [String]) async -> [String: Set<String>] {
        func capitalised(_ word: String) -> Bool { word.first?.isUppercase == true && word != word.uppercased() }
        let lookup = words + words.filter(capitalised).map { $0.lowercased() }
        let found = await knownLanguages(for: lookup, languages: languages)
        var out: [String: Set<String>] = [:]
        for word in words {
            out[word] = (found[word] ?? []).union(capitalised(word) ? found[word.lowercased()] ?? [] : [])
        }
        return out
    }
}
