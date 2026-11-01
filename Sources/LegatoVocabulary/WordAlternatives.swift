import Foundation

/// One ranked replacement for a tapped word.
public struct RankedAlternative: Sendable, Equatable {
    public var text: String
    /// The raw score plus the source prior.
    public var score: Double
    public var source: AlternativeKind
}

/// Merges the sources' candidates into the (at most three) suggestions for a tapped word.
public enum WordAlternatives {
    /// How many suggestions the keyboard has slots for.
    public static let limit = 3

    /// Added to a raw score, so that at an equal score engine beats vocabulary beats spell checker.
    static func prior(_ kind: AlternativeKind) -> Double {
        switch kind {
        case .engine: 0.02
        case .vocabulary: 0.01
        case .spellChecker: 0
        }
    }

    /// The best ``limit`` candidates over all `sources`, best first.
    ///
    /// The word itself never appears (compared case-insensitively), and a text offered more than once
    /// counts once at its best score. Ties keep the order of `sources`, then of their candidates.
    public static func rank(word: String, context: AlternativeContext, sources: [any AlternativeSource], wordPairs: WordPairModel? = nil) async -> [RankedAlternative] {
        let own = key(word)
        var best: [String: (alt: RankedAlternative, order: Int)] = [:]
        var order = 0
        for source in sources {
            for candidate in await source.candidates(for: word, context: context) {
                let k = key(candidate.text)
                order += 1
                guard !k.isEmpty, k != own else { continue }
                let previous = context.sentence[..<context.wordRange.lowerBound].split(whereSeparator: \.isWhitespace).last.map(String.init)
                let boost = previous.flatMap { wordPairs?.weight(of: candidate.text, after: $0, now: Date()) }.map { min(0.15, $0 * 0.03) } ?? 0
                let alt = RankedAlternative(text: candidate.text, score: candidate.score + prior(candidate.source) + boost, source: candidate.source)
                if let seen = best[k], seen.alt.score >= alt.score { continue }
                best[k] = (alt, best[k]?.order ?? order)
            }
        }
        let sorted = best.values.sorted { $0.alt.score != $1.alt.score ? $0.alt.score > $1.alt.score : $0.order < $1.order }
        return sorted.prefix(limit).map(\.alt)
    }

    private static func key(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
