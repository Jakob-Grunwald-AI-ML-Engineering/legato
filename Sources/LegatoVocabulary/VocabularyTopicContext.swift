import Foundation

/// Transient context for ordering already-qualified vocabulary. The caller supplies the bounded text
/// available to this request. Nothing is stored or counted as new vocabulary evidence here.
public struct VocabularyTopicContext: Sendable {
    public struct Take: Sendable {
        public let raw: String
        public let recognitionHints: [String]

        public init(raw: String, recognitionHints: [String]) {
            self.raw = raw
            self.recognitionHints = recognitionHints
        }
    }

    private let field: Passage
    private let recent: [Passage]

    /// Takes are oldest first, with a receipt for each. Legacy takes without a receipt are omitted.
    /// Field exclusions are normalized cue words from earlier Legato output still present in the field.
    public init(recentTakes: [Take] = [], textBeforeCursor: String = "", excludedFieldWords: Set<String> = []) {
        field = Passage(textBeforeCursor, excluding: excludedFieldWords)
        recent = recentTakes.reversed().map {
            Passage($0.raw, excluding: VocabularyLearner.cueWords(in: $0.recognitionHints.joined(separator: " ")))
        }
    }

    /// No alias or fuzzy hit can give a term a topic boost. Each previous take contributes at most
    /// once per term, even if it repeated the term or used multiple accepted spellings.
    func priorities(for entries: [VocabularyEntry]) -> [UUID: Priority] {
        guard !field.words.isEmpty || recent.contains(where: { !$0.words.isEmpty }) else { return [:] }
        var result: [UUID: Priority] = [:]
        for entry in entries {
            let forms = ([entry.text] + entry.spellings).map(VocabularyLearner.orderedCueWords)
            let fieldHit = field.contains(any: forms)
            var recentWeight = 0.0
            for (distance, passage) in recent.enumerated() where passage.contains(any: forms) {
                recentWeight += 1 / Double(distance + 1)
            }
            guard fieldHit || recentWeight > 0 else { continue }
            // The same burst is more informative for a term used occasionally than for one used daily.
            result[entry.id] = Priority(fieldHit: fieldHit, lift: recentWeight / max(1, entry.score))
        }
        return result
    }

    struct Priority: Comparable {
        let fieldHit: Bool
        let lift: Double

        static let absent = Self(fieldHit: false, lift: 0)

        static func < (lhs: Self, rhs: Self) -> Bool {
            if lhs.fieldHit != rhs.fieldHit { return !lhs.fieldHit }
            return lhs.lift < rhs.lift
        }
    }

    private struct Passage: Sendable {
        let words: [String]
        let starts: [String: [Int]]
        let excluded: Set<String>

        init(_ text: String, excluding excluded: Set<String>) {
            let words = VocabularyLearner.orderedCueWords(in: text)
            self.words = words
            self.starts = Dictionary(grouping: words.indices, by: { words[$0] })
            self.excluded = excluded
        }

        func contains(any forms: [[String]]) -> Bool {
            forms.contains { phrase in
                guard let first = phrase.first, let indices = starts[first], excluded.isDisjoint(with: phrase) else {
                    return false
                }
                return indices.contains { words[$0...].starts(with: phrase) }
            }
        }
    }
}
