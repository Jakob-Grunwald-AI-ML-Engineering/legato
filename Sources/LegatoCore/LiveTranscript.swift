import Foundation

public enum LiveTranscript {
    private static let ellipsis = "…"
    public static func tail(of text: String, maxCharacters: Int = 120, maxBytes: Int = 1024) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count <= maxCharacters && trimmed.utf8.count <= maxBytes { return trimmed }

        let chars = Array(trimmed)
        let charBudget = max(maxCharacters - ellipsis.count, 0)
        var byteBudget = max(maxBytes - ellipsis.utf8.count, 0)
        var start = chars.endIndex
        while start > chars.startIndex, chars.endIndex - start < charBudget {
            let bytes = String(chars[start - 1]).utf8.count
            guard bytes <= byteBudget else { break }
            byteBudget -= bytes
            start -= 1
        }
        // Landed inside a word: drop its fragment, unless the slice is that one word.
        if start > chars.startIndex, start < chars.endIndex,
           !chars[start - 1].isWhitespace, !chars[start].isWhitespace,
           let gap = chars[start...].firstIndex(where: \.isWhitespace) {
            start = gap
        }
        while start < chars.endIndex, chars[start].isWhitespace { start += 1 }
        return ellipsis + String(chars[start...])
    }

}
