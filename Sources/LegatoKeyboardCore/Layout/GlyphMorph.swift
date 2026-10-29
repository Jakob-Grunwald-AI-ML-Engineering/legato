import Foundation

/// The per-character diff behind the word row's text animation: a slot's text as glyphs with stable ids, and what
/// changed since the previous text. Characters the old and new text share (a longest common subsequence) keep their
/// ids, so the view slides them to their new places; the rest are removed (fading out right to left) or inserted
/// (growing and fading in left to right). Chain it: each update takes the previous morph, so ids persist across rapid changes. A glyph is a
/// grapheme cluster (an emoji sequence, a decomposed umlaut), and ids are never reused.
public struct GlyphMorph: Equatable, Sendable {
    public struct Glyph: Identifiable, Equatable, Sendable {
        public let id: Int
        public let character: Character
        public init(id: Int, character: Character) { self.id = id; self.character = character }
    }

    /// A glyph of the previous text that is gone from the new one.
    public struct Removal: Equatable, Sendable {
        public let glyph: Glyph
        /// 0 for the rightmost removed glyph, counting up leftwards: the order the removals fade in.
        public let stagger: Int
    }

    /// The new text, in order: kept glyphs (with their old ids) and inserted ones (with fresh ids).
    public let glyphs: [Glyph]
    /// The inserted glyphs' ids, each with its stagger: 0 for the leftmost inserted glyph, counting up rightwards.
    public let insertionStagger: [Int: Int]
    /// The removed glyphs, rightmost first (stagger 0, 1, 2 ...).
    public let removals: [Removal]
    /// The id the next inserted glyph takes.
    public let nextID: Int

    /// A morph at rest: `text` as glyphs with consecutive ids from `firstID`, nothing changing.
    public init(text: String, firstID: Int = 0) {
        var id = firstID
        glyphs = text.map { character in
            defer { id += 1 }
            return Glyph(id: id, character: character)
        }
        insertionStagger = [:]
        removals = []
        nextID = id
    }

    private init(glyphs: [Glyph], insertionStagger: [Int: Int], removals: [Removal], nextID: Int) {
        self.glyphs = glyphs
        self.insertionStagger = insertionStagger
        self.removals = removals
        self.nextID = nextID
    }

    public var text: String { String(glyphs.map(\.character)) }

    /// The morph from this text to `text`.
    public func morphing(to text: String) -> GlyphMorph {
        let old = glyphs
        let new = Array(text)
        // lcs[i][j]: the longest common subsequence of old[i...] and new[j...].
        var lcs = Array(repeating: Array(repeating: 0, count: new.count + 1), count: old.count + 1)
        for i in stride(from: old.count - 1, through: 0, by: -1) {
            for j in stride(from: new.count - 1, through: 0, by: -1) {
                lcs[i][j] = old[i].character == new[j] ? lcs[i + 1][j + 1] + 1 : max(lcs[i + 1][j], lcs[i][j + 1])
            }
        }
        var result: [Glyph] = []
        var removed: [Glyph] = []
        var inserted: [Int] = []
        var id = nextID
        var i = 0, j = 0
        while i < old.count || j < new.count {
            if i < old.count, j < new.count, old[i].character == new[j], lcs[i][j] == lcs[i + 1][j + 1] + 1 {
                result.append(old[i])
                i += 1
                j += 1
            } else if i < old.count, j == new.count || lcs[i + 1][j] >= lcs[i][j + 1] {
                removed.append(old[i])
                i += 1
            } else {
                result.append(Glyph(id: id, character: new[j]))
                inserted.append(id)
                id += 1
                j += 1
            }
        }
        var staggers: [Int: Int] = [:]
        for (stagger, glyphID) in inserted.enumerated() { staggers[glyphID] = stagger }
        let removals = removed.reversed().enumerated().map { Removal(glyph: $1, stagger: $0) }
        return GlyphMorph(glyphs: result, insertionStagger: staggers, removals: removals, nextID: id)
    }
}
