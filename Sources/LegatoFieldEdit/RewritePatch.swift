import Foundation

/// The smallest word-level patches that turn a recognized text into its rewrite (the cleanup agent's reply):
/// the longest common subsequence of whitespace-separated words, compared exactly (punctuation included). Each
/// change becomes one step over the region between the unchanged words around it, narrowed to the characters
/// that differ, so words the model left alone are never written again.
public enum RewritePatch {
    /// One change: the UTF-16 region of the old text and the region of the new text that replaces it. Regions run
    /// from the end of the unchanged word before the change (or the text's start) to the start of the unchanged
    /// word after it (or the text's end), so they include the spacing in between.
    public struct Hunk: Sendable, Hashable {
        public var old: Range<Int>
        public var new: Range<Int>
        /// Old words replaced and new words inserted (indices into the word lists).
        public var oldWords: Range<Int>
        public var newWords: Range<Int>
        /// Where the change starts in the old text: its first replaced word, or the insertion point.
        public var anchor: Int
    }

    /// The steps turning `old` into `new`, where `old` starts at UTF-16 offset `location` of the field. Sorted by
    /// location, non-overlapping, all against the same base. Empty when the two differ only in spacing.
    public static func steps(_ old: String, _ new: String, at location: Int) -> [EditStep] {
        let oldUnits = Array(old.utf16), newUnits = Array(new.utf16)
        return hunks(old, new).compactMap { hunk in
            let removed = String(decoding: oldUnits[hunk.old], as: UTF16.self)
            let inserted = String(decoding: newUnits[hunk.new], as: UTF16.self)
            return ContiguousPatch.between(removed, inserted, at: location + hunk.old.lowerBound)
        }
    }

    /// The changes from `old` to `new`, in order.
    public static func hunks(_ old: String, _ new: String) -> [Hunk] {
        let a = words(old), b = words(new)
        let oldLength = old.utf16.count, newLength = new.utf16.count
        let n = a.count, m = b.count
        // lcs[i][j]: the longest common subsequence of a[i...] and b[j...].
        var lcs = Array(repeating: Array(repeating: Int32(0), count: m + 1), count: n + 1)
        if n > 0, m > 0 {
            for i in stride(from: n - 1, through: 0, by: -1) {
                for j in stride(from: m - 1, through: 0, by: -1) {
                    lcs[i][j] = a[i].text == b[j].text ? lcs[i + 1][j + 1] + 1 : max(lcs[i + 1][j], lcs[i][j + 1])
                }
            }
        }
        var hunks: [Hunk] = []
        var i = 0, j = 0
        var open: (i: Int, j: Int)?
        func close() {
            guard let start = open else { return }
            open = nil
            let oldStart = start.i == 0 ? 0 : a[start.i - 1].range.upperBound
            let oldEnd = i == n ? oldLength : a[i].range.lowerBound
            let newStart = start.j == 0 ? 0 : b[start.j - 1].range.upperBound
            let newEnd = j == m ? newLength : b[j].range.lowerBound
            let anchor = start.i < i ? a[start.i].range.lowerBound : oldStart
            hunks.append(Hunk(
                old: oldStart..<oldEnd, new: newStart..<newEnd, oldWords: start.i..<i, newWords: start.j..<j, anchor: anchor))
        }
        while i < n || j < m {
            if i < n, j < m, a[i].text == b[j].text {
                close()
                i += 1
                j += 1
            } else if j < m, i == n || lcs[i][j + 1] >= lcs[i + 1][j] {
                if open == nil { open = (i, j) }
                j += 1
            } else {
                if open == nil { open = (i, j) }
                i += 1
            }
        }
        close()
        return hunks
    }

    struct Word {
        var text: Substring
        var range: Range<Int>
    }

    /// The whitespace-separated words of `text` with their UTF-16 ranges.
    static func words(_ text: String) -> [Word] {
        var out: [Word] = []
        var offset = 0
        var start: (index: String.Index, offset: Int)?
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            let next = text.index(after: index)
            if character.isWhitespace {
                if let begin = start {
                    out.append(Word(text: text[begin.index..<index], range: begin.offset..<offset))
                    start = nil
                }
            } else if start == nil {
                start = (index, offset)
            }
            offset += character.utf16.count
            index = next
        }
        if let begin = start { out.append(Word(text: text[begin.index...], range: begin.offset..<offset)) }
        return out
    }
}
