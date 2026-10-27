import Foundation

/// What the word row shows.
public enum WordRowContent: Sendable, Equatable {
    /// A tapped word: alternatives for it. `requestID` tells a late answer from the newest tap.
    case alternatives(word: String, span: WordSpan, requestID: Int)
    /// A word being typed: completions of the prefix.
    case completions(prefix: String)
    /// Between words: likely next words after `previous` (nil at the start of a field or a line).
    case predictions(previous: String?)
    /// Dictation status or a hint takes the row over.
    case status(String)
    case empty
}

/// Decides what the word row shows. The newest intent wins: a keystroke shows completions (or
/// predictions after a space), a cursor move the keyboard didn't make shows alternatives for the word
/// it landed on (predictions in a space). A status or an active run takes the row over and pauses both
/// until it ends; the row is then empty until the next intent.
public struct SuggestionState: Sendable {
    /// How long after the keyboard's own edit a matching cursor report still counts as that edit.
    public static let settleWindow: TimeInterval = 0.6

    public private(set) var content: WordRowContent = .empty

    private var statusText: String?
    private var running = false
    private var nextRequestID = 1
    private var expected: (contextBefore: String, at: Date)?

    public init() {}

    private var paused: Bool { running || statusText != nil }

    /// The keyboard is about to change the field; the cursor reports that follow, and match
    /// `expectedContextBefore` inside the settle window, are not the user moving the cursor.
    public mutating func willApplyOwnEdit(expectedContextBefore: String, at now: Date) {
        expected = (expectedContextBefore, now)
    }

    /// A key was typed (or a completion applied); `contextBefore` is the text before the cursor now.
    @discardableResult
    public mutating func keystroke(contextBefore: String, at now: Date) -> WordRowContent {
        expected = (contextBefore, now)
        guard !paused else { return content }
        content = Self.typing(contextBefore)
        return content
    }

    /// The cursor or text changed (`selectionDidChange` / `textDidChange`).
    @discardableResult
    public mutating func cursorMoved(contextBefore: String, contextAfter: String, hasSelection: Bool, at now: Date) -> WordRowContent {
        if let expected {
            if contextBefore == expected.contextBefore, now.timeIntervalSince(expected.at) <= Self.settleWindow { return content }
            self.expected = nil
        }
        guard !paused else { return content }
        guard !hasSelection else { content = .empty; return content }
        if let hit = WordAtCursor.find(contextBefore: contextBefore, contextAfter: contextAfter) {
            if case .alternatives(let word, let span, _) = content, word == hit.word, span == hit.span { return content }
            content = .alternatives(word: hit.word, span: hit.span, requestID: nextRequestID)
            nextRequestID += 1
        } else {
            content = Self.typing(contextBefore, completing: false)
        }
        return content
    }

    /// A dictation or Refine run started or ended in this field.
    @discardableResult
    public mutating func runActive(_ active: Bool) -> WordRowContent {
        running = active
        refresh()
        return content
    }

    /// Dictation status or a hint; nil clears it.
    @discardableResult
    public mutating func status(_ text: String?) -> WordRowContent {
        statusText = text
        refresh()
        return content
    }

    private mutating func refresh() {
        if let statusText, !statusText.isEmpty { content = .status(statusText) } else { content = .empty }
    }

    /// What a context ending at the cursor shows: completions inside a word, predictions after
    /// whitespace or at the start, nothing after punctuation.
    private static func typing(_ before: String, completing: Bool = true) -> WordRowContent {
        let prefix = TextContext(documentContextBeforeInput: before).wordPrefix
        if completing, !prefix.isEmpty { return .completions(prefix: prefix) }
        guard let last = before.last else { return .predictions(previous: nil) }
        guard last.isWhitespace else { return .empty }
        if last.isNewline { return .predictions(previous: nil) }
        let words = before.split(whereSeparator: { !($0.isLetter || $0.isNumber || $0 == "'" || $0 == "’") })
        let tail = before.reversed().drop(while: { $0.isWhitespace })
        guard let end = tail.first, end.isLetter || end.isNumber || end == "'" || end == "’", let word = words.last
        else { return .empty }
        return .predictions(previous: String(word))
    }
}
