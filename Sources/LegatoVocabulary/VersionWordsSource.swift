import Foundation

/// What the other versions of the last dictation said where the user tapped a word.
///
/// `texts` are the versions of one dictation, the dictated one first (raw, then cleaned, then refined);
/// `shown` is the index of the version the tapped word sits in and `wordIndex` its token index there (see
/// ``tokens(in:)`` and ``tokenIndex(of:in:)``). Around the tap a window of ``windowSize`` tokens is aligned
/// against the matching window of each other version, so the cost does not grow with the text. A word the
/// versions share has no alternative; a stretch that was replaced (up to ``WordAlignment/maxBlockWords``
/// words on each side) is offered from every other version as an engine alternative, the earlier version
/// scoring higher.
public struct VersionWordsSource: AlternativeSource {
    /// The most tokens of the tapped version that are aligned.
    public static let windowSize = 40

    private let texts: [String]
    private let shown: Int
    private let wordIndex: Int

    public init(texts: [String], shown: Int, wordIndex: Int) {
        self.texts = texts
        self.shown = shown
        self.wordIndex = wordIndex
    }

    public func candidates(for word: String, context: AlternativeContext) async -> [ScoredCandidate] {
        guard texts.indices.contains(shown), texts.count > 1 else { return [] }
        let tapped = Self.tokenize(texts[shown])
        guard tapped.indices.contains(wordIndex) else { return [] }
        var out: [ScoredCandidate] = []
        var rank = 0
        for (i, text) in texts.enumerated() where i != shown {
            let words = Self.align(tapped: tapped, index: wordIndex, other: Self.tokenize(text)).words
            if !words.isEmpty {
                out.append(ScoredCandidate(text: words.joined(separator: " "), score: max(0.5, 0.9 - 0.1 * Double(rank)), source: .engine))
            }
            rank += 1
        }
        return out
    }

    // MARK: windows and alignment

    /// The window of at most `size` tokens around `index` in a text of `count` tokens, shifted to stay inside it.
    static func window(around index: Int, count: Int, size: Int = windowSize) -> Range<Int> {
        guard count > 0 else { return 0..<0 }
        let length = min(size, count)
        let start = min(max(0, index - length / 2), count - length)
        return start..<(start + length)
    }

    /// The words of `other` that replace the tapped token, and how many table cells the alignment used.
    static func align(tapped: [Token], index: Int, other: [Token]) -> (words: [String], cells: Int) {
        guard tapped.indices.contains(index), !other.isEmpty else { return ([], 0) }
        let a = window(around: index, count: tapped.count)
        let b = otherWindow(for: tapped, index: index, window: a, other: other)
        let aw = tapped[a].map(\.folded)
        let bw = other[b].map(\.folded)
        let local = index - a.lowerBound
        let cells = aw.count * bw.count
        var ai = 0
        var bi = 0
        for (i, j) in lcs(aw, bw) + [(aw.count, bw.count)] {
            if ai <= local, local < i {
                let target = other[b][(b.lowerBound + bi)..<(b.lowerBound + j)]
                let gap = i - ai
                if !target.isEmpty, target.count <= WordAlignment.maxBlockWords, gap <= WordAlignment.maxBlockWords {
                    return (target.map(\.surface), cells)
                }
                return ([], cells)
            }
            if i == local { return ([], cells) }
            ai = i + 1
            bi = j + 1
        }
        return ([], cells)
    }

    /// The part of `other` that lines up with the tapped window: all of it when short, otherwise a window of
    /// twice ``windowSize`` around the spot that shares most words with the tapped window, searched near the
    /// proportional position (insertions and deletions shift positions, so the position alone is not enough).
    private static func otherWindow(for tapped: [Token], index: Int, window: Range<Int>, other: [Token]) -> Range<Int> {
        let size = windowSize * 2
        if other.count <= size { return 0..<other.count }
        let wanted = Set(tapped[window].enumerated().filter { window.lowerBound + $0.offset != index }.map(\.element.folded))
        let estimate = index * other.count / max(1, tapped.count)
        let reach = max(windowSize, other.count * 15 / 100)
        var best = estimate
        var bestScore = -1
        for center in max(0, estimate - reach)...min(other.count - 1, estimate + reach) {
            let span = Self.window(around: center, count: other.count, size: windowSize)
            let score = other[span].reduce(0) { $0 + (wanted.contains($1.folded) ? 1 : 0) }
            if score > bestScore || (score == bestScore && abs(center - estimate) < abs(best - estimate)) {
                best = center
                bestScore = score
            }
        }
        return Self.window(around: best, count: other.count, size: size)
    }

    private static func lcs(_ a: [String], _ b: [String]) -> [(Int, Int)] {
        let n = a.count
        let m = b.count
        var table = [[Int]](repeating: [Int](repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                table[i][j] = a[i] == b[j] ? table[i + 1][j + 1] + 1 : max(table[i + 1][j], table[i][j + 1])
            }
        }
        var pairs: [(Int, Int)] = []
        var i = 0
        var j = 0
        while i < n, j < m {
            if a[i] == b[j] {
                pairs.append((i, j))
                i += 1
                j += 1
            } else if table[i + 1][j] >= table[i][j + 1] {
                i += 1
            } else {
                j += 1
            }
        }
        return pairs
    }

    // MARK: tokens

    struct Token {
        /// The word without edge punctuation, as written.
        var surface: String
        /// Lowercased letters and digits only; what alignment compares.
        var folded: String
        /// The whitespace-delimited piece the word came from.
        var piece: Range<String.Index>
    }

    /// The whitespace-separated words of `text` with edge punctuation trimmed; pieces without a letter or digit are skipped.
    /// This is the indexing ``init(texts:shown:wordIndex:)`` expects.
    public static func tokens(in text: String) -> [String] { tokenize(text).map(\.surface) }

    /// The index, in ``tokens(in:)``, of the token at `range` (the first token that ends after the range starts).
    public static func tokenIndex(of range: Range<String.Index>, in text: String) -> Int? {
        tokenize(text).firstIndex { $0.piece.upperBound > range.lowerBound }
    }

    static func tokenize(_ text: String) -> [Token] {
        func isWordChar(_ c: Character) -> Bool { c.isLetter || c.isNumber }
        var out: [Token] = []
        var i = text.startIndex
        while i < text.endIndex {
            if text[i].isWhitespace { i = text.index(after: i); continue }
            var end = i
            while end < text.endIndex, !text[end].isWhitespace { end = text.index(after: end) }
            var lo = i
            var hi = end
            while lo < hi, !isWordChar(text[lo]) { lo = text.index(after: lo) }
            while lo < hi, !isWordChar(text[text.index(before: hi)]) { hi = text.index(before: hi) }
            if lo < hi {
                let surface = String(text[lo..<hi])
                out.append(Token(surface: surface, folded: String(surface.lowercased().filter(isWordChar)), piece: i..<end))
            }
            i = end
        }
        return out
    }
}
