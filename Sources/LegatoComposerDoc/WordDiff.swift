import Foundation

/// Preserves complete surviving word records without allocating a quadratic-size LCS table.
enum WordDiff {
    static func reconcile(old: [Word], proposed: [Word], origin: TransactionOrigin) -> [Word] {
        if origin == .undo || origin == .asr { return proposed }
        var result = proposed.map { Word(text: $0.text, language: $0.language, pinned: origin == .user && $0.pinned) }
        func preserve(_ i: Int, _ j: Int) { result[j] = old[i] }
        match(old, proposed, oldRange: old.indices, newRange: proposed.indices, preserve: preserve)
        return result
    }

    /// Hirschberg's exact LCS uses two rows, rather than old.count * proposed.count Ints.
    /// A common prefix makes the usual small edit/append linear, even in a very long paragraph.
    private static func match(_ old: [Word], _ new: [Word], oldRange: Range<Int>, newRange: Range<Int>, preserve: (Int, Int) -> Void) {
        var a = oldRange, b = newRange
        while let i = a.first, let j = b.first, old[i].text == new[j].text {
            preserve(i, j); a = (i + 1)..<a.upperBound; b = (j + 1)..<b.upperBound
        }
        guard !a.isEmpty, !b.isEmpty else { return }
        if a.count <= 64, b.count <= 64 {
            matchSmall(old, new, a: a, b: b, preserve: preserve)
            return
        }
        if a.count == 1 {
            if let j = b.first(where: { new[$0].text == old[a.lowerBound].text }) { preserve(a.lowerBound, j) }
            return
        }
        if b.count == 1 {
            if let i = a.first(where: { old[$0].text == new[b.lowerBound].text }) { preserve(i, b.lowerBound) }
            return
        }
        // A complete rewrite with no surviving vocabulary needs no LCS work at all.
        let vocabulary = Set(a.map { old[$0].text })
        guard b.contains(where: { vocabulary.contains(new[$0].text) }) else { return }
        let middle = a.lowerBound + a.count / 2
        // Keep the row buffers in this scope so they are released before recursion.
        let split: Int = {
            let left = row(old, new, a: a.lowerBound..<middle, b: b, backwards: false)
            let right = row(old, new, a: middle..<a.upperBound, b: b, backwards: true)
            var best = -1, offset = 0
            for j in 0...b.count {
                let score = left[j] + right[b.count - j]
                if score > best { best = score; offset = j }
            }
            return b.lowerBound + offset
        }()
        match(old, new, oldRange: a.lowerBound..<middle, newRange: b.lowerBound..<split, preserve: preserve)
        match(old, new, oldRange: middle..<a.upperBound, newRange: split..<b.upperBound, preserve: preserve)
    }

    /// Preserve the original tie-breaking for ordinary edits, with a strict 65 * 65 cell cap.
    private static func matchSmall(_ old: [Word], _ new: [Word], a: Range<Int>, b: Range<Int>, preserve: (Int, Int) -> Void) {
        var lengths = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in stride(from: a.count - 1, through: 0, by: -1) {
            for j in stride(from: b.count - 1, through: 0, by: -1) {
                lengths[i][j] = old[a.lowerBound + i].text == new[b.lowerBound + j].text
                    ? 1 + lengths[i + 1][j + 1] : max(lengths[i + 1][j], lengths[i][j + 1])
            }
        }
        var i = 0, j = 0
        while i < a.count, j < b.count {
            if old[a.lowerBound + i].text == new[b.lowerBound + j].text {
                preserve(a.lowerBound + i, b.lowerBound + j); i += 1; j += 1
            } else if lengths[i + 1][j] >= lengths[i][j + 1] { i += 1 }
            else { j += 1 }
        }
    }

    private static func row(_ old: [Word], _ new: [Word], a: Range<Int>, b: Range<Int>, backwards: Bool) -> [Int] {
        var lengths = Array(repeating: 0, count: b.count + 1)
        for offset in 0..<a.count {
            let i = backwards ? a.upperBound - 1 - offset : a.lowerBound + offset
            var diagonal = 0
            for column in 1...b.count {
                let j = backwards ? b.upperBound - column : b.lowerBound + column - 1
                let previous = lengths[column]
                lengths[column] = old[i].text == new[j].text ? diagonal + 1 : max(previous, lengths[column - 1])
                diagonal = previous
            }
        }
        return lengths
    }

    static func words(_ text: String) -> [Word] { text.split(whereSeparator: \.isWhitespace).map { Word(text: String($0)) } }
}
