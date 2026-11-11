import Foundation

/// Where a take's words show while it runs: in the field itself (live editing), or in the notch panel, typed into
/// the app once when the take ends. Stored in the Mac app's standard defaults; there is no UI for it yet.
public enum PanelDictationSetting {
    public enum Mode: String, CaseIterable, Sendable {
        /// The panel only where the field cannot be edited live: unreadable, or readable without exact writes.
        case whenNeeded
        /// The panel for every field that is not secure.
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
    /// Readable (Magic can read it), but the app does not apply Accessibility text writes (Chromium web content).
    case readOnly
    /// Nothing readable: no focused element, or no selection.
    case unreadable
    /// A secure field, or one that could not be ruled out: never typed into, only copied.
    case secure
}

public enum PanelDictationPolicy {
    /// Whether a take into this field goes through the panel. A secure field never does.
    public static func usesPanel(_ mode: PanelDictationSetting.Mode, field: DictationFieldKind) -> Bool {
        switch field {
        case .secure: false
        case .liveEditable: mode == .always
        case .readOnly, .unreadable: true
        }
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
