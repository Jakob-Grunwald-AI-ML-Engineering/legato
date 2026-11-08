import Foundation

/// A deterministic guard for cleaned live sentences: the model sometimes leaves a sentence start lowercase although
/// the text before it ends a sentence. Such a start gets its capital; names and handles that are meant lowercase stay.
public enum SentenceStart {
    private static let closers: Set<Character> = ["\"", "'", ")", "]", "}", "\u{201D}", "\u{2019}", "\u{00BB}"]

    /// Whether `context` (the text before a sentence) is empty or ends a sentence: `.`, `!`, `?` or `…`, optionally
    /// followed by closing quotes or brackets, and trailing whitespace. A line break also ends one.
    public static func endsSentence(_ context: String) -> Bool {
        let trimmed = context.trimmingCharacters(in: .whitespaces)
        guard let last = trimmed.last else { return true }
        if last.isNewline { return true }
        let core = trimmed.reversed().drop(while: { closers.contains($0) })
        guard let mark = core.first else { return false }
        return ".!?…".contains(mark)
    }

    /// `sentence` with its first letter in capitals when it starts lowercase after a sentence end. Left alone: a first word
    /// with a capital further in (iPhone, eBay), or one that looks like a URL, an address, a handle or a hashtag.
    public static func capitalized(_ sentence: String, after context: String) -> String {
        guard endsSentence(context), let first = sentence.first, first.isLowercase else { return sentence }
        let word = sentence.prefix { !$0.isWhitespace }
        if word.dropFirst().contains(where: \.isUppercase) { return sentence }
        if word.contains(where: { "@/:#".contains($0) }) || word.lowercased().hasPrefix("www.") { return sentence }
        return first.uppercased() + sentence.dropFirst()
    }
}
