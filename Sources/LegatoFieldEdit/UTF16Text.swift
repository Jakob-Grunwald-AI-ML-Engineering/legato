import Foundation

/// Byte equality, never Unicode canonical equivalence: a field that holds a decomposed é still holds it.
func byteEqual(_ a: some StringProtocol, _ b: some StringProtocol) -> Bool { a.utf8.elementsEqual(b.utf8) }

func byteEqual(_ a: Character, _ b: Character) -> Bool { a.utf8.elementsEqual(b.utf8) }

extension String {
    /// The UTF-16 units of `span`, or nil when it reaches outside the text.
    func units(in span: Span) -> ArraySlice<UInt16>? {
        let units = Array(utf16)
        guard span.location >= 0, span.length >= 0, span.end <= units.count else { return nil }
        return units[span.location..<span.end]
    }

    /// The text with `span` replaced by `text`; the caller has checked the span is in range.
    func replacing(_ span: Span, with text: String) -> String {
        var units = Array(utf16)
        units.replaceSubrange(span.location..<span.end, with: text.utf16)
        return String(decoding: units, as: UTF16.self)
    }
}
