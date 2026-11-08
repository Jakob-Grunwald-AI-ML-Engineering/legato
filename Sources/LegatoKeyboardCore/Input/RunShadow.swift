import Foundation

/// The keyboard's model of what a live dictation run typed into the field, and the planner that brings it to
/// the app's target text (`LiveDictationSnapshot`). Pure: the keyboard feeds it the snapshot and the field's
/// text before the cursor, and carries out the `ShadowOp`s it returns.
///
/// - Lazy shadow: no walking and no full-field read. The *region* is the text Legato typed since the run began (or
///   since the last freeze) and ends at the cursor; the *anchor* is what the field held before it (seeded from
///   `documentContextBeforeInput`). Text after the cursor is never touched, so it is never read.
/// - Edit queue: every change goes out as single ops (`ShadowOp`), one in flight at a time. After each op the field's
///   report must confirm it (`confirms`: the text before the cursor, and after it where the op left region text
///   there) before the next op goes; the host reports late (Safari answers a move or a delete a moment later, with
///   the text before the cursor wherever it was on its way). A snapshot that arrives while the queue is busy is not
///   diffed: the newest one is diffed against the shadow once the queue is empty (older ones are dropped, never replayed).
/// - Appends (the target only grows the region) go out a slice at a time through `TypewriterDrain`, a slice per
///   confirmed op. A flip while the take runs (Soniox revising a word, a changed head) is a character-level diff
///   (`ShadowEditPlanner`, `characters`): the cursor moves to the first character that differs, only the differing
///   characters are deleted, the new ones go in one per op at least `flipCharMs` apart, and the cursor returns to the
///   end of the region. The cleaned take at the end (a complete snapshot) is a word-level diff, back to front.
/// - Drift: a report that does not confirm within `confirmLimitMs`, or a selection, means the user moved on (or the
///   host lost an op): everything typed so far is frozen, the rest of the queue is dropped, and the run goes on
///   appending at the cursor once the field's report has stopped changing, so the separator and capital are judged
///   against the text that really is there.
/// - Frozen text is never edited again. Changes the target makes to a frozen sentence are dropped, except growth
///   of a sentence that was still being spoken: what follows the frozen part is appended at the cursor.
public struct RunShadow: Sendable, Equatable {
    public enum FreezeCause: String, Sendable { case keystroke, cursor, selection, drift, field }

    public struct Step: Sendable, Equatable {
        public var ops: [ShadowOp] = []
        /// The region changed text it had already typed (a flip or a cleanup), not only grew.
        public var rewrote = false
        public var insertedChars = 0
        public var deletedChars = 0
        /// Set when this step froze the region (drift, or a selection).
        public var froze: FreezeCause?
        /// Why a drift was declared: lengths and character kinds only, never text.
        public var driftDetail: String?
        /// Set on the step that types the first characters of a region: what it was anchored to (lengths and kinds only).
        public var startDetail: String?
        /// The field's context does not confirm the last op yet: nothing was done, call again.
        public var waiting = false
        /// This step began a wait for the field to confirm an op.
        public var waitStarted = false
        /// The field did not confirm within `confirmLimitMs` (the step froze).
        public var confirmTimedOut = false
        /// Snapshots dropped undiffed because a newer one arrived while the queue was busy.
        public var coalesced = 0
        /// The field shows the whole target of `version` (and nothing was left to type).
        public var applied = false
        public var version: Int?
        /// More steps are needed: text is left to reveal, ops are queued, or the field has to confirm the last one.
        public var needsTicks = false
    }

    public let runID: String
    /// What the field held before the region (context before the cursor when the region began).
    public private(set) var anchor = ""
    /// What Legato typed since, still editable; the cursor sits at its end.
    public private(set) var region = ""
    /// Ready to be seeded from the field at the next step (a new run, or right after a freeze).
    private var reseed = true
    private var waitedMs = 0.0
    private var confirming = false
    /// The edit queue: ops of the edit in progress not sent yet.
    private var queue: [ShadowOp] = []
    /// The queue is a flip typed at typewriter pace: an insert follows an insert only `flipCharMs` after it.
    private var paced = false
    private var sinceSendMs = 0.0
    private var lastSentInsert = false
    /// The region's part of the field as the shadow expects it after the last op sent (it may end in a space Legato
    /// put after the region), and the cursor in it (UTF-16).
    private var work = ""
    private var workCursor = 0
    /// The version the edit in progress brings the field to, and whether the region then holds all of it.
    private var inFlightVersion: Int?
    private var inFlightWhole = false
    /// A version seen while the queue was busy and not diffed yet.
    private var heldVersion: Int?
    /// The target the region is being brought to (the last one diffed).
    private var target = ""
    /// After a freeze: the field's report must hold still for `stableMs` before it seeds the new anchor.
    private var settling: Bool
    private var lastReport: String?
    private var stableForMs = 0.0
    private var frozen: [Int: Frozen] = [:]
    private var built = Built()
    /// The character after the cursor where the region began.
    private var following: Character?
    private static let closingMarks: Set<Character> = [",", ".", ";", ":", "!", "?", ")", "]", "}", "%", "…", "\u{2019}", "\u{201D}"]

    /// `settlesFirst`: the run starts typing only once the field's report has held still for `stableMs`. Right after a
    /// tap or a focus the host can still report the text before the cursor as it was a moment ago (a missing trailing
    /// space would then be added again).
    public init(runID: String, settlesFirst: Bool = false) { self.runID = runID; settling = settlesFirst }

    /// What a sentence (by segment id) already has in the field and may not be edited any more.
    struct Frozen: Equatable, Sendable {
        var text: String
        /// The whole sentence was typed and it was final: nothing of it is typed again.
        var closed: Bool
    }
    /// The last target built: its text and where each segment sits in it.
    struct Built: Equatable, Sendable {
        struct Span: Equatable, Sendable {
            var id: Int
            var text: String
            var final: Bool
            var start: Int
            /// The span continues a frozen, half-typed word: no separator in front of it.
            var continuation: Bool
            /// The span holds a cleaned unit's text: the ids of the unit's other (empty) segments.
            var members: [Int] = []
        }
        var spans: [Span] = []
        /// Characters of separator and the like the prepared text has before the spans' text.
        var prefix = 0
    }

    public var frozenSegments: Int { frozen.count }

    /// How long the field's report may take to confirm an op before it counts as the user's edit (drift).
    public static let confirmLimitMs = 800.0
    /// How long the report must stay unchanged after a freeze before the run types again.
    public static let stableMs = 150.0
    /// The typewriter pace of a flip's characters.
    public static let flipCharMs = 30.0

    /// Ops are queued: a new snapshot waits until they went out.
    public var isBusy: Bool { !queue.isEmpty }
    /// What the field should report before and after the cursor once it shows the last op sent (after: only the
    /// region's own text there).
    public var expectedBefore: String { anchor + String(decoding: Array(work.utf16.prefix(workCursor)), as: UTF16.self) }
    public var expectedAfter: String { String(decoding: Array(work.utf16.dropFirst(workCursor)), as: UTF16.self) }

    /// Whether the field's report shows what the shadow expects. Before the cursor a suffix match counts (hosts trim
    /// their context). After it, the report must start with the region's text there, or be a trimmed part of it; a
    /// host that reports nothing after the cursor must at least not report text past it (a report from before a move).
    static func confirms(expectedBefore: String, expectedAfter: String, reportedBefore: String, reportedAfter: String) -> Bool {
        guard OwnEditEcho.isSame(expected: expectedBefore, reported: reportedBefore) else { return false }
        guard !expectedAfter.isEmpty else { return true }
        if reportedAfter.isEmpty { return reportedBefore.count <= expectedBefore.count }
        return reportedAfter.hasPrefix(expectedAfter) || expectedAfter.hasPrefix(reportedAfter)
    }

    // MARK: Step

    /// - Parameters:
    ///   - contextBefore: where the region would start now (the keyboard's tracked context, which includes its
    ///     own latest edit); used to seed the anchor and to place the first slice.
    ///   - reportedBefore, reportedAfter: the field's own report around the cursor, which lags behind edits; the
    ///     confirmation reads it.
    ///   - flush: the keyboard goes away: no waiting, everything left goes out now (unless the field disagrees).
    ///   - followingCharacter: the character right after the cursor (`documentContextAfterInput`), read only where
    ///     the run begins typing: text that follows without a space gets one from the run's first insert.
    public mutating func step(
        snapshot: LiveDictationSnapshot, contextBefore: String, reportedBefore: String, reportedAfter: String = "",
        hasSelection: Bool, capitalization: AutoCapitalizationType, elapsedMs: Double, animated: Bool, flush: Bool = false,
        followingCharacter: Character? = nil
    ) -> Step {
        var step = Step()
        if hasSelection {
            // Typing would replace the selection: the user took over.
            if freeze(.selection) { step.froze = .selection }
            step.needsTicks = true
            return step
        }
        if settling {
            if reportedBefore == lastReport { stableForMs += elapsedMs } else { lastReport = reportedBefore; stableForMs = 0 }
            if stableForMs < Self.stableMs { step.waiting = true; step.needsTicks = true; return step }
            settling = false
            seed(reportedBefore, following: followingCharacter)
        } else if queue.isEmpty, reseed || region.isEmpty { seed(contextBefore, following: followingCharacter) }
        else if !Self.confirms(expectedBefore: expectedBefore, expectedAfter: expectedAfter, reportedBefore: reportedBefore, reportedAfter: reportedAfter) {
            // No time to wait when flushing, and nothing is typed over a field that does not show what is expected.
            if flush { step.waiting = true; return step }
            if !confirming { confirming = true; step.waitStarted = true }
            waitedMs += elapsedMs
            if waitedMs < Self.confirmLimitMs { step.waiting = true; step.needsTicks = true; return step }
            let expected = expectedBefore
            step.driftDetail = Self.describeMismatch(expected: expected, reported: reportedBefore)
            // The report shows the text up to somewhere earlier in what was typed: the cursor moved, the text is as it was.
            let cause: FreezeCause = Self.cursorMoved(expected: expected, reported: reportedBefore) ? .cursor : .drift
            _ = freeze(cause)
            step.froze = cause; step.confirmTimedOut = true
            step.waiting = true; step.needsTicks = true
            return step
        } else {
            waitedMs = 0; confirming = false
        }
        sinceSendMs += elapsedMs

        if !queue.isEmpty {
            // Busy: a newer snapshot is only noted; the newest is diffed once the queue is empty.
            if snapshot.version != inFlightVersion, snapshot.version != heldVersion {
                if heldVersion != nil { step.coalesced += 1 }
                heldVersion = snapshot.version
            }
            send(&step, flush: flush)
            guard flush else { return step }
            while !queue.isEmpty { send(&step, flush: true) }
        }
        heldVersion = nil

        let target = prepared(snapshot, capitalization: capitalization)
        // A target without any words never erases what is typed, unless the cleaned take dropped every word (all filler).
        let dropsAll = snapshot.complete && !snapshot.segments.isEmpty && snapshot.segments.allSatisfy { $0.final && $0.cleaned }
        if target == region || (target.isEmpty && !dropsAll) {
            step.applied = true; step.version = snapshot.version
            return step
        }
        inFlightVersion = snapshot.version
        if target.hasPrefix(region) {
            let revealed = region.count, total = target.count
            let next = animated ? TypewriterDrain.step(revealed: revealed, target: total, dtMs: elapsedMs) : total
            let slice = String(target.dropFirst(revealed).prefix(next - revealed))
            if region.isEmpty {
                step.startDetail = "anchor=\(anchor.count) endsSpace=\(anchor.last?.isWhitespace == true ? 1 : 0) reported=\(reportedBefore.count) reportedEndsSpace=\(reportedBefore.last?.isWhitespace == true ? 1 : 0) following=\(following.map { $0.isWhitespace ? "space" : "char" } ?? "none") first=\(slice.first?.isWhitespace == true ? "space" : "char")"
            }
            if region.isEmpty, let next = following, !next.isWhitespace, !Self.closingMarks.contains(next) {
                // The run starts in front of text that follows without a space: one goes in behind it, once, and the
                // cursor stays in front of that space, so the run keeps typing where it is.
                queue = [.insert(slice + " "), .move(-1)]
            } else {
                queue = [.insert(slice)]
            }
            paced = false
            region += slice
            inFlightWhole = region == target; self.target = target
        } else {
            // A flip while the take runs is typed character by character; the cleaned take at the end goes in by words.
            paced = !snapshot.complete; lastSentInsert = false
            queue = ShadowEditPlanner.plan(shadow: region, cursor: region.utf16.count, target: target, characters: paced).ops
            step.rewrote = true
            region = target; inFlightWhole = true; self.target = target
        }
        send(&step, flush: flush)
        if flush { while !queue.isEmpty { send(&step, flush: true) } }
        return step
    }

    /// A key of this keyboard is about to freeze the run (`freeze(.keystroke)`) while the typewriter has revealed only
    /// part of a word: the op that types the rest of it first (with marks stuck to it, and a space when `key` starts
    /// with a letter or digit), so the key lands after the word. Nil when nothing is cut off, ops are queued, or the
    /// field does not confirm the last op.
    public mutating func finishWord(beforeKey key: String, reportedBefore: String, reportedAfter: String) -> ShadowOp? {
        guard queue.isEmpty, !settling, let last = region.last, last.isLetter || last.isNumber,
              target.count > region.count, target.hasPrefix(region),
              Self.confirms(expectedBefore: expectedBefore, expectedAfter: expectedAfter, reportedBefore: reportedBefore, reportedAfter: reportedAfter)
        else { return nil }
        var rest = String(target.dropFirst(region.count).prefix { !$0.isWhitespace })
        guard let first = rest.first, first.isLetter || first.isNumber else { return nil }
        if let k = key.first, k.isLetter || k.isNumber { rest += " " }
        (work, workCursor) = ShadowEditPlanner.simulate(ops: [.insert(rest)], shadow: work, cursor: workCursor)
        region += rest
        return .insert(rest)
    }

    /// Takes a new anchor at the cursor; the region starts empty there.
    private mutating func seed(_ before: String, following next: Character?) {
        anchor = before; reseed = false; waitedMs = 0; confirming = false; following = next
        work = ""; workCursor = 0
    }

    /// Sends the next queued op: the shadow's model of the field moves on, and the field has to confirm it. A flip's
    /// insert right after an insert waits for `flipCharMs` (the typewriter pace), unless flushing.
    private mutating func send(_ step: inout Step, flush: Bool = false) {
        guard let next = queue.first else { return }
        if paced, !flush, lastSentInsert, case .insert = next, sinceSendMs < Self.flipCharMs {
            step.needsTicks = true
            return
        }
        let op = queue.removeFirst()
        sinceSendMs = 0
        if case .insert = op { lastSentInsert = true } else { lastSentInsert = false }
        (work, workCursor) = ShadowEditPlanner.simulate(ops: [op], shadow: work, cursor: workCursor)
        switch op {
        case .deleteBackward(let count): step.deletedChars += count
        case .insert(let text): step.insertedChars += text.count
        case .move: break
        }
        step.ops.append(op)
        step.needsTicks = true
        if queue.isEmpty, inFlightWhole, let version = inFlightVersion { step.applied = true; step.version = version }
    }

    /// The user took over (a key, a cursor move, another field): what is typed so far stays as it is. Returns
    /// whether anything was frozen. The next step seeds a new anchor at the cursor.
    @discardableResult
    public mutating func freeze(_ cause: FreezeCause) -> Bool {
        defer {
            reseed = true; region = ""; waitedMs = 0; confirming = false; built = Built(); settling = true; lastReport = nil; stableForMs = 0
            queue = []; work = ""; workCursor = 0; inFlightVersion = nil; heldVersion = nil; paced = false; lastSentInsert = false
        }
        guard !region.isEmpty else { return false }
        let typed = max(0, region.count - built.prefix)
        for span in built.spans {
            let count = min(span.text.count, max(0, typed - span.start))
            guard count > 0 else { continue }
            let part = String(span.text.prefix(count))
            let known = frozen[span.id]
            let joined = known.map { $0.text + (span.continuation ? "" : " ") + part } ?? part
            let closed = count == span.text.count && span.final
            frozen[span.id] = Frozen(text: joined, closed: closed)
            // A cleaned unit typed whole is closed with all its segments: their raw words are in its text, never typed again.
            if closed { for member in span.members { frozen[member] = Frozen(text: "", closed: true) } }
        }
        return true
    }

    /// What of a sentence still has to be typed after its frozen part. A frozen part that ends inside a word leaves that
    /// fragment where it is (the cursor is no longer there): the whole word is typed again with what follows. Words after
    /// the frozen part that the sentence changed under are matched by position.
    static func unfrozenRest(of text: String, frozen: String) -> String {
        let words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        let typed = frozen.split(whereSeparator: \.isWhitespace).map(String.init)
        guard let last = typed.last, !frozen.hasSuffix(" ") else {
            return text.hasPrefix(frozen) ? String(text.dropFirst(frozen.count)).trimmingCharacters(in: .whitespaces)
                                         : words.dropFirst(typed.count).joined(separator: " ")
        }
        // The frozen part ends in `last`: if the sentence's word there is longer, it was cut off; only its first
        // characters are in the field (cleanup may have changed its case since).
        guard typed.count <= words.count else { return "" }
        let word = words[typed.count - 1]
        var rest = Array(words.dropFirst(typed.count))
        if word.lowercased().hasPrefix(last.lowercased()), word.count > last.count {
            let tail = word.dropFirst(last.count)
            // A word that goes on is typed whole; punctuation stuck to a finished word is not typed on its own.
            if let first = tail.first, first.isLetter || first.isNumber { rest.insert(word, at: 0) }
        }
        return rest.joined(separator: " ")
    }

    /// Whether the report is the shadow's text up to a point before its end, which is what the host reports when the
    /// cursor sits there: the user tapped into what was typed.
    static func cursorMoved(expected: String, reported: String) -> Bool {
        guard !reported.isEmpty, reported != expected, let range = expected.range(of: reported) else { return false }
        return range.upperBound < expected.endIndex
    }

    /// Where the field's report and the shadow part ways, without any text: both lengths, how many characters
    /// agree at the end, whether they agree once whitespace is normalised, and the kinds of the first characters that differ.
    static func describeMismatch(expected: String, reported: String) -> String {
        let e = Array(expected), r = Array(reported)
        var common = 0
        while common < min(e.count, r.count), e[e.count - 1 - common] == r[r.count - 1 - common] { common += 1 }
        func kind(_ chars: [Character], _ back: Int) -> String {
            guard back < chars.count else { return "none" }
            let c = chars[chars.count - 1 - back]
            if c == "\u{00A0}" { return "nbsp" }
            if c.isNewline { return "newline" }
            if c.isWhitespace { return "space" }
            if c.isLetter { return "letter" }
            if c.isNumber { return "digit" }
            return c.isASCII ? "punct" : "other"
        }
        func normalized(_ text: String) -> String {
            text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        }
        // The report found inside the shadow, how many characters before its end: a lagging report is an older state.
        let found = expected.range(of: reported).map { expected.distance(from: $0.upperBound, to: expected.endIndex) } ?? -1
        let ne = normalized(expected), nr = normalized(reported)
        let alike = ne.hasSuffix(nr) || nr.hasSuffix(ne)
        return "e=\(e.count) r=\(r.count) common=\(common) wsOnly=\(alike ? 1 : 0) reportInShadowFromEnd=\(found) expectedKind=\(kind(e, common)) reportedKind=\(kind(r, common)) endsSpace=\(e.last?.isWhitespace == true ? 1 : 0)/\(r.last?.isWhitespace == true ? 1 : 0)"
    }

    // MARK: Target

    /// The text the region should hold for `snapshot`: its unfrozen sentences, separated from the anchor and
    /// capitalized where the text before the cursor calls for it.
    private mutating func prepared(_ snapshot: LiveDictationSnapshot, capitalization: AutoCapitalizationType) -> String {
        var raw = ""
        var spans: [Built.Span] = []
        var continuation = false
        // A cleaned unit of several segments with a frozen part cannot be edited whole: its segments go back to their raw words.
        // (A unit frozen whole after its cleaned text was typed is closed in every segment: it is skipped either way.)
        let touched = Set(snapshot.segments.compactMap { $0.unit != nil && frozen[$0.id] != nil ? $0.unit : nil })
        for segment in snapshot.segments {
            var text = (segment.unit.map(touched.contains) == true ? segment.raw ?? segment.text : segment.text).trimmingCharacters(in: .whitespaces)
            var continues = false
            if let known = frozen[segment.id] {
                if known.closed { continue }
                text = Self.unfrozenRest(of: text, frozen: known.text)
            }
            guard !text.isEmpty else { continue }
            if raw.isEmpty { continuation = continues }
            else if let last = raw.last, !last.isWhitespace, let first = text.first, !first.isNewline, !continues { raw += " " }
            let members = segment.unit == segment.id ? snapshot.segments.filter { $0.unit == segment.id && $0.id != segment.id }.map(\.id) : []
            spans.append(.init(id: segment.id, text: text, final: segment.final, start: raw.count, continuation: continues, members: members))
            raw += text
        }
        guard !raw.isEmpty else { built = Built(spans: [], prefix: 0); return "" }
        let result = continuation ? raw : DictationTypist.prepare(raw, contextBefore: anchor, capitalization: capitalization)
        // `prepare` may put a separator in front (never changes the length otherwise).
        built = Built(spans: spans, prefix: result.count - raw.count)
        return result
    }
}
