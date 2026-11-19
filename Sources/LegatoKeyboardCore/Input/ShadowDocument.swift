import Foundation

/// The keyboard's picture of the field on iOS: the known text around the caret, where the caret is (`cursor`), where it
/// belongs to the user (`userCursor`), a selection after the caret, and the regions the keyboard tracks in it (`spans`).
///
/// One owner, two writers of evidence: `FieldQueue` simulates every op it sends on it (an executed chunk), and its
/// observer (`FieldQueue.observe`, `ShadowObserver`) keeps it current from every report the proxy gives, idle or not.
/// Pure value; nothing here talks to a proxy.
public struct ShadowDocument: Sendable, Equatable {
    /// An accepted scoped write, independent of the projected host text as operations land.
    struct EditIntent: Sendable, Equatable {
        enum Origin: Sendable, Equatable { case cleanup, recognition, edit }
        var target: String
        var origin: Origin
        /// The host's original scope carried around any higher-priority edits made during synchronization.
        var original: [Character]
        /// What the scope holds after our own issued writes, before any competing change.
        var transportBaseline: [Character]

        func target(around observed: [Character]) -> [Character] {
            let desired = Array(target)
            guard origin == .cleanup, transportBaseline != observed else { return desired }
            return FieldMerge.rebase(base: transportBaseline, kept: observed, incoming: desired).text
        }
    }

    struct CleanupReplacement: Sendable, Equatable {
        var at: Int
        var pieces: Set<Int>
        var leavesCaretBefore: Bool
    }

    /// A tracked region of the text (a dictation piece, an edit's scope, an anchor).
    struct Span: Sendable, Equatable {
        var start: Int
        var end: Int
        var userChanged = false
        /// Another edit (Magic) rewrote part of it: a dictation region there is left as it is.
        var edited = false
        /// Cleanup can style a piece, but recognition of that speech can still revise it.
        var cleaned = false
        /// A dictation piece: a cleanup's text at its edges is its own (`cleanup`).
        var dictated = false
        /// A cleanup's scope (a pass from the shadow): what it types at a dictation piece's edge belongs to the piece, so
        /// the take keeps it and a later pass sends it again instead of adding it twice (#299 device run 6: "Um. so" made
        /// "So" left the take starting after the "S", and every later pass typed another; a period after the last word).
        var cleanup = false
        /// Dictation pieces whose characters this exact cleanup operation removed.
        var replacement: CleanupReplacement?
        /// Identifies a direct user rewrite while its host operations are in flight.
        var userEdit = false
        /// A surviving user-authored range or deletion boundary.
        var protected = false
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

    var protectedRanges: [Range<Int>] {
        spans.values.filter { $0.protected && !$0.parked }.map { $0.start..<$0.end }
    }

    private mutating func protect(_ range: Range<Int>) {
        var start = range.lowerBound, end = range.upperBound
        for (id, span) in spans where span.protected && !span.parked && span.start <= end && start <= span.end {
            start = min(start, span.start); end = max(end, span.end)
            spans[id] = nil
        }
        var span = Span(start: start, end: end)
        span.protected = true
        _ = addSpan(span)
    }

    // MARK: Editing

    /// Resolve a user's key in known text. Opaque selection and read boundaries remain with the host adapter.
    func replacement(for input: FieldQueue.Input) -> (range: Range<Int>, text: [Character])? {
        let at = cursor
        switch input {
        case .insert(let key): return (at..<(at + selection), Array(key))
        case .deleteBackward where selection > 0: return (at..<(at + selection), [])
        case .deleteBackward where at > 0: return ((at - 1)..<at, [])
        case .deleteBackward, .move: return nil
        }
    }

    mutating func project(_ input: FieldQueue.Input) -> Bool {
        if case .move(let delta) = input {
            guard selection == 0 else { return false }
            cursor = min(max(0, cursor + delta), text.count)
        } else {
            guard let change = replacement(for: input) else { return false }
            let range = change.range
            removeRange(range.lowerBound, range.upperBound, owner: nil)
            selection = 0
            insertAtCursor(change.text, owner: nil)
        }
        userCursor = cursor
        return true
    }

    /// Materialize a placed intent without describing any host cursor moves or transport mutations.
    mutating func project(_ intent: EditIntent, in id: Int, cursorAtEnd: Bool) {
        guard let span = spans[id], !span.parked, !span.userChanged || intent.origin == .cleanup else { return }
        let old = chars(of: span), desired = intent.target(around: old)
        let caret = userCursor
        let offset = FieldMerge.position(min(max(0, caret - span.start), old.count), from: old, to: desired, afterInsertion: true)
        for hunk in ShadowEditPlanner.diff(old, desired).reversed() {
            let lower = span.start + hunk.start
            cursor = span.start + hunk.end
            removeRange(lower, cursor, owner: id)
            insertAtCursor(hunk.text, owner: id)
        }
        if cursorAtEnd { userCursor = span.start + desired.count }
        else if (span.start...span.end).contains(caret) { userCursor = span.start + offset }
        cursor = userCursor
    }

    /// `chars` typed at the caret. `owner`: the span whose text it is (nil: the user's).
    mutating func insertAtCursor(_ chars: [Character], owner: Int?) {
        guard !chars.isEmpty else { return }
        let i = cursor, n = chars.count
        let cleanup = owner.flatMap { spans[$0] }?.cleanup == true
        let replacement = owner.flatMap { spans[$0]?.replacement }.flatMap { $0.at == i ? $0 : nil }
        let endsHere = cleanup && spans.values.contains { $0.dictated && !$0.parked && $0.start < i && $0.end == i }
        let startsHere = cleanup && spans.values.contains { $0.dictated && !$0.parked && $0.start == i && i < $0.end }
        let punctuation = chars.first.map { !$0.isLetter && !$0.isNumber && !$0.isWhitespace } ?? false
        let leavesCaretBefore = replacement?.leavesCaretBefore ?? (endsHere && startsHere && !punctuation)
        if let owner { spans[owner]?.replacement = nil }
        text.insert(contentsOf: chars, at: i)
        for (id, var span) in spans {
            if id != owner, span.start < i, i < span.end { noteChange(to: &span, owner: owner, cleanup: cleanup) }
            // A replacement belongs to the piece it removed from. At a shared edge, pure terminal
            // punctuation belongs to the preceding piece and a new word to the following piece.
            let edge = span.dictated && cleanup && (replacement.map { $0.pieces.contains(id) } ??
                (!endsHere || !startsHere || (punctuation ? span.end == i : span.start == i)))
            if span.start > i || (span.start == i && id != owner && !span.anchor && !edge) { span.start += n }
            if span.end > i || (span.end == i && (id == owner || edge)) { span.end += n }
            if edge && (span.start == i || span.end == i + n) { span.cleaned = true }
            span.end = max(span.end, span.start)
            spans[id] = span
        }
        if userCursor > i || (userCursor == i && !leavesCaretBefore) { userCursor += n }
        cursor = i + n
        if owner == nil || owner.flatMap({ spans[$0] })?.userEdit == true { protect(i..<(i + n)) }
    }

    /// `text[a..<b]` deleted; the caret ends at `a`.
    mutating func removeRange(_ a: Int, _ b: Int, owner: Int?) {
        guard a < b, a >= 0, b <= text.count else { return }
        let n = b - a
        let cleanup = owner.flatMap { spans[$0] }?.cleanup == true
        if let owner, cleanup {
            let pieces = spans.compactMap { id, span in
                span.dictated && !span.parked && span.start < b && a < span.end ? id : nil
            }
            spans[owner]?.replacement = CleanupReplacement(at: a, pieces: Set(pieces), leavesCaretBefore: userCursor == a)
        }
        text.removeSubrange(a..<b)
        func shift(_ p: Int) -> Int { p >= b ? p - n : (p > a ? a : p) }
        for (id, var span) in spans {
            if id != owner, span.start < b, a < span.end { noteChange(to: &span, owner: owner, cleanup: cleanup) }
            span.start = shift(span.start); span.end = shift(span.end)
            spans[id] = span
        }
        userCursor = shift(userCursor)
        cursor = a
        if owner == nil || owner.flatMap({ spans[$0] })?.userEdit == true { protect(a..<a) }
    }

    private func noteChange(to span: inout Span, owner: Int?, cleanup: Bool) {
        if owner == nil || owner.flatMap({ spans[$0] })?.userEdit == true { span.userChanged = true }
        else if cleanup && span.dictated { span.cleaned = true }
        else { span.edited = true }
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
