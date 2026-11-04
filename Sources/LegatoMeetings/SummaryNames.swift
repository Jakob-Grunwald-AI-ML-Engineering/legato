import Foundation

/// A summary names its speakers in words ("Speaker 1 agreed…"), so renaming a speaker changes the words of the
/// summary written before it.
public enum SummaryNames {
    /// `text` with `old` written as `new` wherever `old` stands as a whole name: "Speaker 1" is not part of
    /// "Speaker 10", "Ann" not of "Anna". Nothing changes for an empty or equal name.
    public static func replacing(_ old: String, with new: String, in text: String) -> String {
        let name = old.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != new else { return text }
        let pattern = "(?<![\\p{L}\\p{N}])" + NSRegularExpression.escapedPattern(for: name) + "(?![\\p{L}\\p{N}])"
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return text }
        let range = NSRange(text.startIndex..., in: text)
        return expression.stringByReplacingMatches(in: text, range: range, withTemplate: NSRegularExpression.escapedTemplate(for: new))
    }
}
