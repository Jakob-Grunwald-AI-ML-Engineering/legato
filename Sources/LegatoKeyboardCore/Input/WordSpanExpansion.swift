import Foundation

/// Widens the span of a tapped word by whole neighbouring words, for an alternative that replaces more than
/// the tapped word ("kuber netties" becomes "Kubernetes"). Words are joined by spaces or tabs only: a
/// comma, a full stop or a line break between two words ends the expansion there.
public enum WordSpanExpansion {
    private static func isWordCharacter(_ c: Character) -> Bool { c.isLetter || c.isNumber || c == "'" || c == "’" }
    private static func isBlank(_ c: Character) -> Bool { c == " " || c == "\t" }

    /// The span of `tapped` plus up to `left` words before it and `right` words after it.
    public static func span(
        contextBefore: String, contextAfter: String, tapped: WordAtCursor, left: Int, right: Int
    ) -> WordSpan {
        let before = Array(contextBefore)
        let after = Array(contextAfter)
        var start = before.count - tapped.charsBefore
        var end = tapped.charsAfter
        for _ in 0..<max(0, left) {
            var gap = start
            while gap > 0, isBlank(before[gap - 1]) { gap -= 1 }
            guard gap < start, gap > 0 else { break }
            var word = gap
            while word > 0, isWordCharacter(before[word - 1]) { word -= 1 }
            guard word < gap else { break }
            start = word
        }
        for _ in 0..<max(0, right) {
            var gap = end
            while gap < after.count, isBlank(after[gap]) { gap += 1 }
            guard gap > end, gap < after.count else { break }
            var word = gap
            while word < after.count, isWordCharacter(after[word]) { word += 1 }
            guard word > gap else { break }
            end = word
        }
        return WordSpan(before: before.count - start, after: end)
    }
}
