import Foundation
import LegatoFieldEdit

/// The app's copy of the keyboard's field, folded from its change feed (`link.feed` on iOS): the confirmed
/// window, the version and queue instance new edits are based on, which text the run wrote, and what happened to
/// the edits the app sent. Pure value type; ``LinkedCleanupRun`` keeps one per run.
///
/// The run's text is only what the feed attributes to an automatic write (`applied` with a non-user origin since
/// the last reset); user text and foreign changes are never the run's. A reset, or a resync from another queue
/// instance, forgets it: nothing is the run's until new automatic text lands.
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
    private var lastSeq = 0
    /// The changes that landed since the last reset, with the version each left: for mapping an edit's steps from
    /// its base to the field now.
    private var changes: [(version: FieldVersion, steps: [EditStep])] = []

    public init() {}

    public static func == (a: FeedMirror, b: FeedMirror) -> Bool {
        a.window == b.window && a.version == b.version && a.session == b.session && a.runs == b.runs
            && a.touched == b.touched && a.results == b.results && a.lastSeq == b.lastSeq
    }

    /// Whether anything has been read yet.
    public var isEmpty: Bool { session == nil }

    // MARK: Folding

    public mutating func fold(_ batch: FeedBatch) {
        if batch.resync || batch.session != session {
            guard batch.resync, let text = batch.window else { return }  // another queue, no window: wait
            if batch.session != session || text != window {
                runs = []
                touched = []
                changes = []
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
            changes.append((version, steps))
        case .foreign(let step, let byUser, let version):
            fold(step, run: false, user: byUser)
            changes.append((version, [step]))
        case .conflict(let id, let conflict):
            results[id] = .conflict(conflict)
        case .superseded(let id, _):
            results[id] = .superseded
        case .withdrawn(let id):
            results[id] = .withdrawn
        case .rebased(let text, let shift, _):
            window = text
            runs = runs.map { Span(location: $0.location + shift, length: $0.length) }
            touched = touched.map { Span(location: $0.location + shift, length: $0.length) }
            changes = []  // offsets before the shift are not mapped across it
        case .reset(let reason, let text, _):
            window = text
            runs = []
            touched = []
            changes = []
            if reason == .cleared { wasCleared = true }
        }
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

    /// The run's text as the field shows it: from the start of its first span to the end of its last (what the
    /// user wrote in between included), trimmed; nil when nothing is the run's.
    public var runText: String? {
        guard let region = runRegion else { return nil }
        return Self.trimmedText(region, in: window).text
    }

    private var runRegion: Span? {
        guard let first = runs.first, let last = runs.last else { return nil }
        let length = (window as NSString).length
        let start = min(first.location, length), end = min(last.end, length)
        return end > start ? Span(location: start, length: end - start) : nil
    }

    /// The edit that turns the run's text from `raw` into `cleaned` in the field, as the smallest patches (one step
    /// per changed stretch of words, each trimmed to the Characters that differ), in one transaction based on the
    /// newest version. Nil when the field does not show exactly `raw` as the run's text (the user changed it, it was
    /// sent, or nothing is attributed to the run), or nothing changes.
    public func patch(from raw: String, to cleaned: String, owner: String, origin: EditOrigin = .finalSwap) -> EditTransaction? {
        guard let session, let region = runRegion, touched.allSatisfy({ !Self.touches($0, region) }) else { return nil }
        let shown = Self.trimmedText(region, in: window)
        let raw = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        guard shown.text == raw, !cleaned.isEmpty, cleaned != raw else { return nil }
        let steps = TextPatches.steps(from: raw, to: cleaned, at: shown.location)
        guard !steps.isEmpty else { return nil }
        return EditTransaction(origin: origin, owner: owner, base: version, steps: steps, session: session)
    }

    /// `current` (the run's text) with each unapplied edit's steps applied where they are now: mapped from the
    /// edit's base through everything that landed since; a step whose range is gone, or whose expected text is
    /// not there any more, is left out. For a clipboard fallback.
    public func text(applying unapplied: [EditTransaction]) -> String? {
        guard let region = runRegion else { return nil }
        var steps: [EditStep] = []
        for transaction in unapplied {
            var mapped = transaction.steps
            for change in changes where change.version > transaction.base {
                for landed in change.steps {
                    let map = StepMap(landed)
                    mapped = mapped.compactMap { step in
                        guard case .moved(let span) = map.map(step.span) else { return nil }
                        return EditStep(span: span, text: step.text, expect: step.expect)
                    }
                }
            }
            steps += mapped
        }
        var units = Array(window.utf16)
        var end = region.end
        for step in steps.sorted(by: { $0.span.location > $1.span.location }) {
            guard step.span.location >= region.location, step.span.end <= end, step.span.end <= units.count,
                String(decoding: units[step.span.location..<step.span.end], as: UTF16.self) == step.expect
            else { continue }
            units.replaceSubrange(step.span.location..<step.span.end, with: Array(step.text.utf16))
            end += step.text.utf16.count - step.span.length
        }
        let text = String(decoding: units, as: UTF16.self)
        return Self.trimmedText(Span(location: region.location, length: end - region.location), in: text).text
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
