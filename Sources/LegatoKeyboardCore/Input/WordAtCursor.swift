import Foundation

/// A stretch of text around the cursor, as characters before and after it. Units are Characters
/// (grapheme clusters), the way `deleteBackward` counts; moving the cursor over it takes UTF-16 units
/// (``WordEdit/utf16Forward(contextAfter:)``).
public struct WordSpan: Sendable, Equatable {
    public var before: Int
    public var after: Int

    public init(before: Int, after: Int) {
        self.before = before
        self.after = after
    }
}

/// The word touching the cursor, found from the text before and after it.
public struct WordAtCursor: Sendable, Equatable {
    public let word: String
    /// Characters of the word before the cursor.
    public let charsBefore: Int
    /// Characters of the word after the cursor.
    public let charsAfter: Int

    public var span: WordSpan { WordSpan(before: charsBefore, after: charsAfter) }

    private static func isWordCharacter(_ c: Character) -> Bool { c.isLetter || c.isNumber || isApostrophe(c) }
    private static func isApostrophe(_ c: Character) -> Bool { c == "'" || c == "’" }

    /// The word the cursor is in or touches: letters, digits and apostrophes, where apostrophes at either
    /// end (quoting) are not part of the word. Nil inside whitespace or punctuation, or with a selection.
    public static func find(contextBefore: String, contextAfter: String, hasSelection: Bool = false) -> WordAtCursor? {
        guard !hasSelection else { return nil }
        let head = Array(contextBefore.reversed().prefix(while: isWordCharacter).reversed())
        let tail = Array(contextAfter.prefix(while: isWordCharacter))
        let all = head + tail
        let lead = all.prefix(while: isApostrophe).count
        let trail = all.count > lead ? all.reversed().prefix(while: isApostrophe).count : 0
        // The cursor must sit on the trimmed word, not out among the quoting apostrophes.
        guard lead <= head.count, trail <= tail.count else { return nil }
        let word = all.dropFirst(lead).dropLast(trail)
        guard !word.isEmpty else { return nil }
        return WordAtCursor(word: String(word), charsBefore: head.count - lead, charsAfter: tail.count - trail)
    }
}
