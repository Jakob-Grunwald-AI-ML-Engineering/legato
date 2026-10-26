import Foundation
import LegatoCore

/// Maps vocabulary hints to `AnalysisContext` contextual strings.
enum AppleSpeechVocabulary {
    /// Each hint's text, then its spellings, flattened in order and de-duplicated ignoring case. Blank
    /// strings are dropped.
    static func contextualStrings(_ hints: [VocabularyHint]) -> [String] {
        var seen = Set<String>()
        var strings: [String] = []
        for hint in hints {
            for raw in [hint.text] + hint.spellings {
                let string = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                if !string.isEmpty, seen.insert(string.lowercased()).inserted { strings.append(string) }
            }
        }
        return strings
    }
}
