import Foundation
import LegatoCore

// The parts of the sentence-rewrite cleanup agent around its model turn (spike #95): the endpointer that decides
// when a recognized sentence is finished, the reply cleanup, the guard that lets a rewrite through, and the context
// share every turn is kept within.

/// Decides when a recognized sentence is finished and goes to the model: it is followed by more text (the text was
/// split there by its punctuation or an earlier cut), it ends with terminal punctuation, it is ``Config/maxWords``
/// words long without an end (run-ons still get cleaned), or the speaker paused for ``Config/pause``. At stop the
/// unfinished last sentence is ready too.
public struct SentenceEndpointer: Sendable {
    public struct Config: Sendable, Hashable {
        public var pause: Duration
        public var maxWords: Int
        public init(pause: Duration = .milliseconds(700), maxWords: Int = 30) {
            self.pause = pause
            self.maxWords = maxWords
        }
    }

    public enum Reason: String, Sendable, Hashable {
        /// More text follows it.
        case followed
        case punctuation
        case length
        case pause
        /// The run stopped.
        case end
    }

    public let config: Config

    public init(config: Config = Config()) { self.config = config }

    /// Why `sentence` is ready, or nil while it may still grow. `isLast`: nothing of the run follows it yet;
    /// `quiet`: how long the run's text has not changed; `final`: the run stopped.
    public func ready(_ sentence: String, isLast: Bool, quiet: Duration, final: Bool) -> Reason? {
        guard sentence.contains(where: { !$0.isWhitespace }) else { return nil }
        if !isLast { return .followed }
        if Self.endsSentence(sentence) { return .punctuation }
        if Self.wordCount(sentence) >= config.maxWords { return .length }
        if quiet >= config.pause { return .pause }
        return final ? .end : nil
    }

    public static func wordCount(_ text: String) -> Int { text.split(whereSeparator: \.isWhitespace).count }

    private static let abbreviations: Set<String> = [
        "mr.", "mrs.", "ms.", "dr.", "prof.", "st.", "vs.", "e.g.", "i.e.", "approx.", "no.", "z.b.", "bzw.", "ca.", "nr.",
    ]

    /// Ends with `.`, `!`, `?` or `…` (closing quotes and brackets after it allowed), and its last word is not a
    /// title or an abbreviation such as "e.g.".
    public static func endsSentence(_ text: String) -> Bool {
        var trimmed = Substring(text.trimmingCharacters(in: .whitespacesAndNewlines))
        while let last = trimmed.last, "\"')]}\u{201D}\u{2019}\u{00BB}".contains(last) { trimmed = trimmed.dropLast() }
        guard let last = trimmed.last, ".!?\u{2026}".contains(last) else { return false }
        guard last == "." else { return true }
        let word = trimmed.split(whereSeparator: \.isWhitespace).last.map { $0.lowercased() } ?? ""
        return !abbreviations.contains(word.trimmingCharacters(in: CharacterSet(charactersIn: "\"'([{\u{201C}\u{2018}\u{00AB}")))
    }
}

/// The rewritten text inside the model's raw reply.
public enum RewriteReply {
    /// Think blocks, a leading label and wrapping quotes removed, lines trimmed; line breaks joined with spaces
    /// unless `keepLineBreaks` (Markdown). Nil when nothing is left.
    public static func clean(_ raw: String, keepLineBreaks: Bool = false) -> String? {
        var text = raw
        while let open = text.range(of: "<think>") {
            let close = text.range(of: "</think>", range: open.upperBound..<text.endIndex)
            text.removeSubrange(open.lowerBound..<(close?.upperBound ?? text.endIndex))
        }
        let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        text = lines.joined(separator: keepLineBreaks ? "\n" : " ")
        for label in ["Assistant:", "Sentence:", "Rewritten:", "Corrected:"] where text.hasPrefix(label) {
            text = String(text.dropFirst(label.count)).trimmingCharacters(in: .whitespaces)
        }
        for (open, close) in [("\"", "\""), ("\u{201C}", "\u{201D}"), ("`", "`")]
        where text.count > 1 && text.hasPrefix(open) && text.hasSuffix(close) {
            text = String(text.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
        }
        return text.isEmpty ? nil : text
    }
}

/// Whether a rewritten sentence still says what was dictated. Either guard may accept it: the message guard (drops
/// filler, false starts and self-corrections; its content words must come from the input) or a word drift of at
/// most 40 % (lets in the written forms the message guard counts as new words: "x code" → "Xcode", "four oh four"
/// → "404", "their" → "there"). An answer, a translation or another text fails both.
public enum RewriteGuard {
    public static let drift = CleanupGuard(maxDrift: 0.4)

    public static func accepts(_ candidate: String, reference: String) -> Bool {
        CleanupGuard.message.accepts(candidate, reference: reference) || drift.accepts(candidate, reference: reference)
    }
}

/// The context every agent turn is kept within: a share of the backend's token budget, enforced before each turn
/// (not only when the window is full), the oldest turns dropped first, the instructions and examples kept.
public enum RewriteContext {
    /// The share of the backend's budget a turn may use (spike #95: 50 %).
    public static let share = 50

    public static func budget(tokenBudget: Int, share: Int = share) -> Int { max(0, tokenBudget * share / 100) }

    /// A token estimate for text the session has not counted yet (about three UTF-8 bytes per token).
    public static func estimatedTokens(_ text: String) -> Int { (text.utf8.count + 2) / 3 }

    /// Tokens a reply to a request of `requestTokens` may take: twice the request plus a little.
    public static func replyReserve(requestTokens: Int) -> Int { requestTokens * 2 + 16 }

    /// The history to keep (``LLMSession/trim(keepingSuffix:)``) so the session, the request and its reply fit
    /// `budget`; nil when they fit already.
    public static func trimTarget(usage: LLMTokenUsage, request: Int, budget: Int) -> Int? {
        let reserve = replyReserve(requestTokens: request)
        guard usage.total + request + reserve > budget else { return nil }
        return max(0, budget - usage.head - request - reserve)
    }
}
