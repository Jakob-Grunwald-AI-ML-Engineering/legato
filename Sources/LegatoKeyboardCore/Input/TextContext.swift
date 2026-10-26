import Foundation

/// What the keyboard knows about the text before the cursor (`documentContextBeforeInput`).
public struct TextContext: Sendable, Equatable {
    public let before: String

    public init(documentContextBeforeInput: String?) {
        before = documentContextBeforeInput ?? ""
    }

    public var lastCharacter: Character? { before.last }

    /// The word being typed: the trailing run of letters, digits and apostrophes.
    public var wordPrefix: String {
        String(before.reversed().prefix { $0.isLetter || $0.isNumber || $0 == "'" || $0 == "’" }.reversed())
    }

    /// True at the document start, after a newline, and after `. `, `! ` or `? `.
    public var isSentenceStart: Bool {
        var rest = Substring(before)
        var removed = 0
        while let last = rest.last, last == " " || last == "\t" {
            rest = rest.dropLast()
            removed += 1
        }
        guard let last = rest.last else { return true }
        if last.isNewline { return true }
        return removed > 0 && (last == "." || last == "!" || last == "?")
    }
}
