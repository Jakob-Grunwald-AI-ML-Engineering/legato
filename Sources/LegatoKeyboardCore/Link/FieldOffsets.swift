import Foundation
import LegatoFieldEdit

/// Character <-> UTF-16 conversion at the link boundary. `HostRevision` and the app's text count Characters;
/// the field edit queue counts UTF-16 units (``Span``). A position inside a Character (a surrogate pair, a ZWJ
/// sequence, a flag, a combining mark) has no Character offset and converts to nil: callers must handle nil
/// (drop or re-plan the edit); never round to a neighbour.
public enum FieldOffsets {
    /// The UTF-16 offset where Character number `offset` starts (`text.count` gives the length), or nil outside.
    public static func utf16Offset(ofCharacter offset: Int, in text: String) -> Int? {
        guard offset >= 0 else { return nil }
        var units = 0
        var index = 0
        for character in text {
            if index == offset { return units }
            units += character.utf16.count
            index += 1
        }
        return index == offset ? units : nil
    }

    /// The Character offset of UTF-16 offset `offset`, or nil when it is outside the text or inside a Character.
    public static func characterOffset(ofUTF16 offset: Int, in text: String) -> Int? {
        guard offset >= 0 else { return nil }
        var units = 0
        var index = 0
        for character in text {
            if units == offset { return index }
            if units > offset { return nil }
            units += character.utf16.count
            index += 1
        }
        return units == offset ? index : nil
    }

    /// The span a Character range covers.
    public static func span(ofCharacters range: Range<Int>, in text: String) -> Span? {
        guard let start = utf16Offset(ofCharacter: range.lowerBound, in: text),
            let end = utf16Offset(ofCharacter: range.upperBound, in: text)
        else { return nil }
        return Span(location: start, length: end - start)
    }

    /// The Character range a span covers, nil when either edge is not on a Character boundary.
    public static func characters(ofSpan span: Span, in text: String) -> Range<Int>? {
        guard span.length >= 0, let start = characterOffset(ofUTF16: span.location, in: text),
            let end = characterOffset(ofUTF16: span.end, in: text)
        else { return nil }
        return start..<end
    }
}
