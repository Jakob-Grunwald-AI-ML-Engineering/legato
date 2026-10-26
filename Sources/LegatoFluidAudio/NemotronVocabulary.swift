import FluidAudio
import Foundation
import LegatoCore

/// Maps vocabulary hints to Nemotron's custom-vocabulary terms.
///
/// FluidAudio boosts aliases and emits them as their own surfaces, so only a hint's `spellings` (alternative
/// correct surfaces) become aliases, never known mishearings. The weight stays at FluidAudio's default. Length
/// floors belong to the hint provider, not here.
enum NemotronVocabulary {
    /// One term per distinct hint text (case-insensitive, first wins); aliases are de-duplicated and never
    /// repeat the term itself.
    static func terms(_ hints: [VocabularyHint]) -> [CustomVocabularyTerm] {
        var seen = Set<String>()
        var terms: [CustomVocabularyTerm] = []
        for hint in hints {
            let text = hint.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, seen.insert(text.lowercased()).inserted else { continue }
            var aliasSeen: Set<String> = [text.lowercased()]
            var aliases: [String] = []
            for spelling in hint.spellings {
                let alias = spelling.trimmingCharacters(in: .whitespacesAndNewlines)
                if !alias.isEmpty, aliasSeen.insert(alias.lowercased()).inserted { aliases.append(alias) }
            }
            terms.append(CustomVocabularyTerm(text: text, aliases: aliases.isEmpty ? nil : aliases))
        }
        return terms
    }
}
