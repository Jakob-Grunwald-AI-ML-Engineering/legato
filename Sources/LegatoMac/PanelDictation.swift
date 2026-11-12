import Foundation

/// Where a take's words show while it runs: in the field itself (live editing), or in the notch panel, typed into
/// the app once when the take ends. Stored in the Mac app's standard defaults (Settings → Shortcut → Send dictation).
public enum PanelDictationSetting {
    public enum Mode: String, CaseIterable, Sendable {
        /// The panel only where the field cannot be edited live: unreadable, or readable without any way to write.
        case whenNeeded
        /// The panel for every field: nothing touches the field until the take is final, then it goes in once (through
        /// the field's queue where the field is readable).
        case always
    }
    public static let key = "dictation.panel"
    public static let defaultMode = Mode.whenNeeded
    public static func mode(in defaults: UserDefaults = .standard) -> Mode {
        Mode(rawValue: defaults.string(forKey: key) ?? "") ?? defaultMode
    }
}

/// What the dictation found in front, as far as the panel decision goes.
public enum DictationFieldKind: Sendable, Equatable {
    /// Readable, and Accessibility writes land exactly: live editing works.
    case liveEditable
    /// Readable (Magic can read it), but it takes neither Accessibility writes nor verified keys.
    case readOnly
    /// Nothing readable: no focused element, or no selection.
    case unreadable
    /// A positively identified password field: the panel, typed once at the end like an unreadable field; its takes
    /// are not kept in History.
    case password
}

public enum PanelDictationPolicy {
    /// Whether a take into this field goes through the panel: every field that is not edited live does. There are
    /// only these two modes; no field is copy-only from the start.
    public static func usesPanel(_ mode: PanelDictationSetting.Mode, field: DictationFieldKind) -> Bool {
        switch field {
        case .liveEditable: mode == .always
        case .readOnly, .unreadable, .password: true
        }
    }
}

/// What the notch panel (the pill) shows while a take runs. A take that types straight into its field never shows its
/// words in the pill: the field does. The pill then holds only the listening state and quick controls (Magic, Undo,
/// Redo). A panel-mode take keeps showing every word, growing, until they were typed.
public enum DictationPillContent: Sendable, Equatable {
    /// The take's growing text.
    case growingText
    /// A compact listening state with Magic, Undo and Redo.
    case listeningControls

    public static func forTake(panelActive: Bool) -> DictationPillContent { panelActive ? .growingText : .listeningControls }

    public static func forPolicy(_ mode: PanelDictationSetting.Mode, field: DictationFieldKind) -> DictationPillContent {
        forTake(panelActive: PanelDictationPolicy.usesPanel(mode, field: field))
    }
}

/// The words a panel-mode session shows and types once at the end: finished pieces in speaking order, then the one
/// piece still growing (a live run, or a take whose cleanup streams). A later revision of a finished piece (a late
/// cleanup of the same run) replaces it in place instead of adding it again.
public struct PanelTake: Sendable, Equatable {
    private struct Piece: Sendable, Equatable {
        var id: String
        var text: String
        var finished: Bool
    }
    private var pieces: [Piece] = []
    /// Pieces already handed over for typing: a late revision of one is never typed again.
    private var taken: Set<String> = []

    public init() {}

    /// Everything, joined the way the field would receive it.
    public var text: String {
        pieces.map(\.text).reduce("") { joined, next in
            guard !next.isEmpty else { return joined }
            guard let last = joined.last else { return next }
            return joined + Self.space(before: next, after: last, first: false) + next
        }
    }
    public var isEmpty: Bool { text.isEmpty }
    /// A piece is still growing (a live run in progress, a stream not final or held after a failed cleanup).
    public var isGrowing: Bool { pieces.contains { !$0.finished } }

    /// A live run's snapshot (finals and the speaking head); `complete` finishes it.
    public mutating func live(id: String, text: String, complete: Bool) { update(id: id, text: text, finished: complete) }

    /// A streamed take as it grows; `final` finishes it, `retracted` takes it back out.
    public mutating func stream(id: String, text: String, final: Bool, retracted: Bool = false) {
        if retracted { pieces.removeAll { $0.id == id }; return }
        update(id: id, text: text, finished: final)
    }

    /// A finished line (line-by-line dictation, an inserted raw take).
    public mutating func line(id: String = UUID().uuidString, _ text: String) { update(id: id, text: text, finished: true) }

    /// Drops every unfinished piece (a stalled stream taken back for Retry / Insert as-is).
    public mutating func dropGrowing() { pieces.removeAll { !$0.finished } }

    /// Hands over the finished pieces before the first unfinished one, for typing, and forgets them. A later hand-over
    /// starts with the space the earlier one's last character wants.
    public mutating func takeFinished() -> String {
        let count = pieces.firstIndex(where: { !$0.finished }) ?? pieces.count
        var done = PanelTake()
        done.pieces = Array(pieces.prefix(count))
        taken.formUnion(done.pieces.map(\.id))
        pieces.removeFirst(count)
        let body = done.text
        guard let first = body.first else { return "" }
        defer { lastTaken = body.last }
        guard let lastTaken, first != "\n" else { return body }
        return Self.space(before: body, after: lastTaken, first: false) + body
    }
    private var lastTaken: Character?
    /// Nothing was handed over yet: the first text needs the field's own preceding character for its space.
    public var isFirstHandOver: Bool { lastTaken == nil }

    /// The space (or nothing) between a field's `previous` character and `text`.
    public static func separator(before text: String, after previous: Character?) -> String {
        space(before: text, after: previous, first: true)
    }

    /// A space unless `text` starts with whitespace or closing punctuation, or `previous` is whitespace or opening
    /// punctuation. No previous character: none in an empty field (`first`), one after earlier unknown text.
    static func space(before text: String, after previous: Character?, first: Bool) -> String {
        guard let next = text.first, !next.isWhitespace, !".,;:!?)]}%".contains(next) else { return "" }
        guard let previous else { return first ? "" : " " }
        if previous.isWhitespace || "([{\"'“‘„«¿¡".contains(previous) { return "" }
        return " "
    }

    private mutating func update(id: String, text: String, finished: Bool) {
        guard !taken.contains(id) else { return }
        if let index = pieces.firstIndex(where: { $0.id == id }) {
            pieces[index].text = text
            pieces[index].finished = pieces[index].finished || finished
        } else {
            pieces.append(Piece(id: id, text: text, finished: finished))
        }
    }
}

/// A take that went on in the panel after part of it was typed live (`MacFieldQueue.Handover`): the typed characters
/// stay in the field as they are, and each newer version of the take shows (and is typed at the end) from where they
/// end. That place follows the take by words: the field's first N words stand for the first N words of the newest text,
/// however a revision or cleanup changed them (a replaced word, a capital, punctuation), so no word is typed twice and
/// none is skipped (`MacFieldQueue.typedPrefix` counts the same way).
public struct PanelContinuation: Sendable, Equatable {
    private var text: [Character]
    private var boundary: Int

    public init(text: String, typed: Int) {
        self.text = Array(text)
        boundary = min(max(0, typed), self.text.count)
    }

    /// What of the take's text the field does not show yet.
    public var rest: String { String(text[boundary...]) }

    /// Takes the take's newest text and returns its rest.
    public mutating func rest(of newest: String) -> String {
        let new = Array(newest)
        boundary = Self.map(boundary, from: text, to: new)
        text = new
        return rest
    }

    /// The words of `text`: their character ranges.
    private static func words(_ text: [Character]) -> [Range<Int>] {
        var words: [Range<Int>] = [], index = 0
        while index < text.count {
            while index < text.count, text[index].isWhitespace { index += 1 }
            let start = index
            while index < text.count, !text[index].isWhitespace { index += 1 }
            if index > start { words.append(start..<index) }
        }
        return words
    }

    /// Where `boundary` of `old` falls in `new`: in (or right after) the word of the same number, at the same offset from
    /// its start, inside the new word (or the space after it).
    static func map(_ boundary: Int, from old: [Character], to new: [Character]) -> Int {
        let oldWords = words(old), newWords = words(new)
        guard let word = oldWords.lastIndex(where: { $0.lowerBound < boundary }) else { return min(boundary, newWords.first?.lowerBound ?? new.count) }
        // Fewer words now: everything the newest text has is shown already.
        guard newWords.indices.contains(word) else { return new.count }
        let mapped = word
        let oldWord = oldWords[word], newWord = newWords[mapped]
        let offset = boundary - oldWord.lowerBound
        let next = mapped + 1 < newWords.count ? newWords[mapped + 1].lowerBound : new.count
        // In the space after the word: as far into the new space.
        guard offset <= oldWord.count else { return min(newWord.upperBound + offset - oldWord.count, next) }
        // Inside the word: the new word goes on from the typed letters (a word still being spoken, a capital or a stop
        // added); a word that changed otherwise stays as typed and stands for the new one.
        let typed = String(old[oldWord.lowerBound..<boundary]).lowercased()
        return String(new[newWord]).lowercased().hasPrefix(typed) ? newWord.lowerBound + offset : newWord.upperBound
    }
}
