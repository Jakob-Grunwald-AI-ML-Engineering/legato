import Foundation
import LegatoFieldEdit

/// The app's copy of the keyboard's field, folded from its change feed (`link.feed` on iOS): the confirmed
/// window, the version and queue instance new edits are based on, which text the run wrote, and what happened to
/// the edits the app sent. Pure value type; ``LinkedCleanupRun`` keeps one per run.
///
/// The run's text is only what the feed attributes to an automatic write (`applied` with a non-user origin); user
/// text and foreign changes are never the run's. A resync from the same queue, or a reset other than a clear,
/// re-anchors it as ``CleanupAgent`` does (a span stays where its text occurs exactly once in the new window). A
/// clear, or a resync from another queue instance, forgets it: nothing is the run's until new automatic text lands.
///
/// iOS hosts report only a caret-relative window (`documentContextBefore/AfterInput`; WhatsApp ~100 characters).
/// When its left edge moves (`rebased`), the run's offsets move with it, so the part of the run that left the window
/// keeps exact, negative offsets; the text that scrolled out is kept as ``head`` (it ends at window offset 0), so
/// the run's text stays known. A step is only ever sent for the window, never for the head.
public struct FeedMirror: Sendable, Equatable {
    public enum Result: Sendable, Equatable {
        case applied
        case conflict(Conflict)
        case superseded
        case withdrawn
    }

    public private(set) var window = ""
    public private(set) var version = FieldVersion(0)
    public private(set) var session: UUID?
    /// The run's own text: spans automatic writes put in, sorted, never touching each other.
    public private(set) var runs: [Span] = []
    /// What the user wrote or changed since the last reset.
    public private(set) var touched: [Span] = []
    /// The feed's outcome for every transaction it named.
    public private(set) var results: [UUID: Result] = [:]
    /// The field was cleared (a send) since the run began.
    public private(set) var wasCleared = false
    /// Some of the run's text left what is known since the run began (iOS: its head left the window past what
    /// ``head`` kept, or a reset the run's text could not be found again in): not all of it can be told.
    public private(set) var lostRunText = false
    /// The field's text just before the window (it ends at window offset 0) that left the window through its left
    /// edge, as last seen; only as far back as the oldest span that needs it, and ``headLimit`` units at most.
    public private(set) var head = ""
    /// The most UTF-16 units of ``head`` kept: past it, only the run's tail is known.
    public let headLimit: Int
    private var lastSeq = 0
    /// The changes that landed since the last reset, with the version each left: for mapping an edit's steps from
    /// its base to the field now.
    private var changes: [(version: FieldVersion, change: Change)] = []

    private enum Change {
        case steps([EditStep])
        /// The window's left edge moved: offset `p` is now `p + shift`.
        case shift(Int)
    }

    public init(headLimit: Int = 8_192) {
        self.headLimit = max(0, headLimit)
    }

    public static func == (a: FeedMirror, b: FeedMirror) -> Bool {
        a.window == b.window && a.version == b.version && a.session == b.session && a.runs == b.runs
            && a.touched == b.touched && a.results == b.results && a.lastSeq == b.lastSeq && a.head == b.head
    }

    /// Whether anything has been read yet.
    public var isEmpty: Bool { session == nil }

    // MARK: Folding

    public mutating func fold(_ batch: FeedBatch) {
        if batch.resync || batch.session != session {
            guard batch.resync, let text = batch.window else { return }  // another queue, no window: wait
            if batch.session != session || text != window {
                // As the agent does: the same queue's window is searched for the run's text, another queue's is not.
                let anchored = batch.session == session ? reanchored(in: text) : nil
                if (anchored?.runs.count ?? 0) < runs.count { lostRunText = true }
                runs = anchored?.runs ?? []
                touched = anchored?.touched ?? []
                changes = []
                head = ""
            }
            session = batch.session
            window = text
            version = batch.version
            lastSeq = batch.lastSeq ?? 0
            return
        }
        for entry in batch.entries where entry.seq > lastSeq {
            lastSeq = entry.seq
            apply(entry.event)
        }
        version = batch.version
    }

    private mutating func apply(_ event: FeedEvent) {
        switch event {
        case .asrDelta:
            break
        case .applied(let id, let origin, let steps, let version):
            results[id] = .applied
            for step in steps { fold(step, run: !origin.isUser, user: origin.isUser) }
            changes.append((version, .steps(steps)))
        case .foreign(let step, let byUser, let version):
            fold(step, run: false, user: byUser)
            changes.append((version, .steps([step])))
        case .conflict(let id, let conflict):
            results[id] = .conflict(conflict)
        case .superseded(let id, _):
            results[id] = .superseded
        case .withdrawn(let id):
            results[id] = .withdrawn
        case .rebased(let text, let shift, let version):
            rebase(to: text, shift: shift)
            changes.append((version, .shift(shift)))
        case .reset(let reason, let text, _):
            let anchored = reason == .cleared ? nil : reanchored(in: text)
            if reason != .cleared, (anchored?.runs.count ?? 0) < runs.count { lostRunText = true }
            window = text
            head = ""
            runs = anchored?.runs ?? []
            touched = anchored?.touched ?? []
            changes = []
            if reason == .cleared { wasCleared = true }
        }
    }

    /// The window's edges moved (no text changed): old offset `p` is now `p + shift`. Text that left through the
    /// left edge joins ``head``; text that came back through it leaves ``head`` again when it is the same text
    /// (otherwise what is before the window is not known any more).
    private mutating func rebase(to text: String, shift: Int) {
        let old = Array(window.utf16), new = Array(text.utf16)
        var headUnits = Array(head.utf16)
        if shift < 0 {
            if -shift <= old.count { headUnits += old[0..<(-shift)] } else { headUnits = [] }
        } else if shift > 0 {
            // Back in the window: the kept head's end, when it is the same text; else nothing before it is known.
            if shift <= new.count, headUnits.count >= shift, headUnits.suffix(shift).elementsEqual(new[0..<shift]) {
                headUnits.removeLast(shift)
            } else {
                headUnits = []
            }
        }
        window = text
        runs = runs.map { Span(location: $0.location + shift, length: $0.length) }
        touched = touched.map { Span(location: $0.location + shift, length: $0.length) }
        // Only as far back as the oldest span that needs it, within the limit.
        let needed = max(0, -((runs + touched).map(\.location).min() ?? 0))
        let kept = min(needed, headLimit, headUnits.count)
        head = String(decoding: headUnits.suffix(kept), as: UTF16.self)
        if runs.contains(where: { $0.location < -kept || $0.end > new.count }) { lostRunText = true }
    }

    private mutating func fold(_ step: EditStep, run: Bool, user: Bool) {
        var units = Array(window.utf16)
        guard step.span.location >= 0, step.span.length >= 0, step.span.end <= units.count else { return }
        units.replaceSubrange(step.span.location..<step.span.end, with: step.text.utf16)
        window = String(decoding: units, as: UTF16.self)
        runs = runs.map { Self.mapped($0, through: step) }
        touched = touched.map { Self.mapped($0, through: step) }
        let result = Span(location: step.span.location, length: step.text.utf16.count)
        if run, result.length > 0 { runs = Self.merged(runs + [result]) }
        if user { touched.append(result) }
    }

    /// Each run span and the user-touched spans inside it, found again in `text` after a resync or reset: a span
    /// only when its last known text occurs exactly once there; the others are dropped (`CleanupAgent`'s rule).
    private func reanchored(in text: String) -> (runs: [Span], touched: [Span]) {
        let old = known as NSString, new = text as NSString, base = headLength
        var kept: [Span] = [], inside: [Span] = []
        // A span whose text is not all known (part of it left the window unkept) is not searched for.
        for run in runs where run.length > 0 && run.location >= -base && run.end <= window.utf16.count {
            let known = old.substring(with: NSRange(location: run.location + base, length: run.length))
            var found: [Int] = []
            var from = 0
            while from < new.length, found.count < 2 {
                let hit = new.range(of: known, options: [.literal], range: NSRange(location: from, length: new.length - from))
                guard hit.location != NSNotFound else { break }
                found.append(hit.location)
                from = hit.location + 1
            }
            guard found.count == 1, let location = found.first else { continue }
            let shift = location - run.location
            kept.append(Span(location: location, length: run.length))
            for span in touched {
                if span.length == 0 {
                    if span.location > run.location && span.location < run.end { inside.append(Span(location: span.location + shift, length: 0)) }
                    continue
                }
                let start = max(span.location, run.location), end = min(span.end, run.end)
                if start < end { inside.append(Span(location: start + shift, length: end - start)) }
            }
        }
        return (Self.merged(kept), inside)
    }

    /// `span` after `step`: unchanged before it, shifted after it, grown or shrunk around it when they overlap.
    static func mapped(_ span: Span, through step: EditStep) -> Span {
        let start = step.span.location, end = step.span.end, delta = step.text.utf16.count - step.span.length
        if span.end <= start { return span }
        if span.location >= end { return Span(location: span.location + delta, length: span.length) }
        let location = min(span.location, start)
        return Span(location: location, length: max(span.end, end) + delta - location)
    }

    static func merged(_ spans: [Span]) -> [Span] {
        var out: [Span] = []
        for span in spans.sorted(by: { $0.location < $1.location }) {
            if let last = out.last, span.location <= last.end {
                out[out.count - 1] = Span(location: last.location, length: max(last.end, span.end) - last.location)
            } else {
                out.append(span)
            }
        }
        return out
    }

    // MARK: Reading

    private var headLength: Int { head.utf16.count }
    /// ``head`` and the window: the field's text as known, from window offset `-headLength` on.
    private var known: String { head + window }

    /// The run's text as the field shows it: from the start of its first span to the end of its last (what the
    /// user wrote in between included, the part in ``head`` too), trimmed; nil when nothing is the run's, or not
    /// all of it is known.
    public var runText: String? {
        guard let region = runRegion, region.location >= -headLength else { return nil }
        return Self.trimmedText(Span(location: region.location + headLength, length: region.length), in: known).text
    }

    /// The run's spans' extent in window offsets (negative where it left the window); nil when nothing is the
    /// run's, its end is past the window, or it ends before it.
    private var runRegion: Span? {
        guard let first = runs.first, let last = runs.last, last.end <= window.utf16.count, last.end > first.location
        else { return nil }
        return Span(location: first.location, length: last.end - first.location)
    }

    /// The edit that turns the run's text from `raw` into `cleaned` in the field, as the smallest patches (one step
    /// per changed stretch of words, each trimmed to the Characters that differ), in one transaction based on the
    /// newest version. Nil when the field does not show exactly `raw` as the run's text (the user changed it, it was
    /// sent, nothing is attributed to the run, or part of it is out of the window), or nothing changes.
    public func patch(from raw: String, to cleaned: String, owner: String, origin: EditOrigin = .finalSwap) -> EditTransaction? {
        guard let plan = patches(from: raw, to: cleaned, owner: owner, origin: origin), plan.outOfWindow == 0 else { return nil }
        return plan.transaction
    }

    /// ``patches(from:to:owner:origin:)``: the patches the window shows, and how many there are in all.
    public struct PatchPlan: Sendable, Equatable {
        /// The patches inside the window, in one transaction (nil: none of them is).
        public var transaction: EditTransaction?
        /// Every patch between the raw and the cleaned text.
        public var patches: Int
        /// The patches outside the window (in the run's head): never written.
        public var outOfWindow: Int
    }

    /// The smallest patches from `raw` to `cleaned` for the run's text, split by the window: the ones inside it,
    /// to be written (each step's `expect` its guard), and how many lie outside it, which are not. The run's place
    /// is its spans' offsets as the feed moved them; where the head's text is not known, the visible tail is the
    /// guard (`raw` must end with it, and fill the run's extent), never a search. Nil when there is no such edit
    /// (``unpatchable(raw:)`` says why) or nothing changes.
    public func patches(from raw: String, to cleaned: String, owner: String, origin: EditOrigin = .finalSwap) -> PatchPlan? {
        let raw = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let session, !cleaned.isEmpty, cleaned != raw, case .success(let start) = locate(raw) else { return nil }
        let steps = TextPatches.steps(from: raw, to: cleaned, at: start)
        guard !steps.isEmpty else { return nil }
        let visible = steps.filter { $0.span.location >= 0 && $0.matches(window) }
        let transaction = visible.isEmpty
            ? nil : EditTransaction(origin: origin, owner: owner, base: version, steps: visible, session: session)
        return PatchPlan(transaction: transaction, patches: steps.count, outOfWindow: steps.count - visible.count)
    }

    /// Why ``patch(from:to:owner:origin:)`` has no edit for `raw` (nil: it has one, or nothing changes).
    public enum Unpatchable: String, Sendable, Equatable, Error {
        /// Nothing was read from the keyboard.
        case noFeed
        /// The field was cleared (a send) and nothing of the run is in it.
        case cleared
        /// Nothing in the field is attributed to the run.
        case noRunText
        /// None of the run's text is in the caret-relative window, or where it is cannot be told: a step outside
        /// the window is never written.
        case outOfWindow
        /// The user wrote or changed text inside the run's.
        case userEdited
        /// The field shows other text as the run's than `raw`.
        case textDiffers
    }

    /// Why there are no patches for `raw` in the field as it is: see ``Unpatchable``.
    public func unpatchable(raw: String) -> Unpatchable? {
        if case .failure(let reason) = locate(raw.trimmingCharacters(in: .whitespacesAndNewlines)) { return reason }
        return nil
    }

    /// The most whitespace the run's extent may hold before `raw` where the head is not known (a separator).
    private static let leadingSlack = 2

    /// Where `raw` (trimmed) starts in window offsets, as the run's text the field holds.
    private func locate(_ raw: String) -> Swift.Result<Int, Unpatchable> {
        guard session != nil else { return .failure(.noFeed) }
        guard let region = runRegion else {
            return .failure(wasCleared ? .cleared : lostRunText || !runs.isEmpty ? .outOfWindow : .noRunText)
        }
        if touched.contains(where: { Self.touches($0, region) }) { return .failure(.userEdited) }
        if region.location >= -headLength {
            // All of it is known: it must be exactly `raw`.
            let shown = Self.trimmedText(Span(location: region.location + headLength, length: region.length), in: known)
            guard shown.text == raw else {
                return .failure(lostRunText || (raw.hasSuffix(shown.text) && !shown.text.isEmpty) ? .outOfWindow : .textDiffers)
            }
            return .success(shown.location - headLength)
        }
        // Only the tail is known (from the head's kept start on): `raw` ends with it and fills the run's extent.
        let units = Array(known.utf16)
        var end = region.end + headLength
        while end > 0, let scalar = Unicode.Scalar(units[end - 1]), scalar.properties.isWhitespace { end -= 1 }
        let tail = units[0..<max(end, 0)]
        guard tail.contains(where: { unit in Unicode.Scalar(unit).map { !$0.properties.isWhitespace } ?? true }) else {
            return .failure(.outOfWindow)
        }
        let rawUnits = Array(raw.utf16)
        guard rawUnits.count >= tail.count, rawUnits.suffix(tail.count).elementsEqual(tail) else { return .failure(.textDiffers) }
        let start = end - headLength - rawUnits.count
        guard start >= region.location, start - region.location <= Self.leadingSlack else { return .failure(.textDiffers) }
        return .success(start)
    }

    /// `current` (the run's text) with each unapplied edit's steps applied where they are now: mapped from the
    /// edit's base through everything that landed since (edge shifts included); a step whose range is gone, or
    /// whose expected text is not there any more, is left out. For a clipboard fallback; nil when the run's text
    /// is not all known.
    public func text(applying unapplied: [EditTransaction]) -> String? {
        guard let region = runRegion, region.location >= -headLength else { return nil }
        var steps: [EditStep] = []
        for transaction in unapplied {
            var mapped = transaction.steps
            for change in changes where change.version > transaction.base {
                switch change.change {
                case .shift(let shift):
                    mapped = mapped.map { EditStep(span: Span(location: $0.span.location + shift, length: $0.span.length), text: $0.text, expect: $0.expect) }
                case .steps(let landed):
                    for landed in landed {
                        let map = StepMap(landed)
                        mapped = mapped.compactMap { step in
                            guard case .moved(let span) = map.map(step.span) else { return nil }
                            return EditStep(span: span, text: step.text, expect: step.expect)
                        }
                    }
                }
            }
            steps += mapped
        }
        let base = headLength
        var units = Array(known.utf16)
        var end = region.end + base
        for step in steps.sorted(by: { $0.span.location > $1.span.location }) {
            let location = step.span.location + base
            guard step.span.location >= region.location, location + step.span.length <= end,
                String(decoding: units[location..<(location + step.span.length)], as: UTF16.self) == step.expect
            else { continue }
            units.replaceSubrange(location..<(location + step.span.length), with: Array(step.text.utf16))
            end += step.text.utf16.count - step.span.length
        }
        let text = String(decoding: units, as: UTF16.self)
        return Self.trimmedText(Span(location: region.location + base, length: end - region.location - base), in: text).text
    }

    private static func touches(_ touched: Span, _ region: Span) -> Bool {
        if touched.length == 0 { return touched.location > region.location && touched.location < region.end }
        return touched.location < region.end && touched.end > region.location
    }

    /// The text of `span` in `text` without its surrounding whitespace, and where that starts.
    private static func trimmedText(_ span: Span, in text: String) -> (text: String, location: Int) {
        let ns = text as NSString
        let range = NSIntersectionRange(NSRange(location: span.location, length: span.length), NSRange(location: 0, length: ns.length))
        let body = ns.substring(with: range)
        let leading = body.prefix(while: \.isWhitespace)
        return (body.trimmingCharacters(in: .whitespacesAndNewlines), range.location + leading.utf16.count)
    }
}

/// The smallest patches between two versions of a text: a word-level diff (words and the whitespace between them
/// as tokens, longest common subsequence), each changed stretch then trimmed to the Characters that differ
/// (``ContiguousPatch``). A correction of two words far apart is two small steps, not one that rewrites
/// everything between them.
public enum TextPatches {
    /// Steps (UTF-16, `at` the offset of `old` in the field), sorted by location, non-overlapping.
    public static func steps(from old: String, to new: String, at offset: Int) -> [EditStep] {
        let a = tokens(old), b = tokens(new)
        // Long texts: one contiguous patch (the diff is quadratic).
        guard a.count * b.count <= 250_000 else {
            return ContiguousPatch.between(old, new, at: offset).map { [$0] } ?? []
        }
        var lcs = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in stride(from: a.count - 1, through: 0, by: -1) {
            for j in stride(from: b.count - 1, through: 0, by: -1) {
                lcs[i][j] = a[i] == b[j] ? lcs[i + 1][j + 1] + 1 : max(lcs[i + 1][j], lcs[i][j + 1])
            }
        }
        var steps: [EditStep] = []
        var i = 0, j = 0, position = offset
        var hunkStart: Int?, removed = "", inserted = ""
        func close() {
            if let start = hunkStart, let step = ContiguousPatch.between(removed, inserted, at: start) { steps.append(step) }
            hunkStart = nil
            removed = ""
            inserted = ""
        }
        while i < a.count || j < b.count {
            if i < a.count, j < b.count, a[i] == b[j] {
                close()
                position += a[i].utf16.count
                i += 1
                j += 1
            } else if j < b.count, i == a.count || lcs[i][j + 1] >= lcs[i + 1][j] {
                if hunkStart == nil { hunkStart = position }
                inserted += b[j]
                j += 1
            } else {
                if hunkStart == nil { hunkStart = position }
                removed += a[i]
                position += a[i].utf16.count
                i += 1
            }
        }
        close()
        return steps
    }

    /// Runs of non-whitespace and runs of whitespace, in order.
    static func tokens(_ text: String) -> [String] {
        var out: [String] = []
        var current = ""
        var space: Bool?
        for character in text {
            let isSpace = character.isWhitespace
            if space != nil, space != isSpace {
                out.append(current)
                current = ""
            }
            current.append(character)
            space = isSpace
        }
        if !current.isEmpty { out.append(current) }
        return out
    }
}
