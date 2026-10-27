import Foundation

/// A word-level alignment of two versions of a text, used to find what a cleanup step changed.
public enum WordAlignment {
    /// The most words a substitution block may have on either side.
    public static let maxBlockWords = 3

    /// A run of words that was replaced by another run: n words became m words.
    public struct Block: Sendable, Equatable {
        /// The replaced words as written in the original (edge punctuation trimmed).
        public var raw: [String]
        /// The replacement words as written in the new text.
        public var target: [String]

        public init(raw: [String], target: [String]) {
            self.raw = raw
            self.target = target
        }

        public var rawText: String { raw.joined(separator: " ") }
        public var targetText: String { target.joined(separator: " ") }
    }

    /// The substitution blocks between `raw` and `cleaned`.
    ///
    /// Both texts are split into words and compared by a longest common subsequence over case- and
    /// punctuation-folded words. Each stretch between two shared words where both sides have words becomes a
    /// block, unless either side has more than ``maxBlockWords`` words. Pure insertions and deletions are not
    /// substitutions and yield nothing. The words keep their written case; only edge punctuation is trimmed.
    public static func substitutions(from raw: String, to cleaned: String) -> [Block] {
        let a = tokens(raw)
        let b = tokens(cleaned)
        guard !a.isEmpty, !b.isEmpty else { return [] }
        let pairs = commonPairs(a.map(\.folded), b.map(\.folded))
        var blocks: [Block] = []
        var ai = 0
        var bi = 0
        for (i, j) in pairs + [(a.count, b.count)] {
            let rawGap = a[ai..<i]
            let targetGap = b[bi..<j]
            if !rawGap.isEmpty, !targetGap.isEmpty, rawGap.count <= maxBlockWords, targetGap.count <= maxBlockWords {
                blocks.append(Block(raw: rawGap.map(\.surface), target: targetGap.map(\.surface)))
            }
            ai = i + 1
            bi = j + 1
        }
        return blocks
    }

    private struct Token {
        var surface: String
        var folded: String
    }

    private static func tokens(_ text: String) -> [Token] {
        text.split(whereSeparator: \.isWhitespace).compactMap { piece in
            var chars = Substring(piece)
            while let f = chars.first, !(f.isLetter || f.isNumber) { chars.removeFirst() }
            while let l = chars.last, !(l.isLetter || l.isNumber) { chars.removeLast() }
            let folded = String(chars.lowercased().filter { $0.isLetter || $0.isNumber })
            return folded.isEmpty ? nil : Token(surface: String(chars), folded: folded)
        }
    }

    /// The index pairs of one longest common subsequence, ascending.
    private static func commonPairs(_ a: [String], _ b: [String]) -> [(Int, Int)] {
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
}
