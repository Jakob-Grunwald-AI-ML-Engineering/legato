import Foundation

/// The one writer of a bound text field on iOS: every insert, delete and cursor move the keyboard makes goes through
/// it, so it alone knows where the cursor is. Pure: the keyboard feeds it what happens (user input, dictation
/// snapshots, edits to land) and the field's report on every step, and carries out the one `ShadowOp` a step hands over.
///
/// - Model: the known text around the cursor (`text`), learned from reports and kept up to date by simulating every op
///   sent. `cursor` is where the field's caret is; `userCursor` is where it belongs to the user (a jump unit takes the
///   caret away from it and back).
/// - One op in flight: the next op goes out only after a report confirms the last one (the report must pin the
///   expected cursor in the model at that place and nowhere else, `FieldMatch`).
/// - Lanes: user input (keys, delete, cursor pans, word-row and undo edits) goes first, behind at most the op in flight
///   (bounded by `userBoundMs`, then a resync). Edits (`Edit`: Magic, typed lines, host text) come next, then live
///   dictation runs (`LiveDictationSnapshot`, coalesced to the newest per run). A key waits (bounded, `keyHoldMaxMs`)
///   until the take's text already heard is typed, and a stopped take until it is complete (`flushBeforeKeys`): appends
///   only, never a revision or the stop's swap.
/// - Planning happens when an item starts, against the model as it is then. An edit's change away from the cursor is a
///   jump unit: move to the change, delete and insert only the differing characters (`ShadowEditPlanner.diff`), move back.
///   Nothing else goes out while a unit runs; user input ends the unit early (the caret goes back first) and the rest
///   is planned again later.
/// - Never freezes: a report that does not confirm leads to a resync (re-locate the model around the cursor, unique
///   matches only, or take the report as the new model) and planning goes on. An edit is dropped only when its text
///   cannot be placed or the user changed it (`Event.dropped`).
/// - Live dictation types only at the caret (an iOS keyboard sees a short window of the field, never the whole of it):
///   a run's words go in one grapheme at a time at its open piece's end, the user's caret. A revision of the piece's
///   last words goes in while speaking only when every changed character lies within `nearChars` of the caret and the
///   report shows them as typed; anything else waits for the stop. At the stop the take's trailing piece is swapped to
///   its final text in one delete and one insert, after reads of the field (walking back for a long take, each read
///   overlapping the last) showed every character of it as typed (`Swap`). A user key, delete or caret move ends the
///   open piece and freezes every piece before it: the keyboard never edits them again, and a take whose final text
///   cannot stand whole in the field is reported (`Event.dropped`; the app keeps it in History). Later words start a
///   new piece at the user's caret; where pieces start is told to the app (`pieceStarts`), which cleans them apart.
/// - Field switches look like taps (Safari gives a page's fields one identity): a jump counts only when a report pins
///   it, and one that went nowhere or stopped short drops its work once and reseeds the model (`Resync.jumpFailed`).
/// - Instruction edits carry the read they came from (`markRead`): their scope is found through every change since,
///   and only the user's changes in it cancel them.
public struct FieldQueue: Sendable {
    // MARK: Public types

    /// The field's report around the cursor: `selected` is the selection (nil or empty: none).
    public struct Report: Sendable, Equatable, Codable {
        public var before: String
        public var after: String
        public var selected: String?
        public init(before: String, after: String = "", selected: String? = nil) {
            self.before = before; self.after = after; self.selected = selected?.isEmpty == true ? nil : selected
        }
    }

    /// The user's own input at their cursor.
    public enum Input: Sendable, Equatable, Codable {
        case insert(String)
        case deleteBackward
        /// Characters (grapheme clusters); the queue converts to the field's units.
        case move(Int)
    }

    /// A change of known text: `before` + `after` (split at the cursor when it was read) becomes `target`. With
    /// `selected`, the selection is the scope. With `atCursor`, `target` is typed at the user's cursor as it is when
    /// the edit starts (before and after are ignored).
    public struct Edit: Sendable, Equatable, Codable {
        public enum Kind: String, Sendable, Codable { case magic, word, version, undo, host, typist }
        public var id: String
        public var kind: Kind
        public var before: String
        public var after: String
        public var selected: String?
        public var target: String
        public var atCursor: Bool
        /// The cursor ends after the target (otherwise it keeps its place in the text).
        public var cursorAtEnd: Bool
        /// Typed one grapheme per op at the queue's pace (`SpanPlanner.paceMs`) when animating.
        public var paced: Bool
        /// The read (`markRead`) `before` and `after` came from: the scope is found through every change since, and
        /// the keyboard's own changes to it are merged into `target` (only the user's cancel the edit).
        public var readID: String?
        public init(id: String = UUID().uuidString, kind: Kind, before: String = "", after: String = "", selected: String? = nil,
                    target: String, atCursor: Bool = false, cursorAtEnd: Bool = true, paced: Bool = false, readID: String? = nil) {
            self.id = id; self.kind = kind; self.before = before; self.after = after
            self.selected = selected?.isEmpty == true ? nil : selected
            self.target = target; self.atCursor = atCursor; self.cursorAtEnd = cursorAtEnd; self.paced = paced; self.readID = readID
        }
    }

    public enum Lane: String, Sendable, Codable { case user, edit, live }
    public enum Action: Sendable, Equatable { case send(ShadowOp), wait, idle }
    public enum DropReason: String, Sendable, Codable {
        /// The text the edit was for is no longer there (the user or the host changed it).
        case changed
        /// The user typed into the region or scope.
        case userEdited
        /// The text could not be placed uniquely.
        case unplaceable
        case selectionChanged
        /// The field changed, the keyboard went away, or the queue was reset.
        case reset
    }
    public enum Resync: String, Sendable, Codable {
        /// The report pins the cursor somewhere else in known text: the user moved it.
        case cursorMoved
        /// The report shows the state before the op in flight: the host lost it.
        case opLost
        /// The report fits nowhere: the model starts over from it.
        case reseeded
        /// The report fits several places: the model is kept as predicted.
        case ambiguous
        /// The user waited for the op in flight long enough: it counts as landed.
        case assumed
        /// Text appeared at the caret that the keyboard did not type (another keyboard): it is the user's, at the caret.
        case outsideInsert
        /// A report showed an older confirmed state: lag until a fresh report (after a nudge) keeps showing it.
        case stale
        /// A fresh report kept showing an older state: the host lost what followed. The model goes back to it and the
        /// lost edits are made again (the user's lost keys go once more).
        case reverted
        /// A jump of the keyboard's own went nowhere (the report kept showing the caret where it was): the text it was
        /// for is not in this field. Its work drops and the model starts over from the report (`reseeded` follows).
        case jumpFailed
        case recoveryRequested, recoveryEvidence, recoveryRestored, recoveryReplanned, recoveryRefused
        /// The stop's swap did not go: the field did not show the take as typed, or the user acted first.
        case swapRefused
    }
    public enum CloseCause: String, Sendable, Codable { case keystroke, cursor, resync, selection, newRun, edit }

    public struct Drop: Sendable, Equatable {
        public var id: String
        public var runID: String?
        public var kind: Edit.Kind?
        public var reason: DropReason
        /// What was to be in the field.
        public var text: String
        /// What the scope shows now when known (nothing in flight).
        public var partial: String?
    }

    public enum Event: Sendable, Equatable {
        case sent(ShadowOp, Lane)
        case confirmed(waitedMs: Double)
        case resync(Resync)
        /// An edit landed; `cursor`: UTF-16 offset into its target where the user's cursor ended.
        case applied(id: String, cursor: Int)
        case dropped(Drop)
        case liveApplied(runID: String, version: Int, complete: Bool)
        case regionStarted(runID: String, anchorChars: Int)
        case regionClosed(runID: String, cause: CloseCause)
        /// The op just sent inserts behind the user's cursor: the user's cursor stays in front of it.
        case insertedBehind
        /// A zero-offset move went out to make the proxy report afresh (the op in flight stays in flight).
        case nudged
    }

    public struct Config: Sendable, Equatable {
        public var animated: Bool
        public var movesByCharacters: Bool
        public var capitalization: AutoCapitalizationType
        /// The user's keys wait (bounded, `keyHoldMaxMs`) until the take's text already heard is typed (`flushBeforeKeys`).
        public var keysWaitForTake: Bool
        /// Adapter settlement floor for optimistic insert/delete reports; independent of typewriter pacing.
        public var editConfirmationMs: Double
        /// Automatic deletes must outlive optimistic proxy echoes before another destructive step.
        public var deleteConfirmationMs: Double
        /// The adapter can supply a bounded, self-verifying cursor read on request.
        public var canReadAround: Bool
        /// Edits (Magic) wait while a take is spoken.
        public var prioritizeSpeech: Bool
        public init(animated: Bool = true, movesByCharacters: Bool = false, capitalization: AutoCapitalizationType = .none,
                    keysWaitForTake: Bool = true, editConfirmationMs: Double = FieldQueue.charMs, canReadAround: Bool = false,
                    prioritizeSpeech: Bool = false, deleteConfirmationMs: Double = FieldQueue.charMs) {
            self.animated = animated; self.movesByCharacters = movesByCharacters; self.capitalization = capitalization
            self.keysWaitForTake = keysWaitForTake
            self.editConfirmationMs = editConfirmationMs
            self.deleteConfirmationMs = deleteConfirmationMs
            self.canReadAround = canReadAround
            self.prioritizeSpeech = prioritizeSpeech
        }
    }

    // MARK: Tunables

    /// How long an op may go unconfirmed before the queue resyncs.
    public static let confirmLimitMs = 600.0
    /// How long user input waits behind the op in flight: by then the host has applied it (`transitMs`).
    public static let userBoundMs = transitMs
    /// A new region starts only once the report held still this long.
    public static let stableMs = 150.0
    /// The closest two typed graphemes (or two deletes) follow each other: the field's confirmation floor.
    public static let charMs = SpanPlanner.floorMs
    /// Safari as measured (no field puts its caret back after a move): the proxy reports a move at once, but the host
    /// applies it 25–50 ms later, and an edit no sooner than 5 ms after it is sent. A move is confirmed only by a report
    /// at least `moveSettleMs` after it, so the edit that follows cannot land before it. An edit the proxy has not
    /// reported after `nudgeAfterMs` gets a zero-offset move (its report can stay stale until a move).
    public static let moveSettleMs = 45.0
    public static let nudgeAfterMs = 250.0
    /// The host applies an insert or delete up to about 110 ms after it was sent (in UAT a move sent 70 ms after an
    /// insert landed before it, and the insert was lost). An op that never confirmed, or one whose result the report
    /// cannot tell from the state before it (a delete with nothing known before the cursor, a collapsing move), is
    /// taken as landed only after this transit.
    public static let transitMs = 115.0
    /// An edit of another kind follows an edit only this long after it (it lands no sooner than 5 ms after it is sent);
    /// edits of one kind follow each other at the pace (they land in order).
    public static let editSettleMs = 110.0
    /// A move follows an edit only this long after it (a move lands no sooner than 25 ms after it is sent).
    public static let editMoveSettleMs = 90.0
    /// Confirmed states kept to recognise a late report of one of them (lag), and how long.
    static let historyCount = 24
    static let historyMs = 3_000.0
    /// An edit that cannot be placed yet waits this long for the report to catch up.
    public static let placeGraceMs = 400.0
    /// An edit whose text went out of sight (a resync) waits this long for it to show again.
    public static let parkLimitMs = 3_000.0
    /// Text found again away from the cursor (after a resync, or a scope that moved) must be at least this long.
    public static let relocateChars = 16
    /// Context on each side that must match too when parked text is found again.
    static let contextChars = 8
    /// A report reaching back past a short model must agree with at least this much of it.
    static let extendOverlapChars = 4
    /// How long the user's keys wait for the take (`flushBeforeKeys`): the typing still to do at `keyHoldGraphemeMs` a
    /// grapheme, plus `keyHoldSlackMs` for its final words, never more than `keyHoldMaxMs`. Then they land and the rest
    /// of the take follows them.
    public static let keyHoldMaxMs = 8_000.0
    public static let keyHoldSlackMs = 1_000.0
    /// Safari confirms an insert in about 45 ms.
    static let keyHoldGraphemeMs = 45.0
    /// A budget for the app's wait on an edit of `operationCount` ops.
    public static func budgetMs(operationCount: Int) -> Double { max(20_000, Double(max(0, operationCount)) * 150) }

    // MARK: State

    public var config: Config
    /// Something else needs the cursor for a moment (a walk that reads the field): the op in flight is confirmed and
    /// the caret goes back to the user's cursor, nothing else goes out.
    public var paused = false
    public private(set) var text: [Character] = []
    public private(set) var cursor = 0
    public private(set) var userCursor = 0
    /// Characters selected after `cursor`.
    public private(set) var selection = 0
    public private(set) var seeded = false

    struct Span: Sendable, Equatable {
        var start: Int
        var end: Int
        var userChanged = false
        /// Another edit (Magic) rewrote part of it: a dictation region there is left as it is.
        var edited = false
        var parked = false
        /// An edit's anchor: text inserted right at it goes after it.
        var anchor = false
        /// The text the span was last known to hold, to find it again after a reseed.
        var lastText: [Character] = []
        /// The text around it then (up to `contextChars` each side): it must stand there too.
        var lastBefore: [Character] = []
        var lastAfter: [Character] = []
        /// The user typed or edited while the span was lost: a change found there may be theirs.
        var userActedParked = false
    }
    private var spans: [Int: Span] = [:]
    private var nextSpanID = 0

    private struct EditState: Sendable, Equatable {
        var edit: Edit
        var spanID: Int?
        /// Where the user's cursor was when the edit came: a zero-width span that moves with every change.
        var anchorID: Int?
        var unplacedMs = 0.0
        var attempts = 0
        /// About how many graphemes the edit types (the changed middle of its scope), for the backlog's pace.
        var typedEstimate: Int

        init(edit: Edit) {
            self.edit = edit
            let old = edit.atCursor ? [] : Array(edit.selected ?? edit.before + edit.after), new = Array(edit.target)
            let prefix = zip(old, new).prefix { $0 == $1 }.count
            let suffix = zip(old.dropFirst(prefix).reversed(), new.dropFirst(prefix).reversed()).prefix { $0 == $1 }.count
            typedEstimate = new.count - prefix - suffix
        }
    }
    private enum UserItem: Sendable, Equatable {
        case input(Input, retried: Bool)
        case edit(EditState)
        var isMove: Bool { if case .input(.move, _) = self { true } else { false } }
    }
    private var userLane: [UserItem] = []
    private var editLane: [EditState] = []

    struct LiveRun: Sendable, Equatable {
        var runID: String
        var version: Int?
        var complete = false
        /// The user stopped the take (`takeStopped`, or a snapshot says so): keys wait for its words still arriving.
        var stopped = false
        var pending: LiveDictationSnapshot?
        /// The newest snapshot's segments: what each piece's final text is.
        var segments: [LiveSegment] = []
        /// The take's words as spoken (cleaned units show their raw words), and where each segment starts in the
        /// delivered text while that is the speech as published.
        var speechSegments: [LiveSegment] = []
        var speechStarts: [Int: Int] = [:]
        /// The take's words as typed at the caret (`SpeechDelivery`): only ever extended, except a revision near the
        /// caret the field showed (`nearRevision`).
        var speech = SpeechDelivery()
        var delivered: [Character] { speech.delivered }
        var pieces: [Piece] = []
        var ackedVersion: Int?
        /// Every segment is cleaned: no later cleanup is coming.
        var cleaned = false
        /// The complete version settled (swapped in, or kept with the fallback): each version once.
        var settledVersion: Int?
        var fallbackReported = false
        /// Delivered text up to here is never typed again (it went with a swap that did not finish, or landed elsewhere).
        var settledThrough = 0
    }
    private(set) var runs: [LiveRun] = []
    /// Finished runs kept for a cleanup still to come (the newest run aside).
    static let keptRuns = 4
    /// Runs no longer kept: a late version of one is ignored (it is in History), never typed at the caret.
    private var retiredRunIDs: [String] = []

    /// A read of the field for an instruction (`markRead`): the model then, and every change since, so the edit that
    /// comes back finds its scope through them and tells the keyboard's own changes from the user's.
    private struct ReadMark: Sendable, Equatable {
        enum Change: Sendable, Equatable {
            case insert(at: Int, count: Int, owner: Int?)
            case remove(Int, Int, owner: Int?)
            /// The model learned text in front of what it knew.
            case grow(Int)
        }
        var id: String
        var text: [Character]
        var cursor: Int
        /// The spans then: their text was read, so what they insert at the scope's edge is a change of it.
        var spanIDs: Set<Int>
        var changes: [Change] = []
    }
    private var readMarks: [ReadMark] = []
    static let readMarkCount = 4
    static let readMarkChanges = 4_096

    private enum QOp: Sendable, Equatable {
        /// To this offset into a span (resolved when sent: the model may have grown in front of it meanwhile).
        case moveInSpan(Int, offset: Int)
        case moveToUser
        case moveToSpanEnd(Int)
        /// Deletes this many characters before the caret in one op (the same delete at one place: order cannot matter).
        case delete(Int, owner: Int?)
        case insert(String, owner: Int?)
        /// Inserted at the caret, behind the user's cursor (which stays in front of it).
        case insertBehind(String)
        case setUserCursorToCursor
        case startRegion(run: String, tStart: Int, anchor: String)
    }
    private enum UnitOwner: Sendable, Equatable { case edit(EditState, Lane), space }
    private struct Unit: Sendable, Equatable {
        var ops: [QOp]
        var owner: UnitOwner
        var paced: Bool
        /// The unit's own pace: its typed graphemes spread over the budget left after its settles.
        var paceMs: Double

        init(ops: [QOp], owner: UnitOwner, paced: Bool) {
            self.ops = ops; self.owner = owner; self.paced = paced
            enum Kind { case move, delete, insert }
            var inserts = 0, fixedMs = 0.0
            var previous: Kind?
            for op in ops {
                let kind: Kind
                switch op {
                case .moveInSpan, .moveToUser, .moveToSpanEnd: kind = .move
                case .delete: kind = .delete
                case .insert, .insertBehind: kind = .insert
                case .setUserCursorToCursor, .startRegion: continue
                }
                if let previous, previous != kind {
                    fixedMs += previous == .move ? FieldQueue.moveSettleMs : kind == .move ? FieldQueue.editMoveSettleMs : FieldQueue.editSettleMs
                }
                if kind == .insert { inserts += 1 }
                previous = kind
            }
            paceMs = SpanPlanner.paceMs(ops: inserts, fixedMs: fixedMs)
        }
    }
    private var unit: Unit?

    private struct ModelState: Sendable, Equatable {
        var text: [Character]; var cursor: Int; var userCursor: Int; var selection: Int; var spans: [Int: Span]
    }
    private struct InFlight: Sendable, Equatable {
        var op: ShadowOp
        var lane: Lane
        /// Exact: the report must pin `cursor` in the model. Anywhere: any unique place (a collapsing move).
        var anywhere: Bool
        var pre: ModelState
        var waitedMs = 0.0
        var input: Input?
        var retried = false
        var isMove: Bool
        /// A report counts only this long after the last send (a move's settle gap).
        var settleMs: Double
        var nudged = false
        /// The nudge after a report of an older state: it is given the whole confirm window (late reports still show
        /// the old state for a while) before the older state is believed.
        var staleCheck = false
        var lastReport: Report?
        /// A jump of the keyboard's own to this span (a region's or an edit's).
        var jumpSpan: Int?
    }
    private var coordinator = FieldEditCoordinator.Operations()
    private var inFlight: InFlight? {
        didSet {
            // Losing a prediction is not confirmation. The shared barrier drains its remaining transit first.
            if inFlight == nil, coordinator.current?.kind != .read { coordinator.invalidate() }
        }
    }

    private var recovery = FieldRecovery()
    private var recoveryGeneration = UUID().uuidString
    public private(set) var recoveryRevision: UInt64 = 0
    private var recoveryWaitMs = 0.0
    public private(set) var recoveryRequest: FieldRecovery.Request? {
        didSet { if recoveryRequest?.id != oldValue?.id { recoveryWaitMs = 0 } }
    }
    public private(set) var speechRevision: UInt64 = 0
    /// Positive ambiguity in the known model remains relevant even when the proxy exposes just one nearby copy.
    /// A model's absence of a match makes no claim about unobserved text elsewhere in the field.
    public var recoveryHasKnownAmbiguity: Bool {
        guard let request = recoveryRequest else { return false }
        return recovery.hasAmbiguity(request, text: String(text))
    }
    /// A recovery response can never replace the model after user input or a field reset.
    public mutating func completeRecovery(_ request: FieldRecovery.Request, report: Report?, restored: Bool, completeDocument: Bool = false) {
        guard recoveryRequest == request else { return }
        // The production adapter acquires a read lease only after the op in flight is settled. Never let a late or
        // incorrectly timed response replace the model beneath an issued op; its request remains pending.
        guard inFlight == nil else { events.append(.resync(.recoveryRefused)); return }
        // All current request paths already abort their jump unit, but no future caller may carry precomputed
        // offsets across this model replacement. Its owner is requeued and planned against the fresh evidence.
        abortUnit()
        recoveryRequest = nil
        guard request.generation == recoveryGeneration, request.revision == recoveryRevision else {
            events.append(.resync(.recoveryRefused)); return
        }
        let evidence = (report?.before ?? "") + (report?.after ?? "")
        let decisions = recovery.resolve(request, text: evidence, generation: recoveryGeneration,
                                         revision: recoveryRevision, restored: restored, completeDocument: completeDocument)
        events.append(.resync(.recoveryEvidence))
        if restored { events.append(.resync(.recoveryRestored)) }
        if let report, restored {
            let oldText = text, oldCursor = cursor
            let updated = Array(report.before + report.after), newCursor = report.before.count
            // The walk returned to the user's cursor. Rebase other already-known spans only where the fresh read
            // independently agrees with their contents; unknown or changed spans remain parked.
            for (id, var span) in spans where !span.parked {
                let known = Array(oldText[span.start..<span.end])
                let at = span.start + newCursor - oldCursor
                if at >= 0, at + known.count <= updated.count, updated[at..<(at + known.count)].elementsEqual(known) {
                    span.start = at; span.end = at + known.count
                } else {
                    span.lastText = known; span.parked = true; span.userActedParked = false
                }
                spans[id] = span
            }
            text = updated; cursor = newCursor; userCursor = newCursor; selection = 0; seeded = true
            readMarks = []; userLost = nil; lagging = []; confirmedHistory = []; recentSends = []
        }
        for decision in decisions {
            switch decision {
            case .replan(let placement):
                guard restored, let id = Int(placement.id), var span = spans[id] else { continue }
                span.start = placement.range.lowerBound; span.end = placement.range.upperBound
                span.lastText = Array(placement.text); span.parked = false
                spans[id] = span
                events.append(.resync(.recoveryReplanned))
            case .stop(let key, _):
                if let id = Int(key) { abandonRecoverySpan(id) }
                events.append(.resync(.recoveryRefused))
            }
        }
    }

    private mutating func requestRecoveryIfNeeded() {
        // Dictation never looks around: its pieces are edited only at the caret.
        guard config.canReadAround, recoveryRequest == nil, !(config.prioritizeSpeech && isSpeaking) else { return }
        let pieces = Set(runs.flatMap { $0.pieces.map(\.spanID) })
        let targets = spans.sorted { $0.key < $1.key }.compactMap { id, span -> FieldRecovery.Target? in
            guard span.parked, !span.anchor, !span.userChanged, !span.edited, !span.lastText.isEmpty, !pieces.contains(id) else { return nil }
            return .init(id: String(id), expected: String(span.lastText), before: String(span.lastBefore), after: String(span.lastAfter))
        }
        guard let request = recovery.begin(generation: recoveryGeneration, revision: recoveryRevision, targets: targets) else { return }
        recoveryRequest = request
        events.append(.resync(.recoveryRequested))
    }

    /// A background read gives back its lease before another queue item may use the cursor. Its parked targets
    /// remain intact; the final dictation snapshot can ask for a fresh read instead of dropping deferred edits.
    public mutating func deferRecovery(_ request: FieldRecovery.Request) {
        guard recoveryRequest == request else { return }
        recoveryRequest = nil
        recoveryRevision &+= 1
    }

    private mutating func abandonRecoverySpan(_ id: Int) {
        var abandoned: [EditState] = []
        userLane.removeAll { if case .edit(let state) = $0, state.spanID == id { abandoned.append(state); return true }; return false }
        editLane.removeAll { if $0.spanID == id { abandoned.append($0); return true }; return false }
        for state in abandoned { drop(state, .unplaceable) }
    }

    public var ownsRead: Bool { coordinator.current?.kind == .read }
    public mutating func acquireRead() -> Bool { isHome && coordinator.begin(.read) }
    public mutating func releaseRead() { coordinator.finishRead() }
    /// The adapter calls this after the OS send, never before planning or dispatch.
    public mutating func operationDispatched() {
        coordinator.dispatched(); sinceSendMs = 0; inFlight?.waitedMs = 0
    }

    private var sinceSendMs = 1_000.0
    private var lastReport: Report?
    private var reportStableMs = 0.0
    private var events: [Event] = []
    private var stepElapsedMs = 0.0
    /// States before ops that counted as landed without a confirmation: reports showing them are lag.
    private var lagging: [(state: ModelState, ageMs: Double)] = []
    /// The states before recently confirmed ops, oldest first, with the user's input each op carried.
    private var confirmedHistory: [(state: ModelState, input: Input?, ageMs: Double)] = []
    /// A report showed an older state: a nudge is due, or out and not answered yet.
    private var staleNudgeDue = false
    private var staleNudgeSent = false
    /// The last history entry is the state before an op that never confirmed (kept as a candidate older state).
    private var unconfirmedInHistory = false
    /// The user moved the caret (a tap): only the user's own input goes until the report held still this long and fits.
    private var quietAfterMove = false
    /// The op that was on its way when the user tapped: it may land where they tapped.
    private struct Sent: Sendable, Equatable { var op: ShadowOp; var lane: Lane; var pre: ModelState; var ageMs = 0.0 }
    /// The ops sent lately (within the confirm window): any of them may have landed where the user tapped meanwhile.
    private var recentSends: [Sent] = []
    private var tapRace: (sends: [Sent], ageMs: Double)?
    /// A proved misplaced insertion, anchored by the unchanged text around it. A read or resync may
    /// move the caret to either side; a character count alone never authorizes compensating deletes.
    private struct StrayInsertion: Sendable, Equatable {
        var text: String
        var before: String
        var after: String
        var lane: Lane
        var runID: String?
        var elapsedMs = 0.0
    }
    private var strayInsertion: StrayInsertion?
    private var lastSendConfirmed = true
    private var lastSentOp: ShadowOp?
    /// How far the last paced insert went past its pace (the tick's overshoot), counted toward the next.
    private var paceCreditMs = 0.0
    private var lastSentLane = Lane.live
    static let quietMs = 250.0
    /// How long the user's keys have waited, by when (in that wait) the take's backlog should be typed, and whether the
    /// first of them cut a dictated word short (the key then starts a word of its own after the word is typed).
    private var keyHeldMs = 0.0
    private var keyTypedByMs = 0.0
    /// The keys wait for the take's backlog, then `keyHoldSlackMs` for its final words, at most `keyHoldMaxMs`.
    private var keyHoldLimitMs: Double { min(Self.keyHoldMaxMs, keyTypedByMs + Self.keyHoldSlackMs) }
    private var keyCutWord = false

    public init(config: Config = Config()) { self.config = config }

    // MARK: Inspection

    public var isSpeaking: Bool { runs.contains { !$0.stopped && !$0.complete } }

    public var isIdle: Bool {
        recoveryRequest == nil && strayInsertion == nil && tapRace == nil && inFlight == nil && unit == nil && swap == nil
            && userLane.isEmpty && (editLane.isEmpty || config.prioritizeSpeech && isSpeaking) && !runs.contains(where: { runNeedsWork($0) })
    }
    public var hasUserInput: Bool { !userLane.isEmpty }
    /// The keyboard's own writes still to land (a unit, queued edits, dictation): a read for an instruction waits for
    /// them, so its scope already shows them.
    public var hasOwnWork: Bool {
        unit != nil || swap != nil || (!editLane.isEmpty && !(config.prioritizeSpeech && isSpeaking)) || runs.contains(where: { runNeedsWork($0) })
    }
    public var hasOpInFlight: Bool { inFlight != nil }
    /// Nothing in flight and the caret at the user's cursor: the field is as the user left it, as far as the queue goes.
    public var isHome: Bool { inFlight == nil && cursor == userCursor && sinceSendMs >= Self.transitMs && !(swap?.replacing ?? false) }
    public var isInUnit: Bool { unit != nil }
    public var modelText: String { String(text) }
    /// The text before the user's cursor once pending at-cursor edits landed: what typed lines and host text plan against.
    public var projectedBefore: String {
        var before = String(text[..<min(userCursor, text.count)])
        for state in editLane where state.spanID == nil && state.edit.atCursor { before += state.edit.target }
        for state in editLane {
            guard let id = state.spanID, let span = spans[id], span.end == userCursor else { continue }
            before = String(before.dropLast(span.end - span.start)) + state.edit.target
        }
        return before
    }
    public var expectedBefore: String { String(text[..<cursor]) }
    public var expectedAfter: String { String(text[(cursor + selection)...]) }
    /// The open dictation piece (for the instruction scope `session`): its run, anchor and text.
    public var openRegion: (runID: String, anchor: String, text: String)? {
        guard let (ri, pi) = openPieceIndex(), let span = spans[runs[ri].pieces[pi].spanID] else { return nil }
        return (runs[ri].runID, runs[ri].pieces[pi].anchor, String(chars(of: span)))
    }
    public var pendingEditIDs: [String] {
        userLane.compactMap { if case .edit(let s) = $0 { s.edit.id } else { nil } } + editLane.map(\.edit.id)
    }

    public mutating func drainEvents() -> [Event] { defer { events = [] }; return events }
    /// Raw words of a run still to start a region at the user's cursor.
    var hasUntypedRest: Bool { runs.contains { untypedRest(of: $0) != nil } }

    /// The queue's state in one line, for traces and the edit journal.
    public var debugState: String {
        var parts = ["user=\(userLane.count)", "edits=\(editLane.count)", "unit=\(unit.map { "\($0.ops.count)" } ?? "-")",
                     "flight=\(inFlight != nil)", "sel=\(selection)", "lost=\(userLost.map { "\(String($0.before).debugDescription)|\(String($0.after).debugDescription) homed=\($0.homed)" } ?? "-")"]
        for run in runs {
            for piece in run.pieces {
                let span = spans[piece.spanID]
                parts.append("[\(piece.tStart)..\(piece.tEnd.map(String.init) ?? "open") parked=\(span?.parked ?? true) "
                             + "changed=\(span?.userChanged ?? false) frozen=\(piece.frozen) swapped=\(piece.swapped != nil) "
                             + "has=\(String(span.map { chars(of: $0) } ?? []).debugDescription) wants=\(desiredText(piece, in: run).debugDescription)]")
            }
            if let rest = untypedRest(of: run) { parts.append("rest@\(rest)") }
            if run.speech.hasDeferredRevision { parts.append("deferred=\(String(run.speech.authoritative.suffix(40)).debugDescription)") }
        }
        if let swap { parts.append("swap=\(swap.phase) covered=\(swap.covered.map(String.init) ?? "-")") }
        return parts.joined(separator: " ")
    }

    // MARK: Enqueue

    public mutating func enqueue(_ input: Input) {
        recoveryRevision &+= 1
        if recoveryRequest != nil { events.append(.resync(.recoveryRefused)) }
        recoveryRequest = nil
        if userLane.isEmpty, case .insert = input { keyCutWord = openPieceWordRest() != nil }
        userLane.append(.input(input, retried: false))
    }

    /// The rest of the word the open piece's typewriter has shown only part of, at the user's cursor.
    private func openPieceWordRest() -> [Character]? {
        guard cursor == userCursor, selection == 0, let (ri, pi) = openPieceIndex(), let span = spans[runs[ri].pieces[pi].spanID],
              !span.parked, span.end == userCursor else { return nil }
        let desired = Array(desiredText(runs[ri].pieces[pi], in: runs[ri]))
        let current = chars(of: span)
        guard desired.count > current.count, desired.starts(with: current), let last = current.last,
              last.isLetter || last.isNumber, let first = desired[current.count...].first, first.isLetter || first.isNumber else { return nil }
        return Array(desired[current.count...].prefix { !$0.isWhitespace })
    }

    /// `user`: an edit the user asked for (word row, undo, version swap): it goes in the user lane.
    public mutating func enqueue(_ edit: Edit, user: Bool = false) {
        if user { recoveryRevision &+= 1; recoveryRequest = nil }
        var state = EditState(edit: edit)
        if seeded, !edit.atCursor, edit.selected == nil { state.anchorID = addSpan(Span(start: userCursor, end: userCursor, anchor: true)) }
        if user { userLane.append(.edit(state)) } else { editLane.append(state) }
    }

    /// A live run's newest snapshot. Snapshots of a run coalesce to the newest; a new run closes the last run's region.
    public mutating func enqueue(_ snapshot: LiveDictationSnapshot) {
        if let index = runs.firstIndex(where: { $0.runID == snapshot.runID }) {
            if snapshot.stopped == true { runs[index].stopped = true }
            if let latest = runs[index].pending?.version ?? runs[index].version, snapshot.version <= latest, snapshot.complete == runs[index].complete { return }
            speechRevision &+= 1
            runs[index].pending = snapshot
            return
        }
        guard !retiredRunIDs.contains(snapshot.runID) else { return }
        speechRevision &+= 1
        closeOpenPieces(.newRun)
        var run = LiveRun(runID: snapshot.runID)
        run.pending = snapshot
        run.stopped = snapshot.stopped == true
        runs.append(run)
    }

    /// The user stopped the take (the mic key; the app's snapshots say so too, `LiveDictationSnapshot.stopped`): no more
    /// speech joins it, so keys wait for its text (`flushBeforeKeys`).
    public mutating func takeStopped(_ runID: String) {
        guard let index = runs.firstIndex(where: { $0.runID == runID }) else { return }
        runs[index].stopped = true
    }

    /// Ends work for a run: its unfinished text is reported as dropped (the app keeps the take in History).
    public mutating func cancelRun(_ runID: String) {
        guard let index = runs.firstIndex(where: { $0.runID == runID }) else { return }
        dropRun(at: index, reason: .reset)
        runs.remove(at: index)
        retiredRunIDs.append(runID)
    }

    /// The field is read now for an instruction (the queue home): an edit carrying `id` as its `readID` is placed
    /// through the changes made since. A later mark of the same id replaces it.
    public mutating func markRead(_ id: String) {
        guard seeded else { return }
        readMarks.removeAll { $0.id == id }
        readMarks.append(ReadMark(id: id, text: text, cursor: userCursor, spanIDs: Set(spans.keys)))
        if readMarks.count > Self.readMarkCount { readMarks.removeFirst() }
    }

    public mutating func forgetRead(_ id: String) { readMarks.removeAll { $0.id == id } }

    /// Cancels an edit not yet landed.
    public mutating func cancelEdit(_ id: String) {
        if case .edit(let s, _)? = unit?.owner, s.edit.id == id { unit = nil; finishSpan(s.spanID) }
        var spanIDs: [Int?] = []
        userLane.removeAll { if case .edit(let s) = $0, s.edit.id == id { spanIDs += [s.spanID, s.anchorID]; return true }; return false }
        editLane.removeAll { if $0.edit.id == id { spanIDs += [$0.spanID, $0.anchorID]; return true }; return false }
        for spanID in spanIDs { finishSpan(spanID) }
    }

    /// The field went away or changed: everything pending is dropped with events, and the model starts over.
    public mutating func reset() {
        for item in userLane { if case .edit(let s) = item { drop(s, .reset) } }
        for state in editLane { drop(state, .reset) }
        if case .edit(let s, _)? = unit?.owner { drop(s, .reset) }
        for index in runs.indices { dropRun(at: index, reason: .reset) }
        let config = config
        let events = events
        self = FieldQueue(config: config)
        self.events = events
    }

    // MARK: Step

    /// One step against the field's report: at most one op to carry out.
    public mutating func step(report: Report, elapsedMs: Double) -> Action {
        guard !ownsRead else { return .wait }
        coordinator.advance(elapsedMs)
        stepElapsedMs = elapsedMs
        if let request = recoveryRequest {
            recoveryWaitMs += max(0, elapsedMs)
            // The adapter normally answers. An orphaned or superseded read must still terminate.
            if recoveryWaitMs >= 2 * FieldRecovery.budgetMs + Self.confirmLimitMs, inFlight == nil {
                completeRecovery(request, report: nil, restored: false)
            }
        }
        if !paused, var stray = strayInsertion {
            stray.elapsedMs += max(0, elapsedMs)
            strayInsertion = stray
            let limit = userLane.isEmpty ? Self.confirmLimitMs : Self.userBoundMs
            if stray.elapsedMs >= limit { refuseStrayInsertion() }
        }
        sinceSendMs += elapsedMs

        if userLane.isEmpty {
            keyHeldMs = 0; keyTypedByMs = 0; keyCutWord = false
        } else {
            keyHeldMs += elapsedMs
            let backlog = takeBacklog()
            if backlog > 0 { keyTypedByMs = max(keyTypedByMs, keyHeldMs + Double(backlog) * Self.keyHoldGraphemeMs) }
        }
        // Only the user selects: a selection the model does not have says the user acted at the caret.
        if report.selected != nil, selection == 0 { userActed = true }
        lagging = lagging.filter { $0.ageMs + elapsedMs < Self.confirmLimitMs }.map { ($0.state, $0.ageMs + elapsedMs) }
        if let race = tapRace { tapRace = race.ageMs + elapsedMs < Self.confirmLimitMs * 2 ? (race.sends, race.ageMs + elapsedMs) : nil }
        recentSends = recentSends.compactMap { var sent = $0; sent.ageMs += elapsedMs; return sent.ageMs < Self.confirmLimitMs ? sent : nil }
        confirmedHistory = confirmedHistory.filter { $0.ageMs + elapsedMs < Self.historyMs }.map { ($0.state, $0.input, $0.ageMs + elapsedMs) }
        if report == lastReport { reportStableMs += elapsedMs } else { lastReport = report; reportStableMs = 0 }
        if !seeded {
            seed(report)
            // Edits that came before the first report are anchored where the cursor turns out to be.
            for i in userLane.indices { if case .edit(var s) = userLane[i], s.anchorID == nil, !s.edit.atCursor, s.edit.selected == nil {
                s.anchorID = addSpan(Span(start: userCursor, end: userCursor, anchor: true)); userLane[i] = .edit(s) } }
            for i in editLane.indices where editLane[i].anchorID == nil && !editLane[i].edit.atCursor && editLane[i].edit.selected == nil {
                editLane[i].anchorID = addSpan(Span(start: userCursor, end: userCursor, anchor: true))
            }
        }

        if let tap = tappedElsewhere(report, flight: inFlight) {
            // A place no op was going to, settled or not (or nothing in flight): the user tapped. Later reports of the
            // state before it are lag.
            let flight = inFlight
            inFlight = nil
            userTapped(at: tap.at, flight: flight)
            // The text it was found in, at the tap, is lag too (the proxy can show text from before confirmed edits).
            if let seen = tap.seen { lagging.append((seen, 0)) }
        }
        if var flight = inFlight {
            // The proxy shows a move at once, before the host applied it: only a report after the settle gap counts.
            let settled = coordinator.settled && sinceSendMs >= flight.settleMs
            // A report that fits the state before the op as well proves nothing (the op may still be on its way), and
            // neither does one that shows a state the host lags behind.
            // A stale check's zero-offset move changes nothing: a fresh report of the model is its confirmation.
            if settled, matches(report, anywhere: flight.anywhere),
               flight.anywhere || !pins(report, in: flight.pre) || (flight.staleCheck && flight.op == .move(0)),
               !lagging.contains(where: { pins(report, in: $0.state) }) {
                if flight.anywhere { relocate(report) }
                guard coordinator.confirm(matches: true) else { return .wait }
                events.append(.confirmed(waitedMs: flight.waitedMs))
                lastSendConfirmed = true
                confirmedHistory.append((flight.pre, flight.input, 0))
                unconfirmedInHistory = false
                if confirmedHistory.count > Self.historyCount { confirmedHistory.removeFirst() }
                staleNudgeSent = false
                userActed = false
                merge(report)
                inFlight = nil
                lagging = []
            } else if !settled {
                flight.waitedMs += elapsedMs
                inFlight = flight
                return .wait
            } else {
                flight.waitedMs += elapsedMs
                if report != flight.lastReport { flight.lastReport = report }
                // A report that fits the state before the op (even among other places) may be that state, late.
                let pinsPre = fits(report, in: flight.pre)
                if landedElsewhere(report, flight: flight) {
                    // The user tapped while their key was on its way: it landed where they tapped.
                    inFlight = nil
                    events.append(.resync(.cursorMoved))
                    return next()
                }
                if !flight.nudged, !flight.isMove, flight.waitedMs >= Self.nudgeAfterMs, selection == 0, report.selected == nil {
                    // An edit the proxy has not reported yet (it can stay on its last report): a zero-offset move makes
                    // it report the field afresh. It moves nothing, so it cannot land out of order.
                    flight.nudged = true; flight.settleMs = Self.moveSettleMs; flight.staleCheck = true
                    // The fresh report this brings is the stale check: an older state it keeps showing is believed.
                    staleNudgeSent = true
                    inFlight = flight
                    sinceSendMs = 0
                    events.append(.nudged)
                    return .send(.move(0))
                }
                if !userLane.isEmpty, flight.waitedMs >= Self.userBoundMs, pinsPre, let target = flight.jumpSpan, !consistent(report) {
                    // A jump the report still shows at its start after the host's transit (the proxy shows a move at
                    // once) went nowhere. Taken as landed, the way back would send the user's caret past where it is.
                    inFlight = nil
                    jumpFailed(to: target, flight: flight, report: report, caret: flight.pre.cursor)
                } else if !userLane.isEmpty, flight.waitedMs >= Self.userBoundMs, pinsPre {
                    // The host lags: the op counts as landed so the user's input can go. Its state before stays a candidate
                    // older state: if the host lost it, a later report shows that state (and the op is made again).
                    inFlight = nil
                    lagging.append((flight.pre, 0))
                    confirmedHistory.append((flight.pre, flight.input, 0)); unconfirmedInHistory = true
                    events.append(.resync(.assumed))
                } else if flight.waitedMs < Self.confirmLimitMs, lagging.contains(where: { pins(report, in: $0.state) }) {
                    inFlight = flight
                    return .wait
                } else if flight.waitedMs >= Self.confirmLimitMs
                            || (!flight.staleCheck && !pinsPre && flight.waitedMs >= Self.userBoundMs && reportStableMs >= Self.userBoundMs / 2)
                            || (!flight.staleCheck && !userLane.isEmpty && flight.waitedMs >= 2 * Self.userBoundMs) {
                    inFlight = nil
                    resync(report, pre: flight)
                } else {
                    inFlight = flight
                    return .wait
                }
            }
        } else if !consistent(report) {
            // A report that still shows a state the host lags behind is no change of the user's.
            if lagging.contains(where: { pins(report, in: $0.state) }) { return .wait }
            // An older state within the last op's transit: the host is still applying it (the proxy dropped its echo
            // when an earlier op landed). Lag: nothing goes until it shows, or the transit is over.
            if sinceSendMs < Self.transitMs, !staleNudgeSent, olderState(report, flight: nil) != nil { return .wait }
            resync(report, pre: nil)
        } else if reportStableMs == 0 {
            merge(report)
        }
        return next()
    }

    // MARK: Choosing the next op

    /// The next op, held back while it would follow the last one too soon for its kind: ops of one kind at the caret
    /// (inserts, deletes, moves) land in order, no closer than `charMs`; a change of kind after an edit waits for the
    /// host to have applied it (`editSettleMs`), since Safari can land a later op of another kind first.
    private mutating func next() -> Action {
        if recoveryRequest != nil, !paused { return .wait }
        guard coordinator.available else { return .wait }
        let saved = self
        let action = plannedNext()
        guard case .send(let op) = action, let last = saved.lastSentOp, saved.sinceSendMs < Self.gap(after: last, before: op) else {
            return action
        }
        self = saved
        return .wait
    }

    static func gap(after last: ShadowOp, before op: ShadowOp) -> Double {
        switch (last, op) {
        case (.insert, .insert), (.deleteBackward, .deleteBackward): return charMs
        case (.move, _): return 0 // a move counts only after its settle (`moveSettleMs`) anyway
        case (_, .move): return editMoveSettleMs
        default: return editSettleMs
        }
    }

    private mutating func plannedNext() -> Action {
        // An op that never confirmed may still be on its way: nothing follows it before the host's transit.
        if !lastSendConfirmed, sinceSendMs < Self.transitMs {
            if inFlight == nil { for ri in runs.indices { ack(ri) } }
            return .wait
        }
        if staleNudgeDue {
            // A late report showed an older state: a zero-offset move makes the proxy report the field afresh.
            staleNudgeDue = false; staleNudgeSent = true
            abortUnit()
            // Zero offset: the model is in doubt, so the caret goes nowhere on its strength.
            let action = send(.move(0), lane: .edit)
            inFlight?.staleCheck = true
            return action
        }
        if var lost = userLost {
            if lost.homed {
                // The caret went back the way it came: the user's cursor is found there, or the caret is taken for it.
                findLostUser()
            } else {
                // Nothing starts at a cursor the queue does not know: the caret goes back the way it came, once.
                lost.homed = true; lost.from = cursor; userLost = lost
                abortUnit()
                return send(.move(lost.units), lane: .edit, anywhere: true) { _ in }
            }
        }
        // The stop's swap deleted the take: its final text goes in before anything else (keys wait for this one insert).
        if swap?.replacing == true { return nextSwap() ?? .wait }
        if paused {
            abortUnit()
            // A read needs the cursor: the swap's walk gives it back and is tried again afterwards.
            if swap != nil { swap = nil }
            if cursor != userCursor, selection == 0 { return send(.move(units(to: userCursor)), lane: .user, moveTo: userCursor) }
            return .wait
        }
        // User input first; a running unit gives the caret back first.
        if let stray = strayInsertion, selection == 0 {
            abortUnit()
            let places = FieldMatch.positions(in: text, reportedBefore: stray.before + stray.text, reportedAfter: stray.after)
            guard places.count == 1, let end = places.first, end >= stray.text.count,
                  String(text[(end - stray.text.count)..<end]) == stray.text else {
                // The ownership evidence no longer locates the inserted text. Never undo at today's caret.
                refuseStrayInsertion()
                return .wait
            }
            guard let report = lastReport, consistent(report) else { return .wait }
            if cursor != end { return send(.move(units(to: end)), lane: stray.lane, moveTo: end) }
            // Independent readback must show the owned characters immediately before the settled caret.
            guard report.before.hasSuffix(stray.text),
                  FieldMatch.confirms(expectedBefore: stray.before + stray.text, expectedAfter: stray.after,
                                      reportedBefore: report.before, reportedAfter: report.after) else { return .wait }
            strayInsertion = nil
            return send(.deleteBackward(stray.text.count), lane: stray.lane) { q in
                q.removeRange(end - stray.text.count, end, owner: -1)
            }
        }
        if !userLane.isEmpty {
            // Keys wait for the take's text already heard: a typed line on its way goes on.
            if keysWait, case .edit(let state, _)? = unit?.owner, state.edit.kind == .typist { return nextInUnit() }
            // Keys never wait for the stop's swap: the take stays as typed (its final text is in History).
            if swap != nil { failSwap(.userEdited) }
            abortUnit()
            if cursor != userCursor, selection == 0 { return send(.move(units(to: userCursor)), lane: .user, moveTo: userCursor) }
            if keysWait, let action = flushBeforeKeys() { return action }
            if let action = nextUser() { return action }
        }
        // A tap can redirect an already-issued OS write. Reconcile its landing before any
        // further automated jump/edit, rather than racing a second operation against that write.
        if tapRace != nil { return .wait }
        if quietAfterMove {
            // Ops sent before the tap may still be landing where the user tapped: nothing of the keyboard's own
            // goes until the field holds still and shows what the model expects.
            guard inFlight == nil, reportStableMs >= Self.quietMs, let report = lastReport, consistent(report) else { return .wait }
            quietAfterMove = false
        }
        // Nothing of the keyboard's own starts, and no jump goes out, on a model the field's report does not show at the
        // caret (another field's report can fit it elsewhere): it waits, and a report that holds still so reseeds.
        let shown = lastReport.map(consistent) ?? true
        if config.prioritizeSpeech, isSpeaking, case .edit(_, .edit)? = unit?.owner {
            // Finish the issued op first (the barrier above), then return to the speaking head. The edit is
            // replanned from confirmed text when dictation stops, never replayed from its old cursor offsets.
            abortUnit()
            if cursor != userCursor { return send(.move(units(to: userCursor)), lane: .live, moveTo: userCursor) }
        }
        if let current = unit {
            if !shown, let op = current.ops.first {
                switch op {
                case .moveInSpan, .moveToSpanEnd, .moveToUser: return .wait
                default: break
                }
            }
            return nextInUnit()
        }
        if selection > 0 { return .idle }
        guard shown else { return .wait }
        if swap != nil, let action = nextSwap() { return action }
        // The caret away from the user's cursor with nothing under way (an edit's unit or a walk that stopped): it goes back.
        if cursor != userCursor, userLost == nil { return send(.move(units(to: userCursor)), lane: .edit, moveTo: userCursor) }
        if config.prioritizeSpeech, isSpeaking {
            if let action = nextLive() { return action }
            return .idle
        }
        if let action = nextEdit() { return action }
        if let action = nextLive() { return action }
        return .idle
    }

    /// The user's next item is a key (or delete) that still waits for the take's text already heard (#268).
    private var keysWait: Bool {
        guard config.keysWaitForTake, keyHeldMs < keyHoldLimitMs, selection == 0, !quietAfterMove,
              case .input(let input, _)? = userLane.first else { return false }
        if case .move = input { return false }
        return true
    }

    /// Graphemes the keys wait for (`flushBeforeKeys`): typed lines queued at the cursor, then a stopped or complete
    /// take's untyped end.
    private func takeBacklog() -> Int {
        guard config.keysWaitForTake else { return 0 }
        var count = editLane.prefix { $0.edit.kind == .typist }.reduce(0) { $0 + $1.edit.target.count }
        if let (ri, pi) = openPieceIndex(), runs[ri].complete || runs[ri].stopped, let span = spans[runs[ri].pieces[pi].spanID] {
            count += heldAppend(runs[ri].pieces[pi], in: runs[ri], span: span).count
        }
        return count
    }

    /// What the open piece still appends at its end (the cursor) before the keys: its untyped end.
    private func heldAppend(_ piece: Piece, in run: LiveRun, span: Span) -> [Character] {
        let desired = Array(desiredText(piece, in: run)), current = chars(of: span)
        return desired.starts(with: current) ? Array(desired[current.count...]) : []
    }

    /// Jakob's rule for a key pressed while the take is still being typed: the text already heard goes in first, at
    /// the floor pace, one grapheme an op; the keys then land in order after it. Typed lines queued at the cursor go
    /// first, then the open piece's untyped end once the take was stopped (while it is still spoken, keys go at once
    /// as before: a word cut short is finished, later words follow the keys). A stopped take holds the keys until it is
    /// complete: its final words, still on their way at the stop, go in before them too. Only appends: the keys never
    /// wait for a revision or the stop's swap. Nil: nothing to wait for (the keys go).
    private mutating func flushBeforeKeys() -> Action? {
        if editLane.first?.edit.kind == .typist {
            var state = editLane.removeFirst()
            switch start(&state, lane: .edit) {
            case .started: return nextInUnit()
            case .sent(let action): return action
            case .wait: editLane.insert(state, at: 0); return .wait
            case .done: return flushBeforeKeys()
            }
        }
        guard let (last, _) = openPieceIndex(), runs[last].complete || runs[last].stopped else { return nil }
        // A stopped take's later snapshots bring its final words: they are the take's, heard before the key.
        applyPending(last)
        guard let (ri, pi) = openPieceIndex() else { return nil }
        let piece = runs[ri].pieces[pi]
        guard let span = spans[piece.spanID], !span.parked, !span.userChanged, !span.edited, span.end == userCursor else { return nil }
        let rest = heldAppend(piece, in: runs[ri], span: span)
        // All typed: a stopped take still to complete holds the keys (bounded) for its final words.
        guard !rest.isEmpty else { return runs[ri].complete ? nil : .wait }
        // Nothing of the keyboard's own goes on a model the report does not show at the caret (the keys wait, bounded).
        guard lastReport.map(consistent) ?? true else { return .wait }
        if cursor != userCursor { return .wait }
        let slice = Array(rest.prefix(config.animated ? 1 : rest.count))
        let spanID = piece.spanID
        return send(.insert(String(slice)), lane: .live) { q in
            q.insertAtCursor(slice, owner: spanID)
            q.userCursor = q.cursor
        }
    }

    private mutating func nextUser() -> Action? {
        while let item = userLane.first {
            if !item.isMove { for (id, span) in spans where span.parked { spans[id]?.userActedParked = true } }
            switch item {
            case .input(let input, let retried):
                if case .insert(let key) = input, let finish = finishWordBeforeKey(key) { userLane.removeFirst(); return finish }
                userLane.removeFirst()
                if case .move = input { closeOpenPieces(.cursor) } else { closeOpenPieces(.keystroke) }
                if let action = sendUser(input, retried: retried) { return action }
            case .edit(var state):
                userLane.removeFirst()
                closeOpenPieces(.edit)
                switch start(&state, lane: .user) {
                case .started: return nextInUnit()
                case .sent(let action): return action
                case .wait: drop(state, .changed); continue
                case .done: continue
                }
            }
        }
        return nil
    }

    private mutating func sendUser(_ input: Input, retried: Bool) -> Action? {
        switch input {
        case .insert(var key):
            // The key cut a dictated word short and waited for it: it starts a word of its own (as `finishWordBeforeKey`).
            if keyCutWord, selection == 0, cursor > 0, text[cursor - 1].isLetter || text[cursor - 1].isNumber,
               key.first.map({ $0.isLetter || $0.isNumber }) ?? false { key = " " + key }
            keyCutWord = false
            let action = send(.insert(key), lane: .user) { q in
                if q.selection > 0 { q.removeRange(q.cursor, q.cursor + q.selection, owner: nil); q.selection = 0 }
                q.insertAtCursor(Array(key), owner: nil)
                q.userCursor = q.cursor
            }
            inFlight?.input = .insert(key); inFlight?.retried = retried
            return action
        case .deleteBackward:
            guard selection > 0 || cursor > 0 else {
                // Nothing known before the cursor: the delete goes out and the next report says what it did.
                let action = send(.deleteBackward(1), lane: .user, anywhere: true) { _ in }
                inFlight?.input = input
                return action
            }
            let action = send(.deleteBackward(1), lane: .user) { q in
                if q.selection > 0 { q.removeRange(q.cursor, q.cursor + q.selection, owner: nil); q.selection = 0 }
                else { q.removeRange(q.cursor - 1, q.cursor, owner: nil) }
                q.userCursor = q.cursor
            }
            inFlight?.input = input; inFlight?.retried = retried
            return action
        case .move(let characters):
            let target = max(0, min(text.count, userCursor + characters))
            if selection > 0 {
                let units = target == userCursor ? 0 : units(to: target)
                let action = send(.move(units), lane: .user, anywhere: true) { q in q.selection = 0 }
                inFlight?.input = input
                return action
            }
            userLost = nil
            guard target != cursor else { userCursor = cursor; return nil }
            let action = send(.move(units(to: target)), lane: .user, moveTo: target)
            userCursor = cursor
            inFlight?.input = input
            return action
        }
    }

    /// A key at the open piece's end while the typewriter has shown only part of a word: the word's rest goes in
    /// with the key, in one insert (with a space when the key starts a word), so the key lands after the word.
    private mutating func finishWordBeforeKey(_ key: String) -> Action? {
        guard let restChars = openPieceWordRest(), let (ri, pi) = openPieceIndex() else { return nil }
        keyCutWord = false
        let rest = String(restChars)
        let spacer = (key.first.map { $0.isLetter || $0.isNumber } ?? false) ? " " : ""
        let spanID = runs[ri].pieces[pi].spanID
        let action = send(.insert(rest + spacer + key), lane: .user) { q in
            q.insertAtCursor(Array(rest), owner: spanID)
            q.closeOpenPieces(.keystroke)
            q.insertAtCursor(Array(spacer + key), owner: nil)
            q.userCursor = q.cursor
        }
        inFlight?.input = .insert(rest + spacer + key)
        return action
    }

    private mutating func nextEdit() -> Action? {
        var index = 0
        while index < editLane.count {
            var state = editLane[index]
            editLane.remove(at: index)
            switch start(&state, lane: .edit) {
            case .started: return nextInUnit()
            case .sent(let action): return action
            case .wait: editLane.insert(state, at: index); index += 1
            case .done: break
            }
        }
        return nil
    }

    private enum StartResult { case started, sent(Action), wait, done }

    /// Places an edit (if not yet), plans its jump unit against the model now, or drops it.
    private mutating func start(_ state: inout EditState, lane: Lane) -> StartResult {
        if state.spanID == nil {
            if let selected = state.edit.selected {
                guard selection > 0, String(text[cursor..<(cursor + selection)]) == selected else {
                    drop(state, .selectionChanged); return .done
                }
                // Collapse the selection first (hosts differ about which end); the scope is then known text.
                let span = Span(start: cursor, end: cursor + selection)
                let id = addSpan(span)
                state.spanID = id
                state.edit.cursorAtEnd = true
                if lane == .user { userLane.insert(.edit(state), at: 0) } else { editLane.insert(state, at: 0) }
                closeOpenPieces(.edit)
                return .sent(send(.move(0), lane: lane, anywhere: true) { q in q.selection = 0 })
            }
            if state.edit.atCursor {
                state.spanID = addSpan(Span(start: userCursor, end: userCursor))
            } else if let found = placeThroughRead(state.edit) {
                // Through the changes since the read: the user's cancel it, the keyboard's own merge into the target.
                guard case .placed(let id, let target) = found else { drop(state, .userEdited); return .done }
                state.spanID = id; state.edit.target = target
                finishSpan(state.anchorID); state.anchorID = nil
                if state.edit.kind == .magic { closeOpenPieces(.edit) }
            } else {
                let placement = place(state.edit, anchor: state.anchorID)
                switch placement {
                case .placed(let id): state.spanID = id; finishSpan(state.anchorID); state.anchorID = nil
                case .ambiguous, .absent:
                    // The report may still catch up with a cursor move; past the grace the text is not there.
                    state.unplacedMs += stepElapsedMs
                    if lane == .edit, state.unplacedMs < Self.placeGraceMs { return .wait }
                    if config.canReadAround, lane == .edit, !state.edit.atCursor, state.edit.selected == nil,
                       !(state.edit.before + state.edit.after).isEmpty {
                        var pending = Span(start: userCursor, end: userCursor)
                        pending.parked = true; pending.lastText = Array(state.edit.before + state.edit.after)
                        state.spanID = addSpan(pending)
                        requestRecoveryIfNeeded()
                        if recoveryRequest != nil { return .wait }
                    }
                    drop(state, placement == .ambiguous ? .unplaceable : .changed); return .done
                }
                if state.edit.kind == .magic { closeOpenPieces(.edit) }
            }
        }
        guard let id = state.spanID, let span = spans[id] else { drop(state, .changed); return .done }
        if span.userChanged { drop(state, .userEdited); return .done }
        if span.parked {
            requestRecoveryIfNeeded()
            if recoveryRequest != nil { return .wait }
            // Out of sight after a resync: an edit waits a while for its text to show again, then drops.
            state.unplacedMs += stepElapsedMs
            if lane == .edit, state.unplacedMs < Self.parkLimitMs { return .wait }
            drop(state, .unplaceable); return .done
        }
        let current = chars(of: span)
        let target = Array(state.edit.target)
        if current == target {
            if state.edit.cursorAtEnd, userCursor != span.end {
                state.attempts += 1
                unit = Unit(ops: [.moveToSpanEnd(id), .setUserCursorToCursor], owner: .edit(state, lane), paced: false)
                return .started
            }
            if cursor != userCursor {
                unit = Unit(ops: [.moveToUser], owner: .edit(state, lane), paced: false)
                return .started
            }
            applied(state)
            return .done
        }
        state.attempts += 1
        guard state.attempts <= 4 else { drop(state, .unplaceable); return .done }
        let paced = state.edit.paced && config.animated
        var ops = plan(spanID: id, from: current, to: target, paced: paced)
        ops += state.edit.cursorAtEnd ? [.moveToSpanEnd(id), .setUserCursorToCursor] : [.moveToUser]
        unit = Unit(ops: ops, owner: .edit(state, lane), paced: paced)
        return .started
    }

    /// Exact changes, back to front, grouped for cursor jumps. Every unchanged character stays in the host;
    /// deleting a changed range is still one confirmed grapheme per operation. Insertions animate when paced.
    private func plan(spanID: Int, from current: [Character], to target: [Character], paced: Bool) -> [QOp] {
        guard spans[spanID] != nil else { return [] }
        func typed(_ text: [Character]) -> [QOp] {
            guard !text.isEmpty else { return [] }
            return paced ? text.map { .insert(String($0), owner: spanID) } : [.insert(String(text), owner: spanID)]
        }
        var ops: [QOp] = []
        // Growth at the end of the open region at the cursor is typed by the append path, not inside a unit.
        let groups: [[SpanPlanner.Hunk]] = SpanPlanner.spans(from: current, to: target, leaveTailAppend: false, paceMs: paced ? SpanPlanner.calmMs : 0,
                                                             moveSettleMs: Self.moveSettleMs, editSettleMs: Self.editSettleMs)
            .map { $0.block ? [SpanPlanner.Hunk(start: $0.start, end: $0.end, text: $0.text)] : $0.hunks }
        let base = spans[spanID]!.start
        for hunks in groups.reversed() {
            for hunk in hunks.reversed() {
                if emptiesLine(base + hunk.start, base + hunk.end), !hunk.text.isEmpty {
                    // Never an empty line mid-replacement: a rich editor puts a placeholder line break into a line that
                    // becomes empty (and may drop the line's list or block). The line's last old grapheme stays until the
                    // new text stands before it.
                    ops.append(.moveInSpan(spanID, offset: hunk.end - 1))
                    if hunk.end - 1 > hunk.start { ops.append(.delete(hunk.end - 1 - hunk.start, owner: spanID)) }
                    ops += typed(hunk.text)
                    ops.append(.moveInSpan(spanID, offset: hunk.start + hunk.text.count + 1))
                    ops.append(.delete(1, owner: spanID))
                    continue
                }
                ops.append(.moveInSpan(spanID, offset: hunk.end))
                if hunk.end > hunk.start { ops.append(.delete(hunk.end - hunk.start, owner: spanID)) }
                ops += typed(hunk.text)
            }
        }
        return ops
    }

    /// Deleting the model's `a..<b` leaves its line empty: a line break (or the known text's edge) on both sides, and a
    /// real line break on at least one. A single-line field (or text the model knows no line break around) has no line
    /// for a rich editor to fill, so a whole replacement there goes as one block.
    private func emptiesLine(_ a: Int, _ b: Int) -> Bool {
        let breakBefore = a > 0 && text[a - 1].isNewline, breakAfter = b < text.count && text[b].isNewline
        return b > a && (a == 0 || breakBefore) && (b == text.count || breakAfter) && (breakBefore || breakAfter)
    }

    /// Typed graphemes still to come besides the unit's: the open pieces' append, and the queued edits' estimates.
    private func queuedBacklog() -> Int {
        var count = editLane.reduce(0) { $0 + $1.typedEstimate }
        for item in userLane { if case .edit(let state) = item { count += state.typedEstimate } }
        for run in runs {
            for piece in run.pieces where piece.tEnd == nil {
                guard let span = spans[piece.spanID], !span.parked else { continue }
                count += max(0, desiredText(piece, in: run).count - (span.end - span.start))
            }
        }
        return count
    }

    /// Whether a typed grapheme may go now: at the faster of the unit's own pace and the backlog's (`ops` still to
    /// go), with the last wait's overshoot carried over, since the keyboard steps on a 33 ms tick.
    private func paceAllows(unitPaceMs: Double = SpanPlanner.calmMs, ops: Int) -> (go: Bool, credit: Double) {
        let pace = min(unitPaceMs, SpanPlanner.paceMs(ops: ops))
        let due = sinceSendMs + paceCreditMs
        return (due >= pace, min(max(0, due - pace), pace - Self.charMs))
    }

    private mutating func nextInUnit() -> Action {
        while var current = unit {
            guard !current.ops.isEmpty else {
                unit = nil
                finishUnit(current.owner)
                if inFlight != nil { return .wait }
                return next()
            }
            let op = current.ops[0]
            switch op {
            case .moveInSpan(let id, let offset):
                current.ops.removeFirst(); unit = current
                guard let span = spans[id], !span.parked else { unit = nil; requeue(current.owner); return .wait }
                let target = min(max(0, span.start + offset), text.count)
                if target != cursor { return jump(to: target, span: id, lane: lane(of: current.owner)) }
            case .moveToUser:
                current.ops.removeFirst(); unit = current
                if userCursor != cursor {
                    return send(.move(units(to: userCursor)), lane: lane(of: current.owner), moveTo: userCursor)
                }
            case .moveToSpanEnd(let id):
                current.ops.removeFirst(); unit = current
                if let end = spans[id]?.end, end != cursor { return jump(to: end, span: id, lane: lane(of: current.owner)) }
            case .setUserCursorToCursor:
                current.ops.removeFirst(); unit = current
                userCursor = cursor
            case .startRegion(let runID, let tStart, let anchor):
                current.ops.removeFirst(); unit = current
                if let ri = runs.firstIndex(where: { $0.runID == runID }) {
                    let id = addSpan(Span(start: userCursor, end: userCursor))
                    runs[ri].pieces.append(Piece(spanID: id, tStart: tStart, anchor: anchor, startSegment: startSegment(at: tStart, in: runs[ri])))
                    events.append(.regionStarted(runID: runID, anchorChars: anchor.count))
                }
            case .delete(let count, let owner):
                guard cursor >= count, count > 0 else { unit = nil; requeue(current.owner); return .wait }
                if count > 1 { current.ops[0] = .delete(count - 1, owner: owner) } else { current.ops.removeFirst() }
                unit = current
                return send(.deleteBackward(1), lane: lane(of: current.owner)) { q in q.removeRange(q.cursor - 1, q.cursor, owner: owner) }
            case .insert(let chars, let owner):
                var credit = 0.0
                if current.paced {
                    let remaining = current.ops.reduce(0) { if case .insert = $1 { $0 + 1 } else { $0 } }
                    let pace = paceAllows(unitPaceMs: current.paceMs, ops: remaining + queuedBacklog())
                    guard pace.go else { return .wait }
                    credit = pace.credit
                }
                current.ops.removeFirst(); unit = current
                let action = send(.insert(chars), lane: lane(of: current.owner)) { q in q.insertAtCursor(Array(chars), owner: owner) }
                paceCreditMs = credit
                return action
            case .insertBehind(let chars):
                current.ops.removeFirst(); unit = current
                let action = send(.insert(chars), lane: lane(of: current.owner)) { q in q.insertAtCursor(Array(chars), owner: nil, behindUser: true) }
                events.append(.insertedBehind)
                return action
            }
        }
        return next()
    }

    /// A move to a span's place: if it goes nowhere, the span is not in this field (`jumpFailed`).
    private mutating func jump(to target: Int, span id: Int, lane: Lane) -> Action {
        let action = send(.move(units(to: target)), lane: lane, moveTo: target)
        inFlight?.jumpSpan = id
        return action
    }

    private func lane(of owner: UnitOwner) -> Lane {
        switch owner {
        case .edit(_, let lane): lane
        case .space: .live
        }
    }

    private mutating func finishUnit(_ owner: UnitOwner) {
        guard case .edit(var state, let lane) = owner else { return }
        guard let id = state.spanID, let span = spans[id] else { drop(state, .changed); return }
        if chars(of: span) == Array(state.edit.target), cursor == userCursor,
           !state.edit.cursorAtEnd || userCursor == span.end {
            applied(state)
        } else {
            state.unplacedMs = 0
            if lane == .user { userLane.insert(.edit(state), at: 0) } else { editLane.insert(state, at: 0) }
        }
    }

    /// The unit stops where it is; its item is planned again from the model later.
    private mutating func abortUnit() {
        guard let current = unit else { return }
        unit = nil
        requeue(current.owner)
    }

    private mutating func requeue(_ owner: UnitOwner) {
        guard case .edit(var state, let lane) = owner else { return }
        state.unplacedMs = 0
        if lane == .user { userLane.insert(.edit(state), at: 0) } else { editLane.insert(state, at: 0) }
    }

    private mutating func applied(_ state: EditState) {
        guard let id = state.spanID, let span = spans[id] else { return }
        let offset = min(max(0, userCursor - span.start), span.end - span.start)
        let cursorUnits = String(text[span.start..<(span.start + offset)]).utf16.count
        spans[id] = nil; finishSpan(state.anchorID)
        events.append(.applied(id: state.edit.id, cursor: cursorUnits))
    }

    private mutating func drop(_ state: EditState, _ reason: DropReason) {
        var partial: String?
        if let id = state.spanID, let span = spans[id], !span.parked, inFlight == nil { partial = String(chars(of: span)) }
        finishSpan(state.spanID); finishSpan(state.anchorID)
        events.append(.dropped(Drop(id: state.edit.id, runID: nil, kind: state.edit.kind, reason: reason,
                                    text: state.edit.target, partial: partial)))
    }

    private mutating func finishSpan(_ id: Int?) { if let id { spans[id] = nil } }

    // MARK: Live

    /// The take's words as delivered at the caret while it runs: only new speech extends them. Each revision is aligned
    /// with what was delivered word by word (the longest common subsequence, earliest where it is ambiguous): the words
    /// after the last delivered word are new. A re-split of delivered words is no new speech, a filler dropped or a word
    /// revised before the end still pins the end, and a last word the revision changed leaves the revision deferred.
    /// Where repetitive text makes the place ambiguous the earliest one is taken, so words are left out rather than
    /// typed twice (the stop's swap brings them).
    struct SpeechDelivery: Sendable, Equatable {
        private(set) var delivered: [Character] = []
        private(set) var authoritative: [Character] = []
        var hasDeferredRevision: Bool { authoritative != delivered }

        /// `complete`: the take ended, its text may be a cleanup: only new words extend the delivered text, never a
        /// cleanup's punctuation after the last delivered word.
        /// Returns where the appended text starts: in `text`, and in the delivered text.
        @discardableResult
        mutating func update(_ text: [Character], complete: Bool = false) -> (text: Int, delivered: Int)? {
            authoritative = text
            var end: Int
            if delivered.isEmpty || text.starts(with: delivered) { end = delivered.count }
            else if let found = Self.end(of: delivered, in: text) { end = found }
            else { return nil }
            if complete, !delivered.isEmpty {
                guard let word = text[end...].firstIndex(where: { $0.isLetter || $0.isNumber }) else { return nil }
                if word > end, text[end..<word].contains(where: \.isWhitespace) || text[end..<word].contains(where: \.isNewline) {
                    delivered.append(text[end..<word].contains(where: \.isNewline) ? "\n" : " ")
                }
                end = word
            }
            let at = delivered.count
            delivered += text[end...]
            return (end, at)
        }

        /// The field shows `text` for the take (a verified revision near the caret, or words appended at once).
        mutating func settle(_ text: [Character]) { delivered = text; authoritative = text }

        static let alignedWords = 160

        private static func words(_ text: [Character]) -> [(end: Int, word: String)] {
            var result: [(Int, String)] = [], i = 0
            while i < text.count {
                guard text[i].isLetter || text[i].isNumber else { i += 1; continue }
                let start = i
                while i < text.count, text[i].isLetter || text[i].isNumber { i += 1 }
                result.append((i, String(text[start..<i]).lowercased()))
            }
            return result
        }

        /// Where the delivered text's last word ends in `text`, or nil when that word is not there (or the words before it
        /// do not corroborate it).
        static func end(of delivered: [Character], in text: [Character]) -> Int? {
            let old = Array(words(delivered).suffix(alignedWords)), all = words(text)
            guard let last = old.last, delivered[last.end...].allSatisfy({ !($0.isLetter || $0.isNumber) }) else { return nil }
            let new = Array(all.suffix(old.count + alignedWords))
            let a = old.map(\.word), b = new.map(\.word)
            guard !b.isEmpty else { return nil }
            var table = [[Int]](repeating: [Int](repeating: 0, count: b.count + 1), count: a.count + 1)
            for i in stride(from: a.count - 1, through: 0, by: -1) {
                for j in stride(from: b.count - 1, through: 0, by: -1) {
                    table[i][j] = a[i] == b[j] ? table[i + 1][j + 1] + 1 : max(table[i + 1][j], table[i][j + 1])
                }
            }
            var matches: [Int: Int] = [:]
            var i = 0, j = 0
            while i < a.count, j < b.count {
                if a[i] == b[j], table[i][j] == table[i + 1][j + 1] + 1 { matches[i] = j; i += 1; j += 1 }
                else if table[i][j + 1] >= table[i + 1][j] { j += 1 } else { i += 1 }
            }
            // The last word, and most of the few before it, stand in the revision.
            guard let at = matches[a.count - 1] else { return nil }
            let recent = max(0, a.count - 4)..<(a.count - 1)
            guard recent.filter({ matches[$0] != nil }).count >= min(2, recent.count) else { return nil }
            return new[at].end
        }
    }

    /// One stretch of a run's words in the field, typed at one place. A user key, a cursor move or a resync ends the
    /// open piece; the run's later words start a new piece at the user's caret.
    struct Piece: Sendable, Equatable {
        var spanID: Int
        /// Where its words start in the run's delivered text (`LiveRun.delivered`).
        var tStart: Int
        /// Where they end; nil for the open piece, which takes every word delivered after `tStart`.
        var tEnd: Int?
        /// The field's text before it when it started: the first word's capital and the space before it.
        var anchor: String
        /// The segment its words start with: its final text is known on its own (nil: it starts inside a segment).
        var startSegment: Int?
        /// The user typed, deleted or moved the caret since it was typed: the keyboard never edits it again.
        var frozen = false
        /// The text a swap put in, standing for the delivered words before `swappedEnd`.
        var swapped: [Character]?
        var swappedEnd = 0
    }

    private func runNeedsWork(_ run: LiveRun) -> Bool {
        if run.pending != nil || swap?.runID == run.runID { return true }
        if run.complete, run.version != nil, run.settledVersion != run.version, !run.pieces.isEmpty { return true }
        if let piece = run.pieces.last(where: { $0.tEnd == nil }), let span = spans[piece.spanID] {
            if span.parked || span.end != userCursor || chars(of: span) != Array(desiredText(piece, in: run)) { return true }
        }
        return untypedRest(of: run) != nil
    }

    /// Delivered text after the last piece that still has to be typed (the start of a new piece), if any.
    private func untypedRest(of run: LiveRun) -> Int? {
        guard runs.last?.runID == run.runID, !run.pieces.contains(where: { $0.tEnd == nil }) else { return nil }
        let from = max(run.settledThrough, run.pieces.compactMap(\.tEnd).max() ?? 0)
        guard from < run.delivered.count, run.delivered[from...].contains(where: { !$0.isWhitespace }) else { return nil }
        return from
    }

    private mutating func nextLive() -> Action? {
        for ri in runs.indices { applyPending(ri) }
        if swap != nil { return nextSwap() ?? .wait }
        for ri in runs.indices {
            if let action = settleFinal(ri) { return action }
            if swap != nil { return nextSwap() ?? .wait }
            if let action = typeOpenPiece(ri) { return action }
            if let from = untypedRest(of: runs[ri]) {
                guard reportStableMs >= Self.stableMs || !config.animated else { return .wait }
                let anchor = String(text[max(0, userCursor - 200)..<userCursor])
                // A reseed can leave the caret away from the user's cursor: the piece starts at the user's cursor.
                var ops: [QOp] = cursor == userCursor ? [] : [.moveToUser]
                if userCursor < text.count, !text[userCursor].isWhitespace, !Self.closingMarks.contains(text[userCursor]) {
                    // The run starts in front of text without a space: one goes in behind it, and the caret stays before it.
                    ops += [.insertBehind(" "), .moveToUser]
                }
                ops.append(.startRegion(run: runs[ri].runID, tStart: from, anchor: anchor))
                unit = Unit(ops: ops, owner: .space, paced: false)
                return nextInUnit()
            }
            ack(ri)
        }
        let newest = runs.last?.runID
        // A finished run stays while a later version may still come (it is settled or reported, never typed at the
        // caret), up to the last few runs. A retired run's later versions are ignored.
        let finished = runs.filter { $0.runID != newest && !runNeedsWork($0) && $0.ackedVersion == $0.version && $0.complete }
        let keptFrom = runs.count - Self.keptRuns
        let settled = finished.filter { run in run.cleaned || (runs.firstIndex { $0.runID == run.runID } ?? 0) < keptFrom }.map(\.runID)
        runs.removeAll { settled.contains($0.runID) }
        retiredRunIDs += settled
        if retiredRunIDs.count > 32 { retiredRunIDs.removeFirst(retiredRunIDs.count - 32) }
        return nil
    }

    /// The open piece of run `ri` at the user's caret: its delivered words go in one grapheme at a time; a revision of
    /// its last words (`nearChars`) goes in once the report shows the text it deletes.
    private mutating func typeOpenPiece(_ ri: Int) -> Action? {
        guard let pi = runs[ri].pieces.lastIndex(where: { $0.tEnd == nil }) else { return nil }
        let piece = runs[ri].pieces[pi]
        if spans[piece.spanID]?.parked == true {
            // Out of sight after a resync: it waits a moment to be found again at the caret.
            parkedPieceMs += stepElapsedMs
            guard parkedPieceMs >= Self.placeGraceMs else { return .wait }
        }
        parkedPieceMs = 0
        guard let span = spans[piece.spanID], !span.parked, !span.userChanged, !span.edited, selection == 0, span.end == userCursor else {
            // Not at the user's caret any more (or lost): the piece ends, later words start at the caret. Nothing
            // explains where it went, so it is never edited again.
            closeOpenPieces(.resync, ri: ri, freeze: true)
            return nil
        }
        let current = chars(of: span)
        var desired = Array(desiredText(piece, in: runs[ri]))
        if desired == current, !runs[ri].speech.hasDeferredRevision { return nil }
        if cursor != userCursor { return send(.move(units(to: userCursor)), lane: .live, moveTo: userCursor) }
        if nearRevision(ri, pi) { desired = Array(desiredText(runs[ri].pieces[pi], in: runs[ri])) }
        guard desired != current else { return nil }
        if desired.starts(with: current) {
            // One grapheme per op when animated, at the backlog's pace.
            var count = desired.count - current.count, credit = 0.0
            if config.animated {
                let pace = paceAllows(ops: queuedBacklog())
                guard pace.go else { return .wait }
                count = 1; credit = pace.credit
            }
            let slice = Array(desired[current.count..<(current.count + count)])
            let spanID = piece.spanID
            let action = send(.insert(String(slice)), lane: .live) { q in
                q.insertAtCursor(slice, owner: spanID)
                q.userCursor = q.cursor
            }
            paceCreditMs = credit
            return action
        }
        // A verified revision of the last words: what differs goes, then is typed again.
        let k = current.count - Self.commonPrefix(current, desired)
        guard k <= Self.nearChars, verifiesBefore(k, span: span) else {
            closeOpenPieces(.resync, ri: ri)
            return nil
        }
        let spanID = piece.spanID
        return send(.deleteBackward(k), lane: .live) { q in q.removeRange(q.cursor - k, q.cursor, owner: spanID) }
    }

    /// While the take runs, a revision of the open piece's last words (every changed character within `nearChars`
    /// of the caret, and the field's report showing them as typed) is taken now; anything else waits for the stop.
    private mutating func nearRevision(_ ri: Int, _ pi: Int) -> Bool {
        let run = runs[ri], piece = run.pieces[pi]
        guard !run.complete, run.speech.hasDeferredRevision, !piece.frozen, let span = spans[piece.spanID] else { return false }
        let delivered = run.speech.delivered, revised = run.speech.authoritative
        let from = Self.commonPrefix(delivered, revised)
        // A contraction alone (a word taken back) waits: ASR takes words back and forth, and the stop settles it.
        guard revised.count > from, delivered.count - from <= Self.nearChars,
              from >= (piece.swapped == nil ? piece.tStart : piece.swappedEnd) else { return false }
        var trial = run
        trial.speech.settle(revised)
        let desired = Array(desiredText(piece, in: trial)), current = chars(of: span)
        let k = current.count - Self.commonPrefix(current, desired)
        guard k <= Self.nearChars, k == 0 || verifiesBefore(k, span: span) else { return false }
        runs[ri].speech.settle(revised)
        runs[ri].speechStarts = Self.segmentStarts(of: runs[ri].speechSegments)
        return true
    }

    /// The field's report shows the `k` characters before the caret as the model has them.
    private func verifiesBefore(_ k: Int, span: Span) -> Bool {
        guard k <= span.end - span.start, span.end == cursor, cursor == userCursor, selection == 0, let report = lastReport,
              report.selected == nil, FieldReader.trusted(before: report.before).count >= k else { return false }
        return FieldMatch.positions(in: text, reportedBefore: report.before, reportedAfter: report.after).contains(cursor)
    }

    static func commonPrefix(_ a: [Character], _ b: [Character]) -> Int { zip(a, b).prefix { $0 == $1 }.count }

    private mutating func ack(_ ri: Int) {
        let run = runs[ri]
        // A deferred revision is not in the field yet: the version is not shown.
        guard !(run.speech.hasDeferredRevision && !run.complete), let version = run.version, run.pending == nil,
              run.ackedVersion != version, !runNeedsWork(run), inFlight == nil else { return }
        runs[ri].ackedVersion = version
        events.append(.liveApplied(runID: run.runID, version: version, complete: run.complete))
    }

    private static let closingMarks: Set<Character> = [",", ".", ";", ":", "!", "?", ")", "]", "}", "%", "…", "\u{2019}", "\u{201D}"]
    /// Segments join without a space before these (or a line break), and after an opening mark.

    /// The newest snapshot of a run becomes its target.
    private mutating func applyPending(_ ri: Int) {
        guard let snapshot = runs[ri].pending else { return }
        runs[ri].pending = nil
        apply(snapshot, to: ri)
    }

    /// A snapshot's words go to the run's delivered text (`SpeechDelivery`: only new speech extends it). Its segments
    /// say what each piece's final text is.
    private mutating func apply(_ snapshot: LiveDictationSnapshot, to ri: Int) {
        runs[ri].version = snapshot.version
        if snapshot.stopped == true { runs[ri].stopped = true }
        runs[ri].complete = runs[ri].complete || snapshot.complete
        runs[ri].cleaned = runs[ri].complete && !snapshot.segments.isEmpty && snapshot.segments.allSatisfy { $0.final && $0.cleaned }
        runs[ri].segments = snapshot.segments
        // Its words as spoken (a cleaned unit shows its raw words) extend the delivered text where they go on past it
        // (`SpeechDelivery`): while the take runs and after (the run goes on after a stop; its final words).
        let speech = Self.speech(snapshot.segments)
        runs[ri].speechSegments = speech
        let appended = runs[ri].speech.update(Array(Self.joined(speech)), complete: runs[ri].complete)
        let starts = Self.segmentStarts(of: speech)
        if !runs[ri].speech.hasDeferredRevision {
            runs[ri].speechStarts = starts
        } else if let appended {
            // Segments that start in the appended words start there in the delivered text too.
            for (id, start) in starts where start >= appended.text { runs[ri].speechStarts[id] = appended.delivered + start - appended.text }
        }
    }

    /// The take's words as spoken: a cleaned unit shows its raw words while there are any.
    static func speech(_ segments: [LiveSegment]) -> [LiveSegment] {
        segments.map { segment in
            var segment = segment
            if segment.cleaned { segment.text = segment.raw ?? segment.text }
            segment.cleaned = false; segment.unit = nil
            return segment
        }
    }

    /// A space goes between two segments unless the second starts with closing punctuation (or a line break), or the
    /// first ends with an opening mark: "from" and ", like" join as "from, like" (`LiveSegment.joined`).
    static func spaced(_ last: Character?, _ first: Character) -> Bool { LiveSegment.spaced(last, first) }

    /// Where each non-empty segment's text starts in `joined(segments)`.
    static func segmentStarts(of segments: [LiveSegment]) -> [Int: Int] {
        var starts: [Int: Int] = [:], count = 0
        var last: Character?
        for segment in segments {
            let text = segment.text.trimmingCharacters(in: .whitespaces)
            guard let first = text.first else { continue }
            if spaced(last, first) { count += 1 }
            starts[segment.id] = count
            count += text.count; last = text.last
        }
        return starts
    }

    /// The segments of a run where a piece of it starts in the field after the first: the user typed or moved between it
    /// and the words before. The app cleans the pieces apart.
    public func pieceStarts(of runID: String) -> [Int] {
        guard let run = runs.first(where: { $0.runID == runID }) else { return [] }
        return Array(Set(run.pieces.dropFirst().compactMap(\.startSegment))).sorted()
    }

    /// A snapshot's text: its segments, trimmed, joined by a space where a reader expects one.
    static func target(of snapshot: LiveDictationSnapshot) -> String { joined(snapshot.segments) }

    static func joined(_ segments: some Sequence<LiveSegment>) -> String { LiveSegment.joined(segments.map(\.text)) }

    /// What a piece shows: its delivered words (after a swap's text), separated and capitalised against its anchor.
    private func desiredText(_ piece: Piece, in run: LiveRun) -> String {
        let delivered = run.delivered
        let end = min(delivered.count, piece.tEnd ?? delivered.count)
        if let swapped = piece.swapped {
            let from = min(piece.swappedEnd, end)
            return String(swapped) + DictationTypist.prepare(String(delivered[from..<end]), contextBefore: piece.anchor + String(swapped),
                                                             capitalization: config.capitalization)
        }
        let start = min(piece.tStart, end)
        return DictationTypist.prepare(String(delivered[start..<end]), contextBefore: piece.anchor, capitalization: config.capitalization)
    }

    /// A piece's final text from the newest snapshot: its own segments (cleaned), when it starts with one and no cleanup
    /// unit crosses its edges. Nil when it cannot be known on its own.
    private func finalText(_ pi: Int, in run: LiveRun) -> [Character]? {
        let piece = run.pieces[pi]
        guard let start = piece.startSegment else { return nil }
        var end = Int.max
        if pi + 1 < run.pieces.count {
            guard let next = run.pieces[pi + 1].startSegment else { return nil }
            end = next
        }
        let own = run.segments.filter { $0.id >= start && $0.id < end }
        guard own.allSatisfy(\.final), !own.contains(where: { ($0.unit ?? $0.id) < start }),
              !run.segments.contains(where: { $0.id >= end && ($0.unit.map { $0 < end } ?? false) }) else { return nil }
        return Array(DictationTypist.prepare(Self.joined(own), contextBefore: piece.anchor, capitalization: config.capitalization))
    }

    /// The segment whose words start at delivered offset `from` (after its spaces), while the delivered text is the
    /// speech as published.
    private func startSegment(at from: Int, in run: LiveRun) -> Int? {
        var at = from
        while at < run.delivered.count, run.delivered[at].isWhitespace { at += 1 }
        // The take's start is its first segment's, whatever was revised since.
        if at == 0 || run.delivered[..<at].allSatisfy(\.isWhitespace) {
            return run.speechSegments.first { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }?.id
        }
        return run.speechStarts.filter { $0.value == at }.map(\.key).min()
    }

    private func openPieceIndex() -> (Int, Int)? {
        guard let ri = runs.indices.last, let pi = runs[ri].pieces.lastIndex(where: { $0.tEnd == nil }) else { return nil }
        return (ri, pi)
    }

    /// The user took over (or a resync), or the piece lost its place (`only`): open pieces end at the end of the word
    /// typed so far. Every piece before a user action is frozen: the keyboard never edits it again (its final text is
    /// in History).
    private mutating func closeOpenPieces(_ cause: CloseCause, ri only: Int? = nil, freeze: Bool? = nil) {
        // Anything but the next run may be the user's doing (a resync is a change the model cannot explain): the pieces
        // before it are never corrected.
        let freezes = freeze ?? (cause != .newRun && only == nil)
        for ri in runs.indices where only == nil || only == ri {
            if only == nil { applyPending(ri) }
            if freezes {
                for pi in runs[ri].pieces.indices { runs[ri].pieces[pi].frozen = true }
                if swap?.runID == runs[ri].runID, swap?.replacing == false { failSwap(.userEdited) }
                if swap?.runID == runs[ri].runID, swap?.replacing == true { swap?.userActed = true }
            }
            guard let pi = runs[ri].pieces.lastIndex(where: { $0.tEnd == nil }) else { continue }
            let piece = runs[ri].pieces[pi]
            let span = spans[piece.spanID]
            let current = span.map { chars(of: $0) } ?? []
            if current.isEmpty, piece.swapped == nil, span?.parked != true {
                spans[piece.spanID] = nil
                runs[ri].pieces.remove(at: pi)
                continue
            }
            let delivered = runs[ri].delivered
            let base = piece.swapped == nil ? piece.tStart : piece.swappedEnd
            let prefix = piece.swapped?.count ?? 0
            let slice = delivered[min(base, delivered.count)...]
            let lead = slice.prefix { $0.isWhitespace }.count
            let context = piece.anchor + String(piece.swapped ?? [])
            let prepared = Array(DictationTypist.prepare(String(slice), contextBefore: context, capitalization: config.capitalization))
            let trimmed = String(slice.dropFirst(lead)).trimmingCharacters(in: .whitespaces)
            let separator = max(0, prepared.count - trimmed.count)
            // How much of the delivered text the piece shows (a parked piece: as much as was typed).
            let typed = span?.parked == true ? max(0, (span.map { $0.end - $0.start } ?? 0) - prefix)
                : Self.commonPrefix(Array(current.dropFirst(prefix)), prepared)
            var end = min(delivered.count, base + lead + max(0, typed - separator))
            while end < delivered.count, !delivered[end].isWhitespace { end += 1 }
            runs[ri].pieces[pi].tEnd = max(base, end)
            events.append(.regionClosed(runID: runs[ri].runID, cause: cause))
        }
    }

    // MARK: Swap at stop

    /// The stop's one verified swap: the take's trailing piece is replaced by its final text, deleted and inserted in
    /// one op each, once the field showed every character of it as typed (`verify`: reads at the caret and further
    /// back, each overlapping the last). Anything else leaves the field as it is.
    struct Swap: Sendable, Equatable {
        /// `insert`: the delete went; `landing`: the insert went, its confirmation is due.
        enum Phase: Sendable, Equatable { case verify, back, replace, insert, landing }
        var runID: String
        var version: Int
        var spanID: Int
        var text: [Character]
        var phase = Phase.verify
        /// The lowest model offset the reads so far showed as the model has it.
        var covered: Int?
        var reads = 0
        /// The user acted while the take's characters were going (their delete was on its way or done).
        var userActed = false
        /// The take's characters are going or gone: the swap finishes first.
        var replacing: Bool { phase == .insert || phase == .landing }
    }
    private var swap: Swap?
    /// How long the open piece has been out of sight.
    private var parkedPieceMs = 0.0
    /// A revision while speaking edits at most this many characters before the caret.
    public static let nearChars = 60
    /// Consecutive reads of the walk overlap by this much.
    static let walkOverlapChars = 8
    /// The walk gives up past this many reads: a few, and one for every four characters of the take.
    static func walkReadLimit(_ chars: Int) -> Int { 16 + chars / 4 }

    /// Run `ri`'s complete version: its trailing piece swapped to the final text, or the field kept as it is (the final
    /// text is in History: `Event.dropped`). Each version is settled once.
    private mutating func settleFinal(_ ri: Int) -> Action? {
        let run = runs[ri]
        guard run.complete, let version = run.version, run.settledVersion != version, swap == nil,
              let pi = run.pieces.indices.last, untypedRest(of: run) == nil else { return nil }
        let piece = run.pieces[pi]
        func keep(_ reason: DropReason?) -> Action? {
            runs[ri].settledVersion = version
            reportFallback(ri, reason)
            return nil
        }
        guard let final = finalText(pi, in: run) else { return keep(run.pieces.contains(where: \.frozen) ? .userEdited : .changed) }
        guard let span = spans[piece.spanID], !span.parked else { return keep(.unplaceable) }
        let current = chars(of: span)
        if current == final { return keep(nil) }
        // The delivered words are the final text: typing gets there.
        if piece.tEnd == nil, !piece.frozen, Array(desiredText(piece, in: run)) == final, final.starts(with: current) { return nil }
        guard !piece.frozen, !span.userChanged, !span.edited, selection == 0, span.end == userCursor else { return keep(.userEdited) }
        if cursor != userCursor { return send(.move(units(to: userCursor)), lane: .live, moveTo: userCursor) }
        swap = Swap(runID: run.runID, version: version, spanID: piece.spanID, text: final)
        return nextSwap()
    }

    private mutating func nextSwap() -> Action? {
        guard var s = swap else { return nil }
        if s.phase == .insert, spans[s.spanID]?.parked == true, !s.userActed, cursor == userCursor, selection == 0 {
            // The delete went, then the report did not fit the model (nobody acted): the caret is where the take was,
            // and its final text goes there rather than nowhere.
            spans[s.spanID] = Span(start: cursor, end: cursor)
        }
        guard runs.contains(where: { $0.runID == s.runID }), let span = spans[s.spanID], !span.parked else {
            failSwap(.unplaceable); return nil
        }
        switch s.phase {
        case .verify, .back:
            guard !span.userChanged, !span.edited, selection == 0, span.end == userCursor,
                  runs.first(where: { $0.runID == s.runID })?.pieces.last(where: { $0.spanID == s.spanID })?.frozen == false else {
                failSwap(.userEdited); return nil
            }
            // Each read shows the model's text at the caret, after a move the report pinned there (or one that fit there
            // among other places in repetitive text, with a window of its own long enough to tell).
            guard let report = lastReport, report.selected == nil,
                  FieldMatch.positions(in: text, reportedBefore: report.before, reportedAfter: report.after).contains(cursor),
                  s.reads == 0 || lastSendConfirmed
                    || FieldReader.trusted(before: report.before).count + report.after.count >= 2 * Self.walkOverlapChars
            else { failSwap(.changed); return nil }
            if s.phase == .back {
                s.phase = .replace; swap = s
                return nextSwap()
            }
            let trusted = FieldReader.trusted(before: report.before)
            let echo = trusted.count < report.before.count && report.before.first?.isNewline == true
            let low = max(0, cursor - trusted.count - (echo ? 1 : 0)), high = cursor + report.after.count
            if let covered = s.covered {
                // The reads overlap: this one reaches into what the last ones showed.
                guard high >= covered + min(Self.walkOverlapChars, cursor - covered) else { failSwap(.changed); return nil }
            }
            s.covered = min(s.covered ?? low, low); s.reads += 1
            if s.covered! <= span.start {
                s.phase = cursor == userCursor ? .replace : .back
                swap = s
                if s.phase == .back { return send(.move(units(to: userCursor)), lane: .live, moveTo: userCursor) }
                return nextSwap()
            }
            let next = max(span.start, min(cursor - 1, s.covered! + Self.walkOverlapChars))
            guard s.reads < Self.walkReadLimit(span.end - span.start), next < cursor else { failSwap(.changed); return nil }
            swap = s
            return jump(to: next, span: s.spanID, lane: .live)
        case .replace:
            guard cursor == userCursor, span.end == cursor else { failSwap(.changed); return nil }
            s.phase = .insert; swap = s
            let n = span.end - span.start
            guard n > 0 else { return nextSwap() }
            let id = s.spanID
            return send(.deleteBackward(n), lane: .live) { q in q.removeRange(span.start, span.end, owner: id) }
        case .insert:
            // The take's characters are gone: its final text goes where they were, in one insert. Keys wait for it; a
            // tap meanwhile is the user's place, and nothing goes back there (the take is in History).
            guard !s.text.isEmpty else { finishSwap(); return nil }
            guard cursor == span.start, userCursor == cursor else { failSwap(.unplaceable); return nil }
            let id = s.spanID, text = s.text
            s.phase = .landing; swap = s
            return send(.insert(String(text)), lane: .live) { q in
                q.insertAtCursor(text, owner: id)
                q.userCursor = q.cursor
            }
        case .landing:
            // Its report shows the final text in place: done. A resync on the way (it landed elsewhere, or the field
            // changed) leaves it unknown: reported.
            guard chars(of: span) == s.text, span.end == cursor, let report = lastReport, consistent(report) else {
                failSwap(.unplaceable); return nil
            }
            finishSwap()
            return nil
        }
    }

    private mutating func finishSwap() {
        guard let s = swap else { return }
        swap = nil
        guard let ri = runs.firstIndex(where: { $0.runID == s.runID }) else { return }
        if let pi = runs[ri].pieces.lastIndex(where: { $0.spanID == s.spanID }) {
            runs[ri].pieces[pi].swapped = s.text
            runs[ri].pieces[pi].swappedEnd = runs[ri].delivered.count
            if runs[ri].pieces[pi].tEnd != nil { runs[ri].pieces[pi].tEnd = runs[ri].delivered.count }
        }
        runs[ri].settledVersion = s.version
        reportFallback(ri, .userEdited)
    }

    /// The swap stops: the field keeps the take as typed and the final text is in History. Once its delete went, the
    /// take's characters are gone from the field: a drop says so.
    private mutating func failSwap(_ reason: DropReason) {
        guard let s = swap else { return }
        swap = nil
        events.append(.resync(.swapRefused))
        guard let ri = runs.firstIndex(where: { $0.runID == s.runID }) else { return }
        runs[ri].settledVersion = s.version
        if s.replacing {
            runs[ri].fallbackReported = false
            runs[ri].settledThrough = runs[ri].delivered.count
            closeOpenPieces(.resync, ri: ri, freeze: true)
        }
        reportFallback(ri, s.replacing ? .unplaceable : reason)
    }

    /// The run's final text does not stand whole in the field (a piece kept raw, or the user's edits in it): the app
    /// keeps it in History. Reported once per run.
    private mutating func reportFallback(_ ri: Int, _ reason: DropReason?) {
        let run = runs[ri]
        guard !run.fallbackReported, run.complete else { return }
        let whole = Self.joined(run.segments)
        var shown = true
        for pi in run.pieces.indices {
            guard let span = spans[run.pieces[pi].spanID], !span.parked else { shown = false; break }
            if let final = finalText(pi, in: run) {
                if chars(of: span) != final { shown = false; break }
            } else if whole != String(run.delivered) || span.userChanged || span.edited {
                shown = false; break
            }
        }
        guard !shown else { return }
        runs[ri].fallbackReported = true
        events.append(.dropped(Drop(id: "\(run.runID)#final", runID: run.runID, kind: nil, reason: reason ?? .changed,
                                    text: whole, partial: nil)))
    }

    private mutating func dropRun(at ri: Int, reason: DropReason) {
        let run = runs[ri]
        if swap?.runID == run.runID { swap = nil }
        var shown = untypedRest(of: run) == nil && !(run.complete && run.settledVersion != run.version)
        for piece in run.pieces {
            if let span = spans[piece.spanID], !span.parked, chars(of: span) == Array(desiredText(piece, in: run)) { } else { shown = false }
            spans[piece.spanID] = nil
        }
        if !shown, !run.fallbackReported {
            events.append(.dropped(Drop(id: "\(run.runID)#rest", runID: run.runID, kind: nil, reason: reason,
                                        text: run.complete ? Self.joined(run.segments) : String(run.delivered), partial: nil)))
        }
    }

    // MARK: Sending

    private mutating func send(_ op: ShadowOp, lane: Lane, anywhere: Bool = false, moveTo: Int? = nil,
                               _ apply: (inout FieldQueue) -> Void = { _ in }) -> Action {
        let isCursorMove: Bool
        if case .move = op { isCursorMove = true } else { isCursorMove = false }
        let editSettle: Double
        if case .deleteBackward = op, lane != .user {
            editSettle = max(config.editConfirmationMs, config.deleteConfirmationMs)
        } else {
            editSettle = config.editConfirmationMs
        }
        guard coordinator.begin(isCursorMove ? .move : .edit,
                                settleMs: anywhere ? Self.transitMs : isCursorMove ? Self.moveSettleMs : editSettle,
                                transitMs: Self.transitMs) else { return .wait }
        let pre = ModelState(text: text, cursor: cursor, userCursor: userCursor, selection: selection, spans: spans)
        if let moveTo { cursor = moveTo } else { apply(&self) }
        var isMove = false
        if case .move = op { isMove = true }
        inFlight = InFlight(op: op, lane: lane, anywhere: anywhere, pre: pre, isMove: isMove, settleMs: anywhere ? Self.transitMs : isMove ? Self.moveSettleMs : 0)
        coordinator.dispatched()
        lastSentOp = op; lastSentLane = lane
        recentSends.append(Sent(op: op, lane: lane, pre: pre))
        if recentSends.count > 16 { recentSends.removeFirst() }
        paceCreditMs = 0
        sinceSendMs = 0
        lastSendConfirmed = false
        events.append(.sent(op, lane))
        return .send(op)
    }

    /// The field's units from the cursor to `index` (UTF-16, or characters in a field that moves by characters).
    private func units(to index: Int) -> Int {
        let range = index > cursor ? cursor..<index : index..<cursor
        let count = config.movesByCharacters ? range.count : String(text[range]).utf16.count
        return index > cursor ? count : -count
    }

    // MARK: Model

    private mutating func insertAtCursor(_ chars: [Character], owner: Int?, behindUser: Bool = false) {
        guard !chars.isEmpty else { return }
        let i = cursor, n = chars.count
        record(.insert(at: i, count: n, owner: owner))
        text.insert(contentsOf: chars, at: i)
        for (id, var span) in spans {
            if id != owner, span.start < i, i < span.end { if owner == nil { span.userChanged = true } else { span.edited = true } }
            if span.start > i || (span.start == i && id != owner && !span.anchor) { span.start += n }
            if span.end > i || (span.end == i && id == owner) { span.end += n }
            span.end = max(span.end, span.start)
            spans[id] = span
        }
        if userCursor > i || (userCursor == i && !behindUser) { userCursor += n }
        cursor = i + n
    }

    private mutating func removeRange(_ a: Int, _ b: Int, owner: Int?) {
        guard a < b, a >= 0, b <= text.count else { return }
        let n = b - a
        record(.remove(a, b, owner: owner))
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

    private mutating func prepend(_ chars: [Character]) {
        guard !chars.isEmpty else { return }
        let n = chars.count
        record(.grow(n))
        text.insert(contentsOf: chars, at: 0)
        cursor += n; userCursor += n
        if let from = userLost?.from { userLost?.from = from + n }
        for (id, var span) in spans { span.start += n; span.end += n; spans[id] = span }
    }

    /// A span's text in the model (empty for a parked span, whose bounds mean nothing until it is found again).
    private func chars(of span: Span) -> [Character] {
        guard !span.parked, span.start >= 0, span.start <= span.end, span.end <= text.count else { return [] }
        return Array(text[span.start..<span.end])
    }

    private mutating func addSpan(_ span: Span) -> Int {
        nextSpanID += 1
        spans[nextSpanID] = span
        return nextSpanID
    }

    private mutating func seed(_ report: Report) {
        var before = Array(FieldReader.trusted(before: report.before))
        // A window that starts at a block shows "\n " there: a line break is known to precede the block.
        if before.count < report.before.count, report.before.first?.isNewline == true { before.insert("\n", at: 0) }
        let selected = Array(report.selected ?? "")
        text = before + selected + Array(report.after)
        cursor = before.count; userCursor = cursor; selection = selected.count
        seeded = true
        readMarks = []
    }

    private func matches(_ report: Report, anywhere: Bool) -> Bool {
        let selected = report.selected ?? ""
        let found = FieldMatch.positions(in: text, reportedBefore: report.before, reportedAfter: selected + report.after)
        if anywhere { return found.count == 1 && selected.count == selection && fitsSelection(found[0], selected) }
        return (found == [cursor] || pinsExtended(report)) && selected.count == selection && fitsSelection(cursor, selected)
    }

    /// Idle: the report fits the model at the cursor (perhaps elsewhere too).
    private func consistent(_ report: Report) -> Bool {
        let selected = report.selected ?? ""
        return selected.count == selection
            && (FieldMatch.positions(in: text, reportedBefore: report.before, reportedAfter: selected + report.after).contains(cursor)
                || pinsExtended(report))
            && fitsSelection(cursor, selected)
    }

    /// The model knows only a little before the cursor (fewer than `FieldMatch.reverseMatchChars`), and the report
    /// reaches back past it while agreeing with all of it: the model grown by the report's extra text pins the cursor.
    private func pinsExtended(_ report: Report) -> Bool {
        let before = Array(FieldReader.trusted(before: report.before))
        guard cursor >= Self.extendOverlapChars, cursor < FieldMatch.reverseMatchChars, before.count > cursor,
              before.suffix(cursor).elementsEqual(text[..<cursor]) else { return false }
        // A late report of the state before the op in flight is lag, not more text.
        if let flight = inFlight, pins(report, in: flight.pre) { return false }
        if lagging.contains(where: { pins(report, in: $0.state) }) { return false }
        let extra = before.count - cursor
        let grown = Array(before.prefix(extra)) + text
        return FieldMatch.positions(in: grown, reportedBefore: report.before, reportedAfter: (report.selected ?? "") + report.after) == [cursor + extra]
    }

    private func fitsSelection(_ p: Int, _ selected: String) -> Bool {
        let chars = Array(selected)
        return p + chars.count <= text.count && text[p..<(p + chars.count)].elementsEqual(chars)
    }

    /// The report fits the state at its cursor, wholly inside its text (no reaching past either end).
    private func fitsInside(_ report: Report, in state: ModelState) -> Bool {
        fits(report, in: state) && (report.selected ?? "").count + report.after.count <= state.text.count - state.cursor
            && FieldReader.trusted(before: report.before).count <= state.cursor
    }

    /// The report fits the state at its cursor, perhaps elsewhere too.
    private func fits(_ report: Report, in state: ModelState) -> Bool {
        let selected = report.selected ?? ""
        return selected.count == state.selection
            && FieldMatch.positions(in: state.text, reportedBefore: report.before, reportedAfter: selected + report.after).contains(state.cursor)
    }

    private func pins(_ report: Report, in state: ModelState) -> Bool {
        let selected = report.selected ?? ""
        return FieldMatch.positions(in: state.text, reportedBefore: report.before, reportedAfter: selected + report.after) == [state.cursor]
            && selected.count == state.selection
    }

    /// The report pins a unique place in the model: the cursor (and selection) is there.
    private mutating func relocate(_ report: Report) {
        let selected = report.selected ?? ""
        let found = FieldMatch.positions(in: text, reportedBefore: report.before, reportedAfter: selected + report.after)
        guard found.count == 1 else { return }
        cursor = found[0]; userCursor = cursor; selection = selected.count
    }

    /// A confirmed report that shows more than the model knows extends it.
    private mutating func merge(_ report: Report) {
        let before = Array(FieldReader.trusted(before: report.before))
        if before.count > cursor, before.suffix(cursor).elementsEqual(text[..<cursor]) {
            prepend(Array(before.prefix(before.count - cursor)))
        }
        let after = Array(report.after)
        let tail = cursor + selection
        let known = text.count - tail
        if after.count > known, after.prefix(known).elementsEqual(text[tail...]) {
            text += after[known...]
        }
        unparkSpans()
    }

    private mutating func restore(_ state: ModelState) {
        // The changes since a read no longer lead to this text.
        readMarks = []
        text = state.text; cursor = state.cursor; userCursor = state.userCursor; selection = state.selection; spans = state.spans
    }

    /// The report does not show what the model expects: find out what happened and go on from there.
    private mutating func resync(_ report: Report, pre flight: InFlight?) {
        let selected = report.selected ?? ""
        let found = FieldMatch.positions(in: text, reportedBefore: report.before, reportedAfter: selected + report.after)
        if found.contains(cursor), selected.count == selection {
            // The model fits; with an op on its way that never confirmed (its report fit the state before it too), the
            // op counts as landed now, long after the host's transit.
            if found.count > 1 { events.append(.resync(.ambiguous)) } else if flight != nil { events.append(.resync(.assumed)) }
            return
        }
        // A jump of the keyboard's own that the report, its whole confirm window long, shows went nowhere: the caret is
        // still where it was. The text it jumped for is not in this field (Safari gives every field of a page the same
        // identity, so a switch looks like a tap), and it is never tried again: its work drops, the model starts over.
        // A jump is never taken as landed on a report that fits several places and not its own: nothing pins the
        // region, so nothing is edited there. One that stopped short on its way (the field ended before the region)
        // failed too: the caret is where it stopped.
        if let flight, let target = flight.jumpSpan {
            let short = found.count == 1 && min(flight.pre.cursor, cursor) < found[0] && found[0] < max(flight.pre.cursor, cursor)
            if short || flight.waitedMs >= Self.confirmLimitMs && fits(report, in: flight.pre) || found.count > 1 && !fits(report, in: flight.pre) {
                jumpFailed(to: target, flight: flight, report: report, caret: short ? found[0] : flight.pre.cursor)
                return
            }
        }
        // A late report of the state before the op, which fits there among other places: the op counts as landed.
        if let flight, !pins(report, in: flight.pre), fits(report, in: flight.pre) {
            events.append(.resync(.ambiguous))
            return
        }
        // A report of an older state than one confirmed since (the op in flight's, or an earlier one): lag, never truth,
        // until a fresh report after a nudge keeps showing it. Then the host lost what followed: back to that state.
        let fitsHereElsewhere = found.count == 1 && (found.first.map { selected.count + report.after.count <= text.count - $0 } ?? false)
        if let older = olderState(report, flight: flight) {
            if !staleNudgeSent {
                // The op in flight stays a candidate: if the host lost it, its state before it is the older state.
                if let flight { confirmedHistory.append((flight.pre, flight.input, 0)); unconfirmedInHistory = true }
                staleNudgeDue = true
                events.append(.resync(.stale))
                return
            }
            // After a fresh report: text that is still the current text means the user moved there; else the host lost
            // what followed that state.
            if !fitsHereElsewhere || (older.index == nil && older.at == older.state.cursor && flight?.input != nil) {
                revert(to: older, flight: flight, report: report)
                return
            }
        }
        // Moving the user's cursor takes a report that fits wholly inside known text: at the model's end any text
        // after the cursor fits, which says nothing about where the cursor is. It also takes as much agreeing text as
        // finding text again: an empty field's report pins the start of any text, which may be another field's.
        let after = selected.count + report.after.count
        let inside = found.filter { after <= text.count - $0 }
        if found.count == 1, inside == found, fitsSelection(found[0], selected), hasEvidence(report) {
            abortUnit()
            // Reports of the state before the user moved, still on their way, are lag from now on.
            lagging.append((ModelState(text: text, cursor: cursor, userCursor: userCursor, selection: selection, spans: spans), 0))
            if let flight { lagging.append((flight.pre, 0)) }
            cursor = found[0]; userCursor = cursor; selection = selected.count
            closeOpenPieces(selected.isEmpty ? .cursor : .selection)
            quietAfterMove = true
            // As after a tap: the ops on their way may still land where the user moved the caret (a window too short
            // to tell a tap shows only now).
            if selected.isEmpty, !recentSends.isEmpty { tapRace = (recentSends, 0) }
            events.append(.resync(.cursorMoved))
            merge(report)
            return
        }
        // Ambiguous: the model is kept, unless the report holds still that way (never a freeze): then it starts over.
        if found.count > 1, flight != nil || reportStableMs < Self.confirmLimitMs {
            events.append(.resync(.ambiguous))
            return
        }
        if tapRaceLanded(report) {
            events.append(.resync(.cursorMoved))
            return
        }
        if absorbOutsideInsert(report) {
            abortUnit()
            closeOpenPieces(.keystroke)
            events.append(.resync(.outsideInsert))
            return
        }
        reseed(report, flight: flight)
    }

    /// The report shows this much known text around a place (`relocateChars`, or all the model knows).
    private func hasEvidence(_ report: Report) -> Bool {
        FieldReader.trusted(before: report.before).count + (report.selected ?? "").count + report.after.count >= min(Self.relocateChars, text.count)
    }

    /// A jump to `target` did not get there (`Resync.jumpFailed`): the caret is at `caret` (where it was, or where it
    /// stopped short). The region or edit it was for drops once and the model starts over from the report, so no other
    /// jump goes out on the old field's text; spans found again there (long, unique text with its context) are this
    /// field's. The user's cursor keeps its distance from the caret (the caret goes back with the next op).
    private mutating func jumpFailed(to target: Int, flight: InFlight, report: Report, caret: Int) {
        events.append(.resync(.jumpFailed))
        cursor = caret
        abortUnit()
        if config.canReadAround {
            reseed(report, flight: flight)
            if recoveryRequest != nil { return }
        }
        if swap?.spanID == target { failSwap(.unplaceable) }
        var gone: [EditState] = []
        userLane.removeAll { if case .edit(let s) = $0, s.spanID == target { gone.append(s); return true }; return false }
        editLane.removeAll { if $0.spanID == target { gone.append($0); return true }; return false }
        for state in gone { drop(state, .unplaceable) }
        reseed(report, flight: flight)
    }

    /// The text around the cursor changed: the report is the new model; spans are found again by their text.
    private mutating func reseed(_ report: Report, flight: InFlight?) {
        abortUnit()
        // The open piece stays open while it is out of sight: found again at the caret (`unparkSpans`), it goes on; else
        // it ends (`typeOpenPiece`).
        for (id, var span) in spans where !span.parked {
            span.lastText = chars(of: span)
            if !span.lastText.isEmpty {
                span.lastBefore = Array(text[max(0, span.start - Self.contextChars)..<span.start])
                span.lastAfter = Array(text[span.end..<min(text.count, span.end + Self.contextChars)])
            }
            span.parked = true; span.userActedParked = false; spans[id] = span
        }
        let oldText = text, oldCursor = cursor, oldUser = userCursor
        seed(report)
        // The user's own op on its way (a pan, a key): the caret is where the user put it.
        if flight?.lane == .user { userLost = nil }
        // Already searching (the homing move's landing is unknown to the model): the search alone decides. A carry that
        // fails after the user acted at the caret (a selection appeared) leaves the caret as the user's.
        // A report that shares nothing with the old text around the caret is another field (or text replaced whole): the
        // caret is where the user put it, and nothing goes back the old field's distance.
        else if userLost == nil, Self.shares(report, with: oldText, around: oldCursor),
                !carryUserCursor(from: oldText, cursor: oldCursor, user: oldUser), !userActed {
            // The text between the caret and the user's cursor changed in a way the model did not know: the user's
            // cursor is found again by the text around it, else the caret goes back the distance it came and looks there.
            let before = Array(oldText[max(0, oldUser - Self.relocateChars)..<oldUser])
            let after = Array(oldText[oldUser..<min(oldText.count, oldUser + Self.relocateChars)])
            let units = oldUser > oldCursor ? String(oldText[oldCursor..<oldUser]).utf16.count : -String(oldText[oldUser..<oldCursor]).utf16.count
            userLost = LostUser(before: before, after: after,
                                units: config.movesByCharacters ? oldUser - oldCursor : units, homed: false)
        }
        if userLost != nil { findLostUser() }
        userActed = false
        events.append(.resync(.reseeded))
        unparkSpans()
        requestRecoveryIfNeeded()
    }

    /// The report's text next to the caret (`contextChars` on a side, as a span's found again) stands in the old text
    /// near the old caret.
    static func shares(_ report: Report, with old: [Character], around cursor: Int) -> Bool {
        let window = String(old[max(0, cursor - 2 * relocateChars)..<min(old.count, cursor + 2 * relocateChars)])
        let before = FieldReader.trusted(before: report.before), after = report.after
        return (before.count >= contextChars && window.contains(String(before.suffix(contextChars))))
            || (after.count >= contextChars && window.contains(String(after.prefix(contextChars))))
    }

    /// A resync while a unit had the caret away from the user: the user's cursor keeps its distance from the caret when
    /// the text between them agrees with the new model as far as the model shows it (the rest comes from the old model).
    @discardableResult
    private mutating func carryUserCursor(from old: [Character], cursor oldCursor: Int, user oldUser: Int) -> Bool {
        let d = oldUser - oldCursor
        guard d != 0 else { return true }
        if d > 0 {
            let segment = old[oldCursor..<oldUser]
            let known = min(d, text.count - cursor)
            guard known == d || known >= Self.contextChars, text[cursor..<(cursor + known)].elementsEqual(segment.prefix(known)) else { return false }
            if known < d { text += segment.suffix(d - known) }
            userCursor = cursor + d
        } else {
            let segment = old[oldUser..<oldCursor]
            let known = min(-d, cursor)
            guard known == -d || known >= Self.contextChars, text[(cursor - known)..<cursor].elementsEqual(segment.suffix(known)) else { return false }
            if known < -d { prepend(Array(segment.prefix(-d - known))) }
            userCursor = cursor + d
        }
        return true
    }

    /// The user's cursor after a resync while a unit had the caret away, when the text in between changed unseen.
    struct LostUser: Sendable, Equatable {
        var before: [Character]
        var after: [Character]
        /// From the caret to the user's cursor, in the field's units, as the model last knew it.
        var units: Int
        var homed: Bool
        /// Where the caret was when it went back (model offset).
        var from: Int?
    }
    private(set) var userLost: LostUser?
    private var userActed = false

    /// Finds the lost user's cursor by the text around it: one place in the model where the text before it ends (as far
    /// as the model reaches) and the text after it begins, with at least `relocateChars` of it agreeing.
    private mutating func findLostUser() {
        guard let lost = userLost else { return }
        var hits: [Int] = []
        for p in 0...text.count {
            let b = min(lost.before.count, p), a = min(lost.after.count, text.count - p)
            guard b + a >= min(Self.relocateChars, lost.before.count + lost.after.count),
                  text[(p - b)..<p].elementsEqual(lost.before.suffix(b)), text[p..<(p + a)].elementsEqual(lost.after.prefix(a)) else { continue }
            hits.append(p)
            if hits.count > 1 { break }
        }
        if lost.homed {
            // The caret went back the distance it came: that physical place is the user's (the remembered text around
            // it may be stale, it is what the model got wrong). A way back cut short by the field's edge (another field
            // took the keyboard, where the user tapped) leaves the user where the caret was before it.
            userCursor = cursor; userLost = nil
            if let from = lost.from, from >= 0, from <= text.count {
                let a = min(from, cursor), b = max(from, cursor)
                let moved = config.movesByCharacters ? b - a : String(text[a..<b]).utf16.count
                if moved < abs(lost.units) { userCursor = from }
            }
        } else if hits.count == 1, let p = hits.first {
            userCursor = p; userLost = nil
        }
    }

    /// The report fits the known text (or a recently confirmed state of it, shown late) at one place inside it that is
    /// neither where the op in flight left the caret nor where it was before: no op went there, so the user tapped.
    /// Returns that place in the current text.
    private func tappedElsewhere(_ report: Report, flight: InFlight?) -> (at: Int, seen: ModelState?)? {
        let current = ModelState(text: text, cursor: cursor, userCursor: userCursor, selection: selection, spans: spans)
        let pre = flight?.pre ?? current
        guard report.selected == nil, selection == 0, !fits(report, in: pre), !fits(report, in: current),
              // A recent state at its own caret, late: lag, not a tap.
              !confirmedHistory.contains(where: { fitsInside(report, in: $0.state) }),
              !lagging.contains(where: { fits(report, in: $0.state) }),
              // As much agreeing text as finding text again: a short window at an edge may be another field's.
              hasEvidence(report) else { return nil }
        // Older states only when the report fits the current text nowhere (old text shown at the tap); repetitive text
        // that fits here several times says nothing.
        let fitsNow = !FieldMatch.positions(in: text, reportedBefore: report.before, reportedAfter: report.after).isEmpty
        let states = [current] + (fitsNow ? [] : [pre] + confirmedHistory.reversed().map(\.state))
        for state in states {
            let found = FieldMatch.positions(in: state.text, reportedBefore: report.before, reportedAfter: report.after)
            // Wholly inside that text (a report reaching back past an early, short state's start says nothing).
            // An empty side is an edge of the text for a tap (an empty window after the caret fits anywhere otherwise).
            let candidates = found.filter { p in
                (!report.after.isEmpty || p == state.text.count) && (!report.before.isEmpty || p == 0)
            }
            guard candidates.count == 1, let p = candidates.first, report.after.count <= state.text.count - p,
                  FieldReader.trusted(before: report.before).count <= p else { continue }
            // The place in the current text: through the changes since that state.
            var shift = 0
            for h in ShadowEditPlanner.diff(state.text, text) {
                if h.end <= p { shift += h.text.count - (h.end - h.start) } else if h.start < p { shift += h.start + h.text.count - p; break } else { break }
            }
            let here = min(text.count, max(0, p + shift))
            // At that state's own caret it is that state, late: lag, not a tap.
            guard p != state.cursor, here != cursor, here != pre.cursor else { return nil }
            var seen = state
            seen.cursor = p; seen.userCursor = p; seen.selection = 0
            return (here, state.text == text ? nil : seen)
        }
        return nil
    }

    /// The user tapped at `at` (current text) while an op was on its way: everything stops there; reports of the
    /// states before it are lag from now on.
    private mutating func userTapped(at: Int, flight: InFlight?) {
        recoveryRevision &+= 1; recoveryRequest = nil
        abortUnit()
        lagging.append((ModelState(text: text, cursor: cursor, userCursor: userCursor, selection: selection, spans: spans), 0))
        if let flight { lagging.append((flight.pre, 0)) }
        cursor = at; userCursor = at; selection = 0
        closeOpenPieces(.cursor)
        quietAfterMove = true
        // The last ops may still be landing (they confirmed on the proxy's own echo, or one is in flight; reports after a
        // tap can show the time before it for a while): where the user tapped.
        if !recentSends.isEmpty { tapRace = (recentSends, 0) }
        events.append(.resync(.cursorMoved))
    }

    /// The last inserts that were on their way at the tap (one or several of one lane) show right before the tapped
    /// caret: they landed there, not where they were sent for. The model takes them there (and back out where they were
    /// meant to go). The user's own keys stay, and so does dictation's (nothing is deleted after the user's tap; the
    /// take is reported); an edit's text comes out again (`strayInsertion`).
    private mutating func tapRaceLanded(_ report: Report) -> Bool {
        guard let race = tapRace, report.selected == nil, let last = race.sends.last else { return false }
        if case .deleteBackward(let count) = last.op { return tapRaceDeleteLanded(report, count: count, pre: last.pre) }
        var key = ""
        for sent in race.sends.reversed() {
            guard case .insert(let s) = sent.op, sent.lane == last.lane else { break }
            key = s + key
            guard report.before.hasSuffix(key) else { break }
            let before = String(report.before.dropLast(key.count))
            let found = FieldMatch.positions(in: sent.pre.text, reportedBefore: before, reportedAfter: report.after)
                .filter { !before.isEmpty || $0 == 0 }
            guard found.count == 1, let p = found.first, p != sent.pre.cursor, report.after.count <= sent.pre.text.count - p else { continue }
            restore(sent.pre)
            cursor = p; userCursor = p; selection = 0
            insertAtCursor(Array(key), owner: -1)
            if last.lane == .user { userCursor = cursor } else if last.lane == .live {
                // Dictation never deletes after the user's tap: its text stays where it landed, the caret after it, and
                // the take is reported (its text is in History).
                userCursor = cursor
                if let run = runs.last {
                    runs[runs.count - 1].settledThrough = run.delivered.count
                    events.append(.dropped(Drop(id: "stray:" + run.runID, runID: run.runID, kind: nil, reason: .unplaceable,
                                                text: run.complete ? Self.joined(run.segments) : String(run.delivered), partial: key)))
                }
            } else {
                userCursor = p
                strayInsertion = StrayInsertion(text: key,
                    before: String(sent.pre.text[max(0, p - Self.relocateChars)..<p]),
                    after: String(sent.pre.text[p..<min(sent.pre.text.count, p + Self.relocateChars)]), lane: last.lane,
                    runID: nil)
            }
            tapRace = nil
            lagging = []
            return true
        }
        return false
    }

    /// Never keep typing captive to missing ownership evidence. An uncertain repair is a failed delivery,
    /// not permission to delete at a new caret or to continue the interrupted take's automatic edits.
    private mutating func refuseStrayInsertion() {
        guard let stray = strayInsertion else { return }
        strayInsertion = nil
        if let runID = stray.runID { cancelRun(runID) }
        events.append(.resync(.recoveryRefused))
        events.append(.dropped(Drop(id: "stray:" + UUID().uuidString, runID: stray.runID, kind: nil,
                                    reason: .unplaceable, text: stray.text, partial: nil)))
    }

    /// The delete that was on its way at the tap landed there: the report shows the text before it with the characters
    /// in front of the tapped place gone (fewer at the text's start). The model takes that; what it deleted was not the
    /// keyboard's to delete, so it goes back in, and the user's cursor is where they tapped.
    private mutating func tapRaceDeleteLanded(_ report: Report, count: Int, pre: ModelState) -> Bool {
        let before = Array(FieldReader.trusted(before: report.before)), after = Array(report.after), old = pre.text
        guard before.count <= old.count, before.count + after.count >= Self.relocateChars || before.isEmpty else { return false }
        var hits: [(q: Int, n: Int)] = []
        for q in before.count...old.count where old[(q - before.count)..<q].elementsEqual(before) {
            for n in (q == 0 ? Array(0...count) : [count]) where q + n <= old.count && q + n + after.count <= old.count
                && old[(q + n)..<(q + n + after.count)].elementsEqual(after) {
                hits.append((q, n))
            }
            if hits.count > 1 { return false }
        }
        guard hits.count == 1, let hit = hits.first, hit.q + hit.n != pre.cursor else { return false }
        restore(pre)
        let deleted = Array(text[hit.q..<(hit.q + hit.n)])
        removeRange(hit.q, hit.q + hit.n, owner: nil)
        cursor = hit.q; userCursor = hit.q; selection = 0
        tapRace = nil
        lagging = []
        if !deleted.isEmpty { unit = Unit(ops: [.insert(String(deleted), owner: nil), .setUserCursorToCursor], owner: .space, paced: false) }
        return true
    }

    /// The user's insert in flight shows in the report right before a caret at another place of the text it was sent
    /// into (a tap moved the caret meanwhile): the model takes it there, and the user's cursor is after it.
    private mutating func landedElsewhere(_ report: Report, flight: InFlight) -> Bool {
        guard flight.lane == .user, case .insert(let key) = flight.op, report.selected == nil, flight.pre.selection == 0,
              report.before.hasSuffix(key) else { return false }
        let before = String(report.before.dropLast(key.count))
        let found = FieldMatch.positions(in: flight.pre.text, reportedBefore: before, reportedAfter: report.after)
        guard found.count == 1, let p = found.first, p != flight.pre.cursor, report.after.count <= flight.pre.text.count - p,
              before.count >= Self.relocateChars || before.count == p else { return false }
        restore(flight.pre)
        abortUnit()
        cursor = p; userCursor = p
        closeOpenPieces(.cursor)
        insertAtCursor(Array(key), owner: nil)
        userCursor = cursor
        return true
    }

    /// The most recent confirmed state (or the op in flight's state before it) the report pins at one place.
    private func olderState(_ report: Report, flight: InFlight?) -> (index: Int?, state: ModelState, at: Int)? {
        let selected = report.selected ?? ""
        let after = selected.count + report.after.count
        var candidates: [(Int?, ModelState)] = flight.map { [(nil, $0.pre)] } ?? []
        for i in confirmedHistory.indices.reversed() { candidates.append((i, confirmedHistory[i].state)) }
        for (index, state) in candidates where state.text != text || state.cursor != cursor {
            let found = FieldMatch.positions(in: state.text, reportedBefore: report.before, reportedAfter: selected + report.after)
            // That state at its own caret, late (a tap shown with old text is `tappedElsewhere`'s).
            guard found.count == 1, let p = found.first, p == state.cursor, after <= state.text.count - p, selected.count == state.selection,
                  FieldReader.trusted(before: report.before).count <= p else { continue }
            return (index, state, p)
        }
        return nil
    }

    /// The host has an older state than the model: the model goes back to it. Placed edits are planned again from there (their lost characters are made again); the user's keys that were lost go once more.
    /// A report at another place in that text is the user's tap.
    private mutating func revert(to older: (index: Int?, state: ModelState, at: Int), flight: InFlight?, report: Report) {
        // Only an input that never confirmed goes again: a confirmed one reached the host (it may have been undone
        // there, which is not the keyboard's to repeat).
        var lostInputs: [Input] = []
        if let index = older.index {
            if index == confirmedHistory.count - 1, unconfirmedInHistory, let input = confirmedHistory[index].input { lostInputs.append(input) }
            confirmedHistory.removeSubrange(index...)
        }
        if older.index == nil, let input = flight?.input, flight?.retried == false { lostInputs.append(input) }
        unconfirmedInHistory = false
        abortUnit()
        restore(older.state)
        if older.at != older.state.cursor {
            cursor = older.at; userCursor = older.at
            closeOpenPieces(.cursor)
        }
        // Regions begun and edits placed since that state have no span in it: they are planned afresh.
        if swap != nil { failSwap(.changed) }
        for ri in runs.indices { runs[ri].pieces.removeAll { spans[$0.spanID] == nil } }
        for i in editLane.indices where editLane[i].spanID.map({ spans[$0] == nil }) ?? false { editLane[i].spanID = nil }
        for i in userLane.indices { if case .edit(var e) = userLane[i], e.spanID.map({ spans[$0] == nil }) ?? false { e.spanID = nil; userLane[i] = .edit(e) } }
        for input in lostInputs.reversed() {
            switch input {
            case .move: continue
            // A key whose text stands right before the caret the report shows landed there (a tap moved the caret
            // while it was on its way): it does not go again.
            case .insert(let key) where report.before.hasSuffix(key): continue
            default: userLane.insert(.input(input, retried: true), at: 0)
            }
        }
        staleNudgeSent = false; staleNudgeDue = false
        lagging = []
        events.append(.resync(.reverted))
    }

    /// The report is the model with a few characters more right at the caret (another keyboard typed there): they go
    /// into the model as the user's own input, and the user's cursor is after them.
    private mutating func absorbOutsideInsert(_ report: Report) -> Bool {
        guard selection == 0, report.selected == nil else { return false }
        let before = Array(FieldReader.trusted(before: report.before)), after = Array(report.after)
        // Text the model knows after the caret shows after it: a report with nothing after it is the field's end (a tap
        // there, where an op on its way may have landed), not typing at the caret.
        guard !after.isEmpty || cursor == text.count else { return false }
        let n = min(after.count, text.count - cursor)
        guard n == after.count || cursor + n == text.count, text[cursor..<(cursor + n)].elementsEqual(after[..<n]) else { return false }
        for k in 1...max(1, min(Self.contextChars * 2, before.count - Self.extendOverlapChars)) where before.count - k >= Self.extendOverlapChars {
            let rest = before.dropLast(k)
            let m = min(rest.count, cursor)
            // As strong as finding text again: the text before it agrees for `relocateChars` (or back to the model's start).
            guard m >= min(Self.relocateChars, cursor), m >= Self.extendOverlapChars,
                  text[(cursor - m)..<cursor].elementsEqual(rest.suffix(m)) else { continue }
            insertAtCursor(Array(before.suffix(k)), owner: nil)
            userCursor = cursor
            return true
        }
        return false
    }

    /// Parked spans come back where their text is found again, once and uniquely.
    private mutating func unparkSpans() {
        for (id, var span) in spans where span.parked {
            let needle = span.lastText
            // A short text may well stand elsewhere too (the user's own words): only a long one is found again.
            guard needle.count >= Self.relocateChars, needle.count <= text.count else { continue }
            var hits: [Int] = []
            for p in 0...(text.count - needle.count) where text[p..<(p + needle.count)].elementsEqual(needle)
                && p >= span.lastBefore.count && text[(p - span.lastBefore.count)..<p].elementsEqual(span.lastBefore)
                && p + needle.count + span.lastAfter.count <= text.count
                && text[(p + needle.count)..<(p + needle.count + span.lastAfter.count)].elementsEqual(span.lastAfter) {
                hits.append(p)
                if hits.count > 1 { break }
            }
            guard hits.count == 1, let p = hits.first else { continue }
            span.start = p; span.end = p + needle.count; span.parked = false
            spans[id] = span
        }
    }

    /// A change of the model, for the reads that follow changes (`markRead`).
    private mutating func record(_ change: ReadMark.Change) {
        guard !readMarks.isEmpty else { return }
        for i in readMarks.indices { readMarks[i].changes.append(change) }
        readMarks.removeAll { $0.changes.count > Self.readMarkChanges }
    }

    private enum ReadPlacement: Equatable { case placed(Int, target: String), userEdited }

    /// An edit's scope found through the changes since its read (nil: no such read, or the scope does not fit it). A
    /// user change inside the scope cancels it; the keyboard's own (a cleanup that landed meanwhile, its text at the
    /// scope's edge too) are merged into the target where they touch nothing the edit changes (`FieldMerge`).
    private mutating func placeThroughRead(_ edit: Edit) -> ReadPlacement? {
        guard edit.selected == nil, let readID = edit.readID, let mark = readMarks.last(where: { $0.id == readID }) else { return nil }
        let before = Array(edit.before), after = Array(edit.after)
        let c = mark.cursor, old = mark.text
        let kb = min(c, before.count), ka = min(old.count - c, after.count)
        // The scope as the read saw it; what the model did not know then lies past its ends.
        guard old[(c - kb)..<c].elementsEqual(before.suffix(kb)), old[c..<(c + ka)].elementsEqual(after.prefix(ka)),
              kb == before.count || kb == c, ka == after.count || c + ka == old.count else { return nil }
        var s = c - kb, e = c + ka, userTouched = false
        for change in mark.changes {
            switch change {
            case .grow(let n): s += n; e += n
            case .insert(let i, let n, let owner):
                // At an edge: the keyboard's text of spans that were read belongs to the scope, anything else not.
                let rewrite = owner.map { mark.spanIDs.contains($0) } ?? false
                if i < s || (i == s && !rewrite) { s += n; e += n }
                else if i < e || (i == e && rewrite) { e += n; if owner == nil { userTouched = true } }
            case .remove(let a, let b, let owner):
                if b <= s { s -= b - a; e -= b - a; continue }
                guard a < e else { continue }
                if owner == nil { userTouched = true }
                func shift(_ p: Int) -> Int { p >= b ? p - (b - a) : (p > a ? a : p) }
                s = shift(s); e = shift(e)
            }
        }
        if userTouched { return .userEdited }
        guard s >= 0, s <= e, e <= text.count else { return nil }
        // The parts the read knew beyond the model: they must agree with what the model shows there now, or grow it.
        let front = Array(before.prefix(before.count - kb)), back = Array(after.suffix(after.count - ka))
        let k = min(s, front.count), m = min(text.count - e, back.count)
        guard text[(s - k)..<s].elementsEqual(front.suffix(k)), k == front.count || s - k == 0,
              text[e..<(e + m)].elementsEqual(back.prefix(m)), m == back.count || e + m == text.count else { return nil }
        if k < front.count { prepend(Array(front.prefix(front.count - k))); s += front.count - k; e += front.count - k }
        if m < back.count { text += back.suffix(back.count - m) }
        s -= front.count; e += back.count
        let now = Array(text[s..<e])
        let target = FieldMerge.rebase(base: before + after, kept: Array(edit.target), incoming: now).text
        return .placed(addSpan(Span(start: s, end: e)), target: String(target))
    }

    private enum Placement: Equatable { case placed(Int), ambiguous, absent }

    /// Where an edit's scope is in the model: at the user's cursor (the model may grow by the scope's text beyond what
    /// it knows), else at its one occurrence in the model.
    private mutating func place(_ edit: Edit, anchor: Int? = nil) -> Placement {
        let before = Array(edit.before), after = Array(edit.after)
        func fitsWithGrowth(_ p: Int) -> (front: Int, back: Int)? {
            guard p >= 0, p <= text.count else { return nil }
            let k = min(p, before.count)
            // Growing the model by the scope's text takes some of it agreeing with what the model knows there.
            guard text[(p - k)..<p].elementsEqual(before[(before.count - k)...]),
                  k == before.count || (p - k == 0 && k >= min(before.count, Self.extendOverlapChars)) else { return nil }
            let m = min(text.count - p, after.count)
            guard text[p..<(p + m)].elementsEqual(after[..<m]),
                  m == after.count || (p + m == text.count && m >= min(after.count, Self.extendOverlapChars)) else { return nil }
            return (before.count - k, after.count - m)
        }
        // Where the cursor is, or where it was when the edit came (tracked through every change since).
        for candidate in [userCursor, anchor.flatMap { spans[$0] }.flatMap { $0.parked ? nil : $0.start }].compactMap({ $0 }) {
            guard let growth = fitsWithGrowth(candidate), selection == 0 || candidate != cursor else { continue }
            var p = candidate
            if growth.front > 0 { prepend(Array(before.prefix(growth.front))); p += growth.front }
            if growth.back > 0 { text += after.suffix(growth.back) }
            return .placed(addSpan(Span(start: p - before.count, end: p + after.count)))
        }
        let scope = before + after
        guard scope.count >= Self.relocateChars, scope.count <= text.count else { return .absent }
        var hits: [Int] = []
        for p in before.count...(text.count - after.count)
            where text[(p - before.count)..<p].elementsEqual(before) && text[p..<(p + after.count)].elementsEqual(after) {
            hits.append(p)
        }
        if hits.count == 1, let p = hits.first { return .placed(addSpan(Span(start: p - before.count, end: p + after.count))) }
        return hits.isEmpty ? .absent : .ambiguous
    }
}
