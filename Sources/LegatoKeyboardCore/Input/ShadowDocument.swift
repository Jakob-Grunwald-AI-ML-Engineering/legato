import Foundation

/// The keyboard's picture of the field on iOS: the known text around the caret, where the caret is (`cursor`), where it
/// belongs to the user (`userCursor`), a selection after the caret, and the regions the keyboard tracks in it (`spans`).
///
/// One owner, two writers of evidence: `FieldQueue` simulates every op it sends on it (an executed chunk), and its
/// observer (`FieldQueue.observe`, `ShadowObserver`) keeps it current from every report the proxy gives, idle or not.
/// Pure value; nothing here talks to a proxy.
public struct ShadowDocument: Sendable, Equatable {
    /// A tracked region of the text (a dictation piece, an edit's scope, an anchor).
    struct Span: Sendable, Equatable {
        var start: Int
        var end: Int
        var userChanged = false
        /// Another edit (Magic) rewrote part of it: a dictation region there is left as it is.
        var edited = false
        /// Behind a seam: its bounds mean nothing until the observer finds its text again (`lastText`).
        var parked = false
        /// An edit's anchor: text inserted right at it goes after it.
        var anchor = false
        /// The text the span was last known to hold, to find it again after a seam.
        var lastText: [Character] = []
        /// The text around it then (up to `FieldQueue.contextChars` each side): it must stand there too.
        var lastBefore: [Character] = []
        var lastAfter: [Character] = []
        /// The user typed or edited while the span was lost: a change found there may be theirs.
        var userActedParked = false
        /// Parked by `revert`: the text it holds if the edit's inserts and deletes the report no longer showed did
        /// reach the host after all (`lastText`: if they did not). Only a fresh read tells which (`FieldRecovery`).
        var landedText: [Character]?
    }

    public internal(set) var text: [Character] = []
    public internal(set) var cursor = 0
    public internal(set) var userCursor = 0
    /// Characters selected after `cursor`.
    public internal(set) var selection = 0
    public internal(set) var seeded = false
    var spans: [Int: Span] = [:]
    private(set) var nextSpanID = 0

    public init() {}

    // MARK: Editing (what an executed op does)

    /// `chars` typed at the caret. `owner`: the span whose text it is (nil: the user's).
    mutating func insertAtCursor(_ chars: [Character], owner: Int?) {
        guard !chars.isEmpty else { return }
        let i = cursor, n = chars.count
        text.insert(contentsOf: chars, at: i)
        for (id, var span) in spans {
            if id != owner, span.start < i, i < span.end { if owner == nil { span.userChanged = true } else { span.edited = true } }
            if span.start > i || (span.start == i && id != owner && !span.anchor) { span.start += n }
            if span.end > i || (span.end == i && id == owner) { span.end += n }
            span.end = max(span.end, span.start)
            spans[id] = span
        }
        if userCursor >= i { userCursor += n }
        cursor = i + n
    }

    /// `text[a..<b]` deleted; the caret ends at `a`.
    mutating func removeRange(_ a: Int, _ b: Int, owner: Int?) {
        guard a < b, a >= 0, b <= text.count else { return }
        let n = b - a
        text.removeSubrange(a..<b)
        func shift(_ p: Int) -> Int { p >= b ? p - n : (p > a ? a : p) }
        for (id, var span) in spans {
            if id != owner, span.start < b, a < span.end { if owner == nil { span.userChanged = true } else { span.edited = true } }
            span.start = shift(span.start); span.end = shift(span.end)
            spans[id] = span
        }
        userCursor = shift(userCursor)
        cursor = a
    }

    /// Text learned in front of what was known.
    mutating func prepend(_ chars: [Character]) {
        guard !chars.isEmpty else { return }
        let n = chars.count
        text.insert(contentsOf: chars, at: 0)
        cursor += n; userCursor += n
        for (id, var span) in spans { span.start += n; span.end += n; spans[id] = span }
    }

    /// Text learned after what was known.
    mutating func append(_ chars: some Sequence<Character>) { text += chars }

    /// A span's text (empty for a parked span, whose bounds mean nothing until it is found again).
    func chars(of span: Span) -> [Character] {
        guard !span.parked, span.start >= 0, span.start <= span.end, span.end <= text.count else { return [] }
        return Array(text[span.start..<span.end])
    }

    mutating func addSpan(_ span: Span) -> Int {
        nextSpanID += 1
        spans[nextSpanID] = span
        return nextSpanID
    }

    /// The report is the whole picture: the model starts over from it (spans keep their ids and are not touched).
    mutating func seed(_ report: FieldQueue.Report) {
        var before = Array(FieldReader.trusted(before: report.before))
        // A window that starts at a block shows "\n " there: a line break is known to precede the block.
        if before.count < report.before.count, report.before.first?.isNewline == true { before.insert("\n", at: 0) }
        let selected = Array(report.selected ?? "")
        text = before + selected + Array(report.after)
        cursor = before.count; userCursor = cursor; selection = selected.count
        seeded = true
    }

    /// The model's text, caret and spans go back to `state`'s (span ids stay unique).
    mutating func restore(_ state: ShadowDocument) {
        text = state.text; cursor = state.cursor; userCursor = state.userCursor; selection = state.selection; spans = state.spans
    }

    /// The field's units from the caret to `index`: UTF-16, or characters in a field that moves by characters. The
    /// observer corrects the difference a host's own unit makes (`FieldQueue` hops look and adjust).
    func units(to index: Int, byCharacters: Bool) -> Int {
        let range = index > cursor ? cursor..<index : index..<cursor
        let count = byCharacters ? range.count : String(text[range]).utf16.count
        return index > cursor ? count : -count
    }

    // MARK: Reading a report against the model

    /// Every place in the model the report fits (its text before and after the caret, the selection included).
    func positions(of report: FieldQueue.Report) -> [Int] {
        FieldMatch.positions(in: text, reportedBefore: report.before, reportedAfter: (report.selected ?? "") + report.after)
    }

    func fitsSelection(_ p: Int, _ selected: String) -> Bool {
        let chars = Array(selected)
        return p + chars.count <= text.count && text[p..<(p + chars.count)].elementsEqual(chars)
    }

    /// The report fits the model at its caret, perhaps elsewhere too.
    func fits(_ report: FieldQueue.Report) -> Bool {
        (report.selected ?? "").count == selection && positions(of: report).contains(cursor)
    }

    /// The report fits the model at its caret and nowhere else.
    func pins(_ report: FieldQueue.Report) -> Bool {
        positions(of: report) == [cursor] && (report.selected ?? "").count == selection
    }

    /// The report fits the model at its caret, wholly inside its text (no reaching past either end).
    func fitsInside(_ report: FieldQueue.Report) -> Bool {
        fits(report) && (report.selected ?? "").count + report.after.count <= text.count - cursor
            && FieldReader.trusted(before: report.before).count <= cursor
    }

    /// The report shows this much known text around a place (`chars`, or all the model knows).
    func hasEvidence(_ report: FieldQueue.Report, chars: Int) -> Bool {
        FieldReader.trusted(before: report.before).count + (report.selected ?? "").count + report.after.count >= min(chars, text.count)
    }

    /// The report reaches further than the model on either side while agreeing with it at the caret: the model grows by
    /// the extra text. Nothing else changes.
    mutating func extend(with report: FieldQueue.Report) -> (front: Int, back: Int) {
        var front = 0, back = 0
        let before = Array(FieldReader.trusted(before: report.before))
        if before.count > cursor, before.suffix(cursor).elementsEqual(text[..<cursor]) {
            front = before.count - cursor
            prepend(Array(before.prefix(front)))
        }
        let after = Array(report.after)
        let tail = cursor + selection
        let known = text.count - tail
        if after.count > known, after.prefix(known).elementsEqual(text[tail...]) {
            back = after.count - known
            text += after[known...]
        }
        return (front, back)
    }
}

/// What a report says about the shadow (`ShadowDocument.observe`). The observer keeps the shadow current from every proxy
/// callback, separately from the chunks that edit the field.
public enum ShadowObservation: Sendable, Equatable {
    /// The report shows the shadow at its caret.
    case match
    /// The report shows the shadow at its caret and text beyond what the shadow knew there.
    case extends
    /// The report shows known text, at one other place only: the caret is there (a tap, a jump into known text).
    case stitch(at: Int)
    /// The report shows text the shadow cannot place (a paste, another field, text replaced whole): an unknown region.
    case seam
}

extension ShadowDocument {
    /// Classifies a report against the shadow. `evidence`: how much agreeing text a stitch takes (finding text again by a
    /// short window may find another field's).
    public func observe(_ report: FieldQueue.Report, evidence: Int = FieldQueue.relocateChars) -> ShadowObservation {
        let selected = report.selected ?? ""
        let before = FieldReader.trusted(before: report.before)
        let found = positions(of: report)
        if found.contains(cursor), selected.count == selection, fitsSelection(cursor, selected) {
            let knownAfter = text.count - cursor - selection
            return before.count > cursor || report.after.count > knownAfter ? .extends : .match
        }
        // The shadow knows little before the caret and the report reaches back past it, agreeing with all of it.
        if before.count > cursor, cursor >= 1, before.suffix(cursor).elementsEqual(text[..<cursor]), selected.count == selection,
           FieldMatch.positions(in: Array(before.prefix(before.count - cursor)) + text, reportedBefore: report.before,
                                reportedAfter: selected + report.after) == [before.count] {
            return .extends
        }
        let inside = found.filter { selected.count + report.after.count <= text.count - $0 && before.count <= $0 }
        if found.count == 1, inside == found, hasEvidence(report, chars: evidence) { return .stitch(at: found[0]) }
        return .seam
    }
}
