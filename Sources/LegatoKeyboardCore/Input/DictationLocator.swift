import Foundation

/// Finds, among the versions of the last dictation, the one the field still holds around a tapped word, and
/// where the word sits in it. The keyboard only sees the text near the cursor, so the match is made on the
/// word with the characters around it, trying wide neighbourhoods first: a sentence edited elsewhere still
/// matches by its closer neighbours, and a word that only occurs outside the dictation matches nothing.
public enum DictationLocator {
    public struct Location: Sendable, Equatable {
        /// The index in `texts` of the version the field holds.
        public var version: Int
        /// The tapped word's offset in that version, in Characters.
        public var start: Int
        public var length: Int
    }

    /// Characters taken on each side of the word, widest first.
    static let radii = [40, 16, 6]

    /// - Parameter preferred: the version known to be in the field (wins a tie between equal versions).
    public static func locate(
        texts: [String], contextBefore: String, contextAfter: String, word: WordAtCursor, preferred: Int? = nil
    ) -> Location? {
        let before = Array(contextBefore)
        let after = Array(contextAfter)
        let length = word.charsBefore + word.charsAfter
        let wordStart = before.count - word.charsBefore
        guard wordStart >= 0, wordStart + length <= before.count + after.count else { return nil }
        let combined = before + after
        let chars = texts.map { Array($0) }
        var order = Array(texts.indices)
        if let preferred, let at = order.firstIndex(of: preferred) { order.remove(at: at); order.insert(preferred, at: 0) }
        for radius in radii {
            let lead = min(radius, wordStart)
            let tail = min(radius, combined.count - (wordStart + length))
            let pattern = Array(combined[(wordStart - lead)..<(wordStart + length + tail)])
            for version in order {
                if let at = find(pattern, in: chars[version]) {
                    return Location(version: version, start: at + lead, length: length)
                }
            }
        }
        return nil
    }

    private static func find(_ pattern: [Character], in text: [Character]) -> Int? {
        guard !pattern.isEmpty, pattern.count <= text.count else { return nil }
        for i in 0...(text.count - pattern.count) where text[i] == pattern[0] {
            if text[i..<(i + pattern.count)].elementsEqual(pattern) { return i }
        }
        return nil
    }
}
