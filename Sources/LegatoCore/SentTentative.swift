import Foundation

/// Where tentative text that went with a sent message ends in the committed text that later finalizes it.
///
/// A Live run's field can be cleared (a chat app's Send) while it shows tentative text after the committed
/// text. That text was sent, but the engine commits it only later, and maybe changed ("how are" becomes
/// "How are you?"). The part of the later committed text that stands for it must not be typed or cleaned
/// again; only what follows it may be.
///
/// The rule works on words (letters and digits, case ignored; punctuation and whitespace don't count):
/// - The sent words are looked for at the start of the committed text, or one or two words later (the
///   engine put words in front). The last sent word may be the start of a longer committed word (the
///   tentative text stopped mid-word).
/// - Otherwise as many committed words as were sent count as sent (a word changed).
/// - The part covered runs to the end of its last word and the whitespace after it.
/// - A committed word counts only once whitespace follows it, or once the text is `complete` (the run's
///   final text). Until enough words count to decide, there is no answer (nil): nothing after the boundary
///   may be typed yet. An answer, once given, stays the same as more text is committed.
///
/// So a mismatch errs on leaving words out of the field (they are in the history's raw text), never on
/// typing the sent phrase again. This is a copy of LegatoKeyboardCore's `SentTentative` (the two packages
/// don't depend on each other): the keyboard and `DictationSession` must put the boundary at the same place,
/// so the two stay identical.
enum SentTentative {
    /// How many more words than were sent may come before them.
    static let slack = 2

    /// The number of characters at the start of `text` (committed text after the boundary) that stand for the
    /// sent `tentative` text; nil while that can't be told yet.
    static func coveredCount(of tentative: String, in text: String, complete: Bool) -> Int? {
        let sent = words(of: tentative).map(\.key)
        guard !sent.isEmpty else { return 0 }
        let found = words(of: text)
        let closed = complete ? found.count : found.filter(\.closed).count
        let k = sent.count

        func matches(at j: Int) -> Bool {
            for i in 0..<k {
                let word = found[j + i].key
                if i == k - 1 ? !word.hasPrefix(sent[i]) : word != sent[i] { return false }
            }
            return true
        }

        for j in 0...slack {
            guard j + k <= closed else {
                if complete { break }
                return nil
            }
            if matches(at: j) { return found[j + k - 1].through }
        }
        let n = min(k, closed)
        return n == 0 ? 0 : found[n - 1].through
    }

    private struct Word {
        /// Lowercased letters and digits.
        var key: String
        /// Characters from the start of the text to past the word and the whitespace after it.
        var through: Int
        /// Whitespace follows it.
        var closed: Bool
    }

    private static func words(of text: String) -> [Word] {
        var result: [Word] = []
        var key = ""
        var inWord = false
        var offset = 0
        for c in text {
            if c.isWhitespace {
                if inWord {
                    if !key.isEmpty { result.append(Word(key: key, through: offset, closed: true)) }
                    key = ""
                    inWord = false
                }
                if let last = result.indices.last, result[last].through == offset { result[last].through = offset + 1 }
            } else {
                inWord = true
                if c.isLetter || c.isNumber { key += c.lowercased() }
            }
            offset += 1
        }
        if inWord, !key.isEmpty { result.append(Word(key: key, through: offset, closed: false)) }
        return result
    }
}
