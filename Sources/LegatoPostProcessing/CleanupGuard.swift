import Foundation

/// Rejects LLM output that drifted too far from the text it was asked to clean.
///
/// Both texts are reduced to lowercased word tokens without punctuation, so punctuation and casing fixes
/// cost nothing. The drift is the word-level edit distance over the longer token count: a spelling fix,
/// a written form or a misrecognition replaces a word or two and stays under the limit; an added or
/// dropped sentence, an answer, or a translation does not.
public struct CleanupGuard: Sendable {
    /// The limit tuned against the cleanup fixtures and the literal pairs in `CleanupStageTests`.
    public static let defaultMaxDrift = 0.25

    /// Candidates with a drift above this are rejected.
    public var maxDrift: Double

    public init(maxDrift: Double = CleanupGuard.defaultMaxDrift) { self.maxDrift = maxDrift }

    /// Lowercased runs of letters and digits.
    public static func tokens(_ text: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        for character in text.lowercased() {
            if character.isLetter || character.isNumber {
                current.append(character)
            } else if !current.isEmpty {
                tokens.append(current)
                current = ""
            }
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }

    /// Word-level edit distance over the longer token count, in `0...1`.
    public func drift(candidate: String, reference: String) -> Double {
        let a = Self.tokens(reference)
        let b = Self.tokens(candidate)
        let longest = max(a.count, b.count)
        guard longest > 0 else { return 0 }
        return Double(Self.editDistance(a, b)) / Double(longest)
    }

    /// Whether `candidate` is a faithful cleanup of `reference`.
    public func accepts(_ candidate: String, reference: String) -> Bool {
        if Self.tokens(candidate).isEmpty { return Self.tokens(reference).isEmpty }
        return drift(candidate: candidate, reference: reference) <= maxDrift
    }

    private static func editDistance(_ a: [String], _ b: [String]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var previous = Array(0 ... b.count)
        var row = previous
        for i in 1 ... a.count {
            row[0] = i
            for j in 1 ... b.count {
                let substitution = previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1)
                row[j] = min(substitution, previous[j] + 1, row[j - 1] + 1)
            }
            swap(&previous, &row)
        }
        return previous[b.count]
    }
}
