import Foundation

/// The take's words as delivered at the caret while it runs: only new speech extends them. Each revision is aligned
/// with what was delivered word by word (the longest common subsequence, earliest where it is ambiguous): the words
/// after the last delivered word are new. A re-split of delivered words is no new speech, a filler dropped or a word
/// revised before the end still pins the end, and a last word the revision changed leaves the revision deferred.
/// Where repetitive text makes the place ambiguous the earliest one is taken, so words are left out rather than
/// typed twice (the stop's swap brings them).
public struct SpeechDelivery: Sendable, Equatable {
    /// Mac keeps a revised last word deferred; the keyboard must continue after user edits freeze its old words.
    /// Both policies use the same alignment and frontier ownership.
    private let allowsRevisedTail: Bool
    public init(allowsRevisedTail: Bool = true) { self.allowsRevisedTail = allowsRevisedTail }
    public private(set) var delivered: [Character] = []
    public private(set) var authoritative: [Character] = []
    /// Delivered words (by their index among the delivered words) heard again as others, and what they stand for now:
    /// they align as that word (`end(of:in:aliases:)`).
    public private(set) var aliases: [Int: String] = [:]
    public var hasDeferredRevision: Bool { authoritative != delivered }

    /// `complete`: the take ended, its text may be a cleanup: only new words extend the delivered text, never a
    /// cleanup's punctuation after the last delivered word.
    /// Returns where the appended text starts: in `text`, and in the delivered text.
    @discardableResult
    public mutating func update(_ text: [Character], complete: Bool = false) -> (text: Int, delivered: Int)? {
        authoritative = text
        var end: Int
        if delivered.isEmpty || text.starts(with: delivered) { end = delivered.count }
        else if let found = Self.end(of: delivered, in: text, aliases: &aliases, allowsRevisedTail: allowsRevisedTail) { end = found }
        else { return nil }
        if complete, !delivered.isEmpty {
            guard let word = text[end...].firstIndex(where: { $0.isLetter || $0.isNumber }) else { return nil }
            if word > end, text[end..<word].contains(where: \.isWhitespace) || text[end..<word].contains(where: \.isNewline) {
                delivered.append(text[end..<word].contains(where: \.isNewline) ? "\n" : " ")
            }
            end = word
        }
        let at = delivered.count
        delivered += text[end...]
        return (end, at)
    }

    /// The field shows `text` for the take (a verified revision near the caret, or words appended at once).
    public mutating func settle(_ text: [Character]) { delivered = text; authoritative = text; aliases = [:] }

    static let alignedWords = 160
    /// At most this many last delivered words may have been heard again as others (`end(of:in:)`).
    static let revisedWords = 3

    private static func words(_ text: [Character]) -> [(end: Int, word: String)] {
        var result: [(Int, String)] = [], i = 0
        while i < text.count {
            guard text[i].isLetter || text[i].isNumber else { i += 1; continue }
            let start = i
            while i < text.count, text[i].isLetter || text[i].isNumber { i += 1 }
            result.append((i, String(text[start..<i]).lowercased()))
        }
        return result
    }

    /// Where the delivered text's last word ends in `text`, or nil when that word is not there (or the words before it
    /// do not corroborate it). Last words heard again as others become `aliases`.
    static func end(of delivered: [Character], in text: [Character], aliases: inout [Int: String], allowsRevisedTail: Bool = true) -> Int? {
        let every = words(delivered), all = words(text)
        let old = Array(every.suffix(alignedWords)), first = every.count - old.count
        guard let last = old.last, delivered[last.end...].allSatisfy({ !($0.isLetter || $0.isNumber) }) else { return nil }
        let new = Array(all.suffix(old.count + alignedWords))
        let a = old.enumerated().map { aliases[first + $0.offset] ?? $0.element.word }, b = new.map(\.word)
        guard !b.isEmpty else { return nil }
        var table = [[Int]](repeating: [Int](repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in stride(from: a.count - 1, through: 0, by: -1) {
            for j in stride(from: b.count - 1, through: 0, by: -1) {
                table[i][j] = a[i] == b[j] ? table[i + 1][j + 1] + 1 : max(table[i + 1][j], table[i][j + 1])
            }
        }
        var matches: [Int: Int] = [:]
        var i = 0, j = 0
        while i < a.count, j < b.count {
            if a[i] == b[j], table[i][j] == table[i + 1][j + 1] + 1 { matches[i] = j; i += 1; j += 1 }
            else if table[i][j + 1] >= table[i + 1][j] { j += 1 } else { i += 1 }
        }
        // The last word, and most of the few before it, stand in the revision. Or the last few words were heard again
        // as others, one for one ("whether" → "weather"): the words after them in the revision are new, and the
        // delivered ones stay as typed (a take the user acted in is never revised; delivery must not stall on it).
        // (Every delivered word heard again: one for one from the take's start.)
        let anchor = matches[a.count - 1] != nil ? a.count - 1 : (matches.keys.max() ?? -1)
        let revised = a.count - 1 - anchor
        let fromStart = anchor < 0 && first == 0 && new.count == all.count
        guard anchor >= 0 || fromStart, revised <= (allowsRevisedTail ? Self.revisedWords : 0) else { return nil }
        let matched = anchor >= 0 ? matches[anchor]! : -1
        guard matched + revised < new.count else { return nil }
        let at = matched + revised
        let recent = max(0, anchor - 3)..<max(0, anchor)
        guard recent.isEmpty || recent.contains(where: { matches[$0] != nil }) else { return nil }
        // Delivered words heard again one for one (between two matched words, or at the end) align as the new word
        // from now on: a take that is never revised still finds its end in later versions.
        var previous = (i: -1, j: -1)
        for (i, j) in matches.sorted(by: { $0.key < $1.key }) + [(anchor + revised + 1, at + 1)] {
            if i - previous.i == j - previous.j, i - previous.i > 1 {
                for k in (previous.i + 1)..<i { aliases[first + k] = b[previous.j + k - previous.i] }
            }
            previous = (i, j)
        }
        // What stands after the last word in the delivered text is delivered too, where the revision has it as well
        // ("some." delivered, "some." again): it is not typed a second time.
        var end = new[at].end
        for c in delivered[last.end...] {
            guard end < text.count, text[end] == c else { break }
            end += 1
        }
        return end
    }
}

