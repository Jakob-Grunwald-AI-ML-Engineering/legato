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
///   confirmed op. A flip while the take runs (Soniox revising a word, a changed head) never moves the cursor: a change
///   that starts within the last `flipRetypeChars` characters is erased back to its first character and typed again,
///   one character per op at least `flipCharMs` apart; a change further back is left for the cleaned take.
/// - The cleaned take at the end (a complete snapshot) is retyped from its first change (deleted back from the end,
///   the rest inserted whole) up to `cleanupRetypeChars`; only a longer one goes by words with cursor moves, back to
///   front. If that one freezes, the cursor goes back to the end of the run when the report pins where it is.
/// - Confirmation pins the cursor: the report must fit the shadow at the expected position and nowhere else (a web
///   view's few words before the cursor may fit where the cursor was before a move too). A move the report never
///   showed (the cursor pinned where it was) goes out once more; a move it showed must still show a tick later. A
///   report that then keeps pinning the old place, unchanged, over `caretResetReports` reports and `caretResetMs`
///   means the page put its caret back (a lagging report shows the move again first): the run freezes and moves are
///   off for good (`avoidsMoves`: retype or leave). Anything else that does not confirm freezes at `confirmLimitMs`.
/// - Drift: a report that does not confirm within `confirmLimitMs`, or a selection, means the user moved on (or the
///   host lost an op): everything typed so far is frozen, the rest of the queue is dropped, and the run goes on
///   appending at the cursor once the field's report has stopped changing, so the separator and capital are judged
///   against the text that really is there.
/// - Frozen text is never edited again. Changes the target makes to a frozen sentence are dropped, except growth
///   of a sentence that was still being spoken: what follows the frozen part is appended at the cursor.
public struct RunShadow: Sendable, Equatable {
    /// `instruction`: an instruction's edit is about to change the text before the cursor. `caretReset`: the page put
    /// its caret back after a move.
    public enum FreezeCause: String, Sendable { case keystroke, cursor, selection, drift, field, instruction, caretReset }

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
        /// The field did not show the last move (the cursor stayed where it was): `ops` sends it once more.
        public var moveResent = false
        /// The field showed the last move, then the cursor back where it was: the page resets its caret (the step froze).
        public var caretReset = false
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
    /// The last op sent was this move, from `movedFrom` (the cursor in `work` before it): a field that shows the cursor
    /// still at `movedFrom` gets it once more.
    private var lastMove: ShadowOp?
    private var movedFrom = 0
    private var moveResent = false
    /// How long the field has shown the last move (nil: not yet).
    private var moveShownMs: Double?
    /// The same report pinning the old place after the move showed: how often, for how long.
    private var resetReport: String?
    private var resetReports = 0
    private var resetMs = 0.0
    /// The cleaned take is going in with cursor moves (a freeze then puts the cursor back at the end if it can).
    private var cleanupMoving = false
    /// The run began with a space typed behind it (text followed the cursor): `work` ends in that space.
    private var spaceAfterRegion = false
    /// No cursor moves at all: the field puts its caret back after the keyboard moved it.
    public private(set) var avoidsMoves: Bool
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
    /// `avoidsMoves`: the field is known to reset its caret (this keyboard session saw it): edits only retype at the end.
    public init(runID: String, settlesFirst: Bool = false, avoidsMoves: Bool = false) {
        self.runID = runID; settling = settlesFirst; self.avoidsMoves = avoidsMoves
    }

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
    /// How long a move may go unseen before it is sent once more (only when the report pins the cursor where it was).
    public static let moveResendMs = 400.0
    /// The cleaned take lands without cursor moves (delete back to the first change, type the rest) when that tail
    /// is this short, or the whole region is (a short take).
    /// A flip while the take runs is retyped when it starts within this many characters of the end, else left.
    public static let flipRetypeChars = 40
    /// The cleaned take is retyped from its first change up to this many characters; beyond it goes by words with
    /// moves (or, with moves off, is left as typed).
    public static let cleanupRetypeChars = 2000
    /// A caret reset needs the same report pinning the old place this many times, over at least this long.
    public static let caretResetReports = 3
    public static let caretResetMs = 150.0
    /// A move the field showed must still show this much later before the next op goes.
    public static let moveVerifyMs = 30.0

    /// Ops are queued, or the last move is not verified yet: a new snapshot waits until they went out.
    public var isBusy: Bool { !queue.isEmpty || lastMove != nil }
    /// What the field should report before and after the cursor once it shows the last op sent (after: only the
    /// region's own text there).
    public var expectedBefore: String { anchor + String(decoding: Array(work.utf16.prefix(workCursor)), as: UTF16.self) }
    public var expectedAfter: String { String(decoding: Array(work.utf16.dropFirst(workCursor)), as: UTF16.self) }

    /// Whether the field's report shows what the shadow expects, and pins the cursor there: the report must fit the
    /// known text (`expectedBefore + expectedAfter`) at the expected cursor and at no other position in it. A short
    /// window (a web view reports a few words, often nothing after the cursor) that also fits elsewhere, say where the
    /// cursor sat before a move, confirms nothing: the queue waits for a report that tells the positions apart.
    static func confirms(expectedBefore: String, expectedAfter: String, reportedBefore: String, reportedAfter: String) -> Bool {
        let before = Array(expectedBefore)
        return positions(in: before + Array(expectedAfter), reportedBefore: reportedBefore, reportedAfter: reportedAfter) == [before.count]
    }

    /// Whether the report pins the cursor at `cursor` (characters into `text`): it fits there and nowhere else.
    static func pins(text: [Character], cursor: Int, reportedBefore: String, reportedAfter: String) -> Bool {
        positions(in: text, reportedBefore: reportedBefore, reportedAfter: reportedAfter) == [cursor]
    }

    /// The reverse match (the report reaches back past the known text) needs this much known text before the cursor:
    /// a report that merely ends in the first few characters of the known text says nothing about where it is.
    static let reverseMatchChars = 12

    /// Every cursor position (characters into `text`) the field's report fits. Before the cursor the report is the
    /// known text's end there (hosts trim their context), or reaches back past the start of the known text; nothing
    /// reported before it fits only the start. After the cursor the report starts with the known text there, or is a
    /// trimmed part of it, or goes on past it (text after the region); nothing reported after it fits anywhere.
    ///
    /// A block-based host's window that starts at a block's start begins with "\n " (`FieldReader.trusted(before:)`):
    /// when the report fits nowhere as it is, its trusted part counts, at positions where a line break precedes it.
    static func positions(in text: [Character], reportedBefore: String, reportedAfter: String) -> [Int] {
        let exact = fits(in: text, reportedBefore: Array(reportedBefore), reportedAfter: Array(reportedAfter))
        let trusted = Array(FieldReader.trusted(before: reportedBefore))
        guard exact.isEmpty, trusted.count < reportedBefore.count, reportedBefore.first?.isNewline == true else { return exact }
        if trusted.isEmpty {
            // Only the boundary: the cursor is in an empty block, a line break before it and one (or the end) after it.
            guard reportedAfter.isEmpty else { return [] }
            return (1...max(1, text.count)).filter { p in
                p <= text.count && text[p - 1].isNewline && (p == text.count || text[p].isNewline)
            }
        }
        return fits(in: text, reportedBefore: trusted, reportedAfter: Array(reportedAfter)).filter { p in
            let start = p - trusted.count
            return start > 0 && text[start - 1].isNewline
        }
    }

    private static func fits(in text: [Character], reportedBefore rb: [Character], reportedAfter ra: [Character]) -> [Int] {
        func beforeFits(_ p: Int) -> Bool {
            if rb.isEmpty { return p == 0 }
            if p >= rb.count { return text[(p - rb.count)..<p].elementsEqual(rb) }
            return p >= reverseMatchChars && rb[(rb.count - p)...].elementsEqual(text[..<p])
        }
        func afterFits(_ p: Int) -> Bool {
            let n = min(ra.count, text.count - p)
            return text[p..<(p + n)].elementsEqual(ra[..<n])
        }
        return (0...text.count).filter { p in
            (rb.isEmpty || (p > 0 && text[p - 1] == rb[rb.count - 1])) && beforeFits(p) && afterFits(p)
        }
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
            let pinsOldPlace = lastMove != nil && Self.pins(
                text: Array(anchor) + Array(work), cursor: anchor.count + Self.characters(ofUTF16: movedFrom, in: work),
                reportedBefore: reportedBefore, reportedAfter: reportedAfter)
            if pinsOldPlace, moveShownMs != nil {
                // The field showed the move, and now the cursor where it was before it. A lagging report does that for
                // a moment; a page that put its caret back keeps showing it. The move must show again (and hold a tick).
                moveShownMs = 0
                let report = reportedBefore + "\u{0}" + reportedAfter
                if report == resetReport { resetReports += 1; resetMs += elapsedMs } else { resetReport = report; resetReports = 1; resetMs = 0 }
                if resetReports >= Self.caretResetReports, resetMs >= Self.caretResetMs {
                    // Nothing more goes out at a place that is not where the shadow thinks; no moves from now on.
                    avoidsMoves = true
                    step.driftDetail = Self.describeMismatch(expected: expectedBefore, reported: reportedBefore)
                    parkAtEnd(&step, reportedBefore: reportedBefore, reportedAfter: reportedAfter)
                    _ = freeze(.caretReset)
                    step.froze = .caretReset; step.caretReset = true
                    step.waiting = true; step.needsTicks = true
                    return step
                }
            } else {
                resetReport = nil; resetReports = 0; resetMs = 0
            }
            if let move = lastMove, pinsOldPlace, moveShownMs == nil, !moveResent, waitedMs >= Self.moveResendMs {
                // The field never showed the move and pins the cursor where it was: the move was lost. It goes out
                // once more; the field has to show it like the first time.
                moveResent = true; waitedMs = 0
                step.ops = [move]; step.moveResent = true
                step.waiting = true; step.needsTicks = true
                return step
            }
            if waitedMs < Self.confirmLimitMs { step.waiting = true; step.needsTicks = true; return step }
            let expected = expectedBefore
            step.driftDetail = Self.describeMismatch(expected: expected, reported: reportedBefore)
            // The report shows the text up to somewhere earlier in what was typed: the cursor moved, the text is as it was.
            let cause: FreezeCause = Self.cursorMoved(expected: expected, reported: reportedBefore) ? .cursor : .drift
            parkAtEnd(&step, reportedBefore: reportedBefore, reportedAfter: reportedAfter)
            _ = freeze(cause)
            step.froze = cause; step.confirmTimedOut = true
            step.waiting = true; step.needsTicks = true
            return step
        } else {
            waitedMs = 0; confirming = false; resetReport = nil; resetReports = 0; resetMs = 0
        }
        sinceSendMs += elapsedMs
        // A move the field shows must still show a tick later (a page may put its caret back after its input event).
        var verifying = false
        if lastMove != nil {
            moveShownMs = moveShownMs.map { $0 + elapsedMs } ?? 0
            if !flush, (moveShownMs ?? 0) < Self.moveVerifyMs { verifying = true } else {
                lastMove = nil; moveShownMs = nil
                if queue.isEmpty { cleanupMoving = false }
            }
        }

        if !queue.isEmpty || verifying {
            // Busy: a newer snapshot is only noted; the newest is diffed once the queue is empty.
            if snapshot.version != inFlightVersion, snapshot.version != heldVersion {
                if heldVersion != nil { step.coalesced += 1 }
                heldVersion = snapshot.version
            }
            if verifying { step.needsTicks = true; return step }
            send(&step, flush: flush)
            guard flush else { return step }
            while !queue.isEmpty { send(&step, flush: true) }
        }
        heldVersion = nil

        let full = prepared(snapshot, capitalization: capitalization)
        // A target without any words never erases what is typed, unless the cleaned take dropped every word (all filler).
        let dropsAll = snapshot.complete && !snapshot.segments.isEmpty && snapshot.segments.allSatisfy { $0.final && $0.cleaned }
        if full.isEmpty && !dropsAll { step.applied = true; step.version = snapshot.version; return step }
        // What the region is brought to: while the take runs, changes that start further back than `flipRetypeChars`
        // are left as typed (the cleaned take fixes them); with moves off, so is a cleaned take too long to retype.
        let target: String
        if !snapshot.complete {
            target = ShadowEditPlanner.endGoal(shadow: region, target: full, window: Self.flipRetypeChars)
        } else if avoidsMoves, ShadowEditPlanner.retypeTail(shadow: region, target: full, limit: Self.cleanupRetypeChars) == nil {
            target = region
        } else {
            target = full
        }
        if target == region {
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
            if region.isEmpty, !avoidsMoves, let next = following, !next.isWhitespace, !Self.closingMarks.contains(next) {
                // The run starts in front of text that follows without a space: one goes in behind it, once, and the
                // cursor stays in front of that space, so the run keeps typing where it is.
                queue = [.insert(slice + " "), .move(-1)]; spaceAfterRegion = true
            } else {
                queue = [.insert(slice)]
            }
            paced = false
            region += slice
            inFlightWhole = region == target; self.target = target
        } else {
            // No cursor move where it can be helped: everything from the first change is deleted back from the end and
            // typed again, each op checkable at the end of the field. A flip while the take runs types it one character
            // per op; the cleaned take inserts it whole, and only a long one far from the end goes by words with moves.
            paced = !snapshot.complete; lastSentInsert = false
            let limit = snapshot.complete ? Self.cleanupRetypeChars : Int.max
            if let retype = ShadowEditPlanner.retypeTail(shadow: region, target: target, limit: limit, characters: paced) {
                queue = retype
            } else {
                queue = ShadowEditPlanner.plan(shadow: region, cursor: region.utf16.count, target: target, characters: paced).ops
                cleanupMoving = true
            }
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
        guard queue.isEmpty, lastMove == nil, !settling, let last = region.last, last.isLetter || last.isNumber,
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
        work = ""; workCursor = 0; lastMove = nil; moveShownMs = nil; spaceAfterRegion = false; cleanupMoving = false
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
        if case .move = op { lastMove = op; movedFrom = workCursor; moveResent = false } else { lastMove = nil }
        moveShownMs = nil
        (work, workCursor) = ShadowEditPlanner.simulate(ops: [op], shadow: work, cursor: workCursor)
        switch op {
        case .deleteBackward(let count): step.deletedChars += count
        case .insert(let text): step.insertedChars += text.count
        case .move: break
        }
        step.ops.append(op)
        step.needsTicks = true
        if queue.isEmpty, inFlightWhole, let version = inFlightVersion { step.applied = true; step.version = version }
        if queue.isEmpty, lastMove == nil { cleanupMoving = false }
    }

    /// A freeze while the cleaned take goes in with moves: the cursor goes back to the end of the run when the report
    /// pins where it is, else it stays (`driftDetail` says which).
    private mutating func parkAtEnd(_ step: inout Step, reportedBefore: String, reportedAfter: String) {
        guard cleanupMoving else { return }
        let text = Array(anchor) + Array(work)
        let end = text.count - (spaceAfterRegion ? 1 : 0)
        let found = Self.positions(in: text, reportedBefore: reportedBefore, reportedAfter: reportedAfter)
        guard found.count == 1, let at = found.first else {
            step.driftDetail = (step.driftDetail ?? "") + " cleanup=left"
            return
        }
        let units = at < end ? String(text[at..<end]).utf16.count : -String(text[end..<at]).utf16.count
        if units != 0 { step.ops.append(.move(units)) }
        step.driftDetail = (step.driftDetail ?? "") + " cleanup=parked"
    }

    /// The user took over (a key, a cursor move, another field): what is typed so far stays as it is. Returns
    /// whether anything was frozen. The next step seeds a new anchor at the cursor.
    @discardableResult
    public mutating func freeze(_ cause: FreezeCause) -> Bool {
        defer {
            reseed = true; region = ""; waitedMs = 0; confirming = false; built = Built(); settling = true; lastReport = nil; stableForMs = 0
            queue = []; work = ""; workCursor = 0; inFlightVersion = nil; heldVersion = nil; paced = false; lastSentInsert = false
            lastMove = nil; moveShownMs = nil; resetReport = nil; resetReports = 0; resetMs = 0
            cleanupMoving = false; spaceAfterRegion = false
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

    /// The character offset of a UTF-16 offset into `text`.
    static func characters(ofUTF16 offset: Int, in text: String) -> Int {
        ShadowEditPlanner.characterIndex(ofUTF16: offset, in: Array(text))
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
