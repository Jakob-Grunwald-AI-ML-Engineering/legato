import Foundation

/// The text the user types with the keyboard's keys, collected until a sentence ends, so that the word-pair
/// model can learn from it (``typed(_:)`` returns the finished text). Dictation, pasted text and the host's
/// own edits never enter: they call ``interrupted()``, which hands over what was typed so far and starts over.
public struct TypedSentenceBuffer: Sendable, Equatable {
    /// A run this long is handed over even without an end.
    public static let maxLength = 400
    private static let enders: Set<Character> = [".", "!", "?", "\n"]

    private var text = ""

    public init() {}

    /// A key's text. Returns the finished sentence when this key ended it (or the buffer is full).
    public mutating func typed(_ key: String) -> String? {
        text += key
        if key.contains(where: { Self.enders.contains($0) }) || text.count >= Self.maxLength { return take() }
        return nil
    }

    /// A backspace.
    public mutating func deleted() {
        if !text.isEmpty { text.removeLast() }
    }

    /// A completion replaced the last `count` characters with `text`: the buffer follows, nothing is handed over.
    /// (Returns the finished sentence when `text` ended one.)
    public mutating func completed(deleting count: Int, with text: String) -> String? {
        for _ in 0..<max(0, count) { deleted() }
        return typed(text)
    }

    /// The typed text is being undone: it is dropped, not learned.
    public mutating func discard() { text = "" }

    /// The cursor moved, the field changed or something else edited the text: what was typed so far.
    public mutating func interrupted() -> String? { take() }

    /// Hands over the text when it has at least two words.
    private mutating func take() -> String? {
        let out = text.trimmingCharacters(in: .whitespacesAndNewlines)
        text = ""
        return out.split(whereSeparator: \.isWhitespace).count >= 2 ? out : nil
    }
}
