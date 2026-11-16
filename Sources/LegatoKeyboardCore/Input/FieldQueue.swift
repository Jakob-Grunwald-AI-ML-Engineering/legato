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
/// - Live dictation types only at the caret and trusts the model (the keyboard is the field's only writer; an iOS
///   keyboard sees a short window of it): a run's words go in one grapheme at a time at its open piece's end, the
///   user's caret. A revision of the piece's last words goes in while speaking only when every changed character lies
///   within `nearChars` of the caret for legacy hosts without activity admission. Production hosts release revisions
///   through the conditional edit lane in confirmed pauses or at stop. Every unchanged character remains in place;
///   a stop-time block swap is only an end-verified fallback after a failed jump. Otherwise text stays as typed with
///   recovery in History. A take never starts inside a word (`liveStart`).
/// - User typing, deletion and movement close the current speech piece; later words start at the user's caret.
///   Corrections still visit unchanged portions of earlier pieces. The shared merge protects user changes, including
///   changes made while an edit was on its way. Pieces remain independently anchored across typed separators.
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
        /// The read (`markRead`) `before` and `after` came from: the scope is found through every change since, and
        /// the keyboard's own changes to it are merged into `target` (only the user's cancel the edit).
        public var readID: String?
        public init(id: String = UUID().uuidString, kind: Kind, before: String = "", after: String = "", selected: String? = nil,
                    target: String, atCursor: Bool = false, cursorAtEnd: Bool = true, readID: String? = nil) {
            self.id = id; self.kind = kind; self.before = before; self.after = after
            self.selected = selected?.isEmpty == true ? nil : selected
            self.target = target; self.atCursor = atCursor; self.cursorAtEnd = cursorAtEnd; self.readID = readID
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
        /// The report fits nowhere: the model starts over from it.
        case reseeded
        /// The report fits several places: the model is kept as predicted.
        case ambiguous
        /// The deadline passed with the report still showing the model's text at the caret: the chunk counts as landed.
        case assumed
        /// Text appeared at the caret that the keyboard did not type (another keyboard): it is the user's, at the caret.
        case outsideInsert
        /// A jump of the keyboard's own went nowhere (the report kept showing the caret where it was): the text it was
        /// for is not in this field. Its work drops and the model starts over from the report (`reseeded` follows).
        case jumpFailed
        /// A read across a seam (`FieldRecovery`): asked, its evidence, the model restored from it, an edit planned
        /// again there, or refused.
        case recoveryRequested, recoveryEvidence, recoveryRestored, recoveryReplanned, recoveryRefused
        /// The stop's swap did not go: the report did not show the take's end before the caret as the model has it, or
        /// after the delete its text could not go where the take was.
        case swapRefused
        /// A chunk's result did not show by the deadline (or its hop found nothing to see): the queue re-read.
        case checkFailed
        /// A new document identity whose report shows the shadow (`observe`): the same field, kept.
        case identityKept
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
    }

    public struct Config: Sendable, Equatable {
        public var movesByCharacters: Bool
        public var capitalization: AutoCapitalizationType
        /// The adapter can supply a bounded, self-verifying cursor read on request (to explore across a seam).
        public var canReadAround: Bool
        /// Edits (Magic, cleanup) wait while a take is spoken: they go in the gaps between words.
        public var prioritizeSpeech: Bool
        public init(movesByCharacters: Bool = false, capitalization: AutoCapitalizationType = .none,
                    canReadAround: Bool = false, prioritizeSpeech: Bool = false) {
            self.movesByCharacters = movesByCharacters; self.capitalization = capitalization
            self.canReadAround = canReadAround
            self.prioritizeSpeech = prioritizeSpeech
        }
    }

    // MARK: Tunables

    /// The one deadline: how long a chunk's result may be missing from the report (the keyboard's own inserts and
    /// deletes produce no host callback; Safari's last callback for a burst came at up to 260 ms, native apps under 60 ms)
    /// before the queue re-reads. A report that does not show the chunk inside it is not a seam.
    public static let checkDeadlineMs = 400.0
    /// Text found again away from the cursor (after a seam, or a scope that moved) must be at least this long.
    public static let relocateChars = 16
    /// Context on each side that must match too when text behind a seam is found again.
    static let contextChars = 8
    /// A report reaching back past a short model must agree with at least this much of it.
    static let extendOverlapChars = 4
    /// Hops toward one target before the chunk gives up (each one within sight, then a look and a correction).
    static let hopLimit = 8
    /// A budget for the app's wait on an edit of `operationCount` ops.
    public static func budgetMs(operationCount: Int) -> Double { max(20_000, Double(max(0, operationCount)) * 150) }
    /// Conservative background playback budget: each changed character can need a mutation and two moves.
    /// This does not hold user input or determine its responsiveness deadline.
    public static func budgetMs(sourceCharacters: Int, targetCharacters: Int) -> Double {
        budgetMs(operationCount: 3 * (max(0, sourceCharacters) + max(0, targetCharacters)) + 2)
    }

    // MARK: State

    public var config: Config
    /// Something else needs the cursor for a moment (a walk that reads the field): the op in flight is confirmed and
    /// the caret goes back to the user's cursor, nothing else goes out.
    public var paused = false
    /// The field as the keyboard knows it (`ShadowDocument`): text, caret, the user's cursor, selection and spans.
    public private(set) var doc = ShadowDocument()
    public private(set) var text: [Character] { get { doc.text } set { doc.text = newValue } }
    public private(set) var cursor: Int { get { doc.cursor } set { doc.cursor = newValue } }
    public private(set) var userCursor: Int { get { doc.userCursor } set { doc.userCursor = newValue } }
    /// Characters selected after `cursor`.
    public private(set) var selection: Int { get { doc.selection } set { doc.selection = newValue } }
    public var seeded: Bool { doc.seeded }

    typealias Span = ShadowDocument.Span
    private var spans: [Int: Span] { get { doc.spans } set { doc.spans = newValue } }

    private struct LiveRevision: Sendable, Equatable {
        var runID: String
        var version: Int
        var proposal: [Character]
        var through: Int
        /// Expected text after only our own partial operations; user changes rebase against this.
        var baseline: [Character]
    }

    private struct EditState: Sendable, Equatable {
        var edit: Edit
        var spanID: Int?
        /// Where the user's cursor was when the edit came: a zero-width span that moves with every change.
        var anchorID: Int?
        var unplacedMs = 0.0
        /// Chunks of it whose check failed (the queue re-read and planned it again).
        var failures = 0
        /// The span's text when its last chunk was planned.
        var plannedFrom: [Character]?
        var revision: LiveRevision?

        init(edit: Edit) { self.edit = edit }
    }
    private enum UserItem: Sendable, Equatable {
        case input(Input)
        case edit(EditState)
        var isMove: Bool { if case .input(.move) = self { true } else { false } }
    }
    private var userLane: [UserItem] = []
    private var editLane: [EditState] = []

    struct LiveRun: Sendable, Equatable {
        var runID: String
        var version: Int?
        var complete = false
        /// The user stopped the take (`takeStopped`, or a snapshot says so): keys wait for its words still arriving.
        var stopped = false
        /// Acoustic/semantic activity, supplied by the route; an open take need not be speaking.
        var speaking = true
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
        /// The complete version settled through verified edits or a reported fallback: each version once.
        var settledVersion: Int?
        var fallbackReported = false
        /// Manual activity prevents whole-block fallback and changes where later speech starts.
        /// Conditional revisions still visit unchanged pieces and preserve protected user words.
        var userActed = false
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
        case setUserCursorToCursor
        case startRegion(run: String, tStart: Int, anchor: String)
    }
    private enum UnitOwner: Sendable, Equatable { case edit(EditState, Lane), space }
    /// One chunk of the keyboard's own: hops within sight, one place's deletes and inserts, the way back. Its ops go out
    /// back to back; only a hop waits for a look at where it landed. One check follows the last op.
    private struct Unit: Sendable, Equatable {
        var ops: [QOp]
        var owner: UnitOwner
        /// Hops sent toward the current target (each within sight, looked at, corrected).
        var hops = 0
    }
    private var unit: Unit?

    private typealias ModelState = ShadowDocument
    /// The chunk on its way: the ops sent since the field last showed the model, and the model before them.
    private struct InFlight: Sendable, Equatable {
        var op: ShadowOp
        var lane: Lane
        /// Exact: the report must pin `cursor` in the model. Anywhere: any unique place (a collapsing move).
        var anywhere: Bool
        var pre: ModelState
        /// Since the last op went out: past `checkDeadlineMs` a report that does not show the chunk is a failed check.
        var waitedMs = 0.0
        var input: Input?
        /// A deliberate user action in an opaque selection is allowed, but never replayed against the old model.
        var acceptsRawUserReport = false
        /// A take's words typed while the selection or context was unverified (`heldSpeechNext`).
        var heldSpeech: HeldSpeech?
        /// The last op was a hop of a running chunk from this caret: the next report is looked at before the chunk goes on.
        var hopFrom: Int?
        /// A jump of the keyboard's own to this span (a region's or an edit's).
        var jumpSpan: Int?
        /// The ops of the chunk so far (a tap can redirect any of them).
        var ops: [ShadowOp] = []
        /// The report the first op went out on.
        var sentOn: Report?
    }
    /// The report a held insert of speech was sent on, and the piece's span it went to.
    private struct HeldSpeech: Sendable, Equatable {
        var report: Report
        var spanID: Int
    }
    private var coordinator = FieldEditCoordinator.Operations()
    private var inFlight: InFlight? {
        didSet {
            // Losing a prediction is not confirmation; nothing drains (the next chunk acts on the report as it is).
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
            text = updated; cursor = newCursor; userCursor = newCursor; selection = 0
            readMarks = []; userLost = nil; recentSends = []
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
        guard !hasUnverifiedInput else { return }
        // Dictation never looks around: its pieces are edited only at the caret.
        guard config.canReadAround, recoveryRequest == nil, !prioritizesSpeech else { return }
        let pieces = Set(runs.flatMap { $0.pieces.map(\.spanID) })
        let targets = spans.sorted { $0.key < $1.key }.compactMap { id, span -> FieldRecovery.Target? in
            guard span.parked, !span.anchor, !span.userChanged, !span.edited, !span.lastText.isEmpty, !pieces.contains(id) else { return nil }
            return .init(id: String(id), expected: String(span.lastText), landed: nil,
                         before: String(span.lastBefore), after: String(span.lastAfter))
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

    /// An issued deletion may temporarily leave the host empty. The adapter must not mistake
    /// its own confirmed operation for a host clearing the draft (for example after Send).
    public var ownsEmptyReport: Bool {
        guard text.isEmpty else { return false }
        if swap != nil { return true }
        if case .edit(_, let lane)? = unit?.owner, lane != .user { return true }
        if let flight = inFlight, flight.lane != .user, case .deleteBackward = flight.op { return true }
        // A synchronous proxy may confirm the final deletion before the adapter observes its
        // empty callback. Carry that automatic origin through the check's deadline only.
        if lastSentLane != .user, sinceSendMs < Self.checkDeadlineMs,
           case .deleteBackward? = lastSentOp { return true }
        return false
    }

    /// A nil selection following an external selection callback can be an opaque Safari Select All.
    /// Identical windows cannot prove a collapsed caret, so every automatic action that needs to know where the
    /// caret is remains held (revisions, edits, recovery reads, any move or delete). A take's words still go in
    /// at the caret as plain inserts (`heldSpeechNext`), as the user's keys do: the report they change is the
    /// evidence that lifts the hold.
    public enum UnverifiedInput: String, Sendable { case selection, externalContext }
    private var opaqueSelectionBaseline: Report?
    public private(set) var unverifiedInputReason: UnverifiedInput?
    public var hasUnverifiedInput: Bool { opaqueSelectionBaseline != nil }
    public var hasUnverifiedSelection: Bool { hasUnverifiedInput && unverifiedInputReason == .selection }
    public var hasUnverifiedContext: Bool { hasUnverifiedInput && unverifiedInputReason == .externalContext }
    public var hasRecentOwnOperation: Bool { hasRecentOwnOperation(elapsedMs: 0) }

    /// The keyboard's own op went out within the check's deadline (its callbacks may still come), or is unchecked.
    /// Native callbacks supply the idle wall time before pumping; observe it without advancing
    /// the queue clock, because the next step will account for that same interval exactly once.
    public func hasRecentOwnOperation(elapsedMs: Double) -> Bool {
        inFlight != nil || ownsRead || sinceSendMs + max(0, elapsedMs) < Self.checkDeadlineMs
    }

    public mutating func externalSelectionChanged(report: Report, hasText: Bool? = nil, elapsedSinceLastStepMs: Double = 0) {
        guard !hasRecentOwnOperation(elapsedMs: elapsedSinceLastStepMs), !confirmEmptyField(report, hasText: hasText) else { return }
        opaqueSelectionBaseline = report.selected == nil ? (lastReport ?? report) : nil
        unverifiedInputReason = opaqueSelectionBaseline == nil ? nil : .selection
        if opaqueSelectionBaseline != nil {
            abortUnit()
            recoveryRequest = nil
            recoveryRevision &+= 1
        }
    }

    /// A native text callback whose proxy windows stayed old is not a readable insertion yet.
    /// Use the same admission barrier as an opaque selection, without blind refresh movements.
    public mutating func externalContextChanged(report: Report, hasText: Bool? = nil, elapsedSinceLastStepMs: Double = 0) {
        guard !hasRecentOwnOperation(elapsedMs: elapsedSinceLastStepMs), !confirmEmptyField(report, hasText: hasText) else { return }
        opaqueSelectionBaseline = lastReport ?? report
        unverifiedInputReason = .externalContext
        abortUnit()
        recoveryRequest = nil
        recoveryRevision &+= 1
    }

    /// Empty proxy windows can be stale; the native field's independent hasText=false
    /// distinguishes a genuinely empty editor, where there is no hidden text selection.
    private mutating func confirmEmptyField(_ report: Report, hasText: Bool?) -> Bool {
        guard hasText == false, report.before.isEmpty, report.after.isEmpty, report.selected == nil,
              text.isEmpty, runs.isEmpty, !hasOwnWork else { return false }
        opaqueSelectionBaseline = nil
        unverifiedInputReason = nil
        return true
    }

    /// The route owns activity admission; this queue only schedules against that evidence.
    public mutating func setSpeaking(_ active: Bool, runID: String) {
        guard let index = runs.firstIndex(where: { $0.runID == runID }) else { return }
        runs[index].speaking = active
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
    /// The user moved the caret (a tap): only the user's own input goes until the report held still this long and fits.
    private var quietAfterMove = false
    /// The op that was on its way when the user tapped: it may land where they tapped.
    private struct RevisionRollback: Sendable, Equatable {
        var editID: String
        var baseline: [Character]
    }
    private struct Sent: Sendable, Equatable {
        var op: ShadowOp; var lane: Lane; var pre: ModelState
        var revisionRollback: RevisionRollback?
        var ageMs = 0.0
    }
    /// The ops sent lately (within the check's deadline): any of them may have landed where the user tapped meanwhile.
    private var recentSends: [Sent] = []
    private var tapRace: (sends: [Sent], ageMs: Double)?
    /// A proved misplaced insertion, anchored by the unchanged text around it. A read or resync may
    /// move the caret to either side; a character count alone never authorizes compensating deletes.
    private struct StrayInsertion: Sendable, Equatable {
        var text: String
        var before: String
        var after: String
        var lane: Lane
        var elapsedMs = 0.0
    }
    private var strayInsertion: StrayInsertion?
    private var lastSentOp: ShadowOp?
    /// The unit a hop's look showed the field moves by (it differs from the configured one).
    private var learnedByCharacters: Bool?
    private var lastSentLane = Lane.live
    /// After a tap, ops sent before it may still land where the user tapped: the keyboard's own work resumes once the
    /// field held still this long (kept, see `docs/field-editing.md`).
    static let quietMs = 250.0

    public init(config: Config = Config()) { self.config = config }

    // MARK: Inspection

    public var isSpeaking: Bool { runs.contains { !$0.stopped && !$0.complete && $0.speaking } }
    /// Quiet audio permits revisions only after every heard append has reached the field.
    private var prioritizesSpeech: Bool {
        config.prioritizeSpeech && (isSpeaking || runs.contains(where: rawAppendPending))
    }

    public var isIdle: Bool {
        recoveryRequest == nil && strayInsertion == nil && tapRace == nil && inFlight == nil && unit == nil && swap == nil
            && userLane.isEmpty && (editLane.isEmpty || prioritizesSpeech)
            && !runs.contains(where: { runNeedsWork($0) || ackDue($0) })
    }
    public var hasUserInput: Bool { !userLane.isEmpty }
    /// The keyboard's own writes still to land (a unit, queued edits, dictation): a read for an instruction waits for
    /// them, so its scope already shows them.
    public var hasOwnWork: Bool {
        unit != nil || swap != nil || (!editLane.isEmpty && !prioritizesSpeech) || runs.contains(where: { runNeedsWork($0) })
    }
    public var hasOpInFlight: Bool { inFlight != nil }
    /// Nothing in flight and the caret at the user's cursor: the field is as the user left it, as far as the queue goes.
    public var isHome: Bool { inFlight == nil && cursor == userCursor && swap == nil }
    public var isInUnit: Bool { unit != nil }
    /// A chunk is running: its next op goes out at once (the adapter keeps stepping).
    public var isInChunk: Bool { inFlight != nil && unit.map { !$0.ops.isEmpty } == true }
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
                             + "changed=\(span?.userChanged ?? false) userActed=\(run.userActed) swapped=\(piece.swapped != nil) "
                             + "has=\(String(span.map { chars(of: $0) } ?? []).debugDescription) wants=\(desiredText(piece, in: run).debugDescription)]")
            }
            if let rest = untypedRest(of: run) { parts.append("rest@\(rest)") }
            if run.speech.hasDeferredRevision { parts.append("deferred=\(String(run.speech.authoritative.suffix(40)).debugDescription)") }
        }
        if let swap { parts.append("swap=\(swap.inserted ? "inserted" : "deleted")") }
        return parts.joined(separator: " ")
    }

    // MARK: Enqueue

    public mutating func enqueue(_ input: Input) {
        recoveryRevision &+= 1
        if recoveryRequest != nil { events.append(.resync(.recoveryRefused)) }
        recoveryRequest = nil
        userLane.append(.input(input))
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
    public var history = EditHistory()

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
    ///
    /// A chunk's ops go out back to back, one per step, acting on the proxy's immediate view: only a hop waits for the
    /// report after it (`look`). After the chunk's last op one check: the report shows the model at the caret. A report
    /// that does not, inside `checkDeadlineMs`, is not acted on (Safari's first callback after a move still shows the old
    /// place; a host applies a burst in stages). At the deadline the check has failed: the queue re-reads (`resync`) and
    /// plans what is left against what it read.
    public mutating func step(report: Report, elapsedMs: Double) -> Action {
        guard !ownsRead else { return .wait }
        if config.prioritizeSpeech {
            // Delivery metadata is independent of the OS operation in flight. See the newest heard tail before
            // admitting more background work, even when the route already reports quiet audio.
            for ri in runs.indices { applyPending(ri) }
            if prioritizesSpeech, let request = recoveryRequest { deferRecovery(request) }
        }
        coordinator.advance(elapsedMs)
        stepElapsedMs = elapsedMs
        if let request = recoveryRequest {
            recoveryWaitMs += max(0, elapsedMs)
            // The adapter normally answers. An orphaned or superseded read must still terminate.
            if recoveryWaitMs >= 2 * FieldRecovery.budgetMs + Self.checkDeadlineMs, inFlight == nil {
                completeRecovery(request, report: nil, restored: false)
            }
        }
        if !paused, var stray = strayInsertion {
            stray.elapsedMs += max(0, elapsedMs)
            strayInsertion = stray
            if stray.elapsedMs >= Self.checkDeadlineMs { refuseStrayInsertion() }
        }
        sinceSendMs += elapsedMs
        inFlight?.waitedMs += elapsedMs
        // Only the user selects: a selection the model does not have says the user acted at the caret.
        if report.selected != nil, selection == 0 { userActed = true }
        if let race = tapRace { tapRace = race.ageMs + elapsedMs < 2 * Self.checkDeadlineMs ? (race.sends, race.ageMs + elapsedMs) : nil }
        recentSends = recentSends.compactMap { var sent = $0; sent.ageMs += elapsedMs; return sent.ageMs < Self.checkDeadlineMs ? sent : nil }
        if report == lastReport { reportStableMs += elapsedMs } else { lastReport = report; reportStableMs = 0 }
        if let baseline = opaqueSelectionBaseline,
           (unverifiedInputReason == .selection && report.selected != nil) || report != baseline {
            opaqueSelectionBaseline = nil
            unverifiedInputReason = nil
        }
        if !seeded {
            seed(report)
            // Edits that came before the first report are anchored where the cursor turns out to be.
            for i in userLane.indices { if case .edit(var s) = userLane[i], s.anchorID == nil, !s.edit.atCursor, s.edit.selected == nil {
                s.anchorID = addSpan(Span(start: userCursor, end: userCursor, anchor: true)); userLane[i] = .edit(s) } }
            for i in editLane.indices where editLane[i].anchorID == nil && !editLane[i].edit.atCursor && editLane[i].edit.selected == nil {
                editLane[i].anchorID = addSpan(Span(start: userCursor, end: userCursor, anchor: true))
            }
        }

        if let flight = inFlight, flight.acceptsRawUserReport {
            // No cursor probe and no retry: a key may have intentionally replaced an unreported selection. The proxy
            // shows the key at once; a report that does not change waits for the deadline.
            guard report != flight.sentOn || flight.waitedMs >= Self.checkDeadlineMs else { return .wait }
            let inputs = userLane.compactMap { item -> UserItem? in
                if case .input = item { return item }; return nil
            }
            let retired = runs.map(\.runID) + retiredRunIDs
            let waited = flight.waitedMs
            reset()
            retiredRunIDs = Array(retired.suffix(32))
            userLane = inputs
            seed(report)
            lastReport = report
            events.append(.confirmed(waitedMs: waited))
            return next()
        }
        if let flight = inFlight, let held = flight.heldSpeech {
            // No cursor probe and no retry: the report says what the insert did (an optimistic echo cannot show a
            // selection it replaced, so it is read as it comes).
            if report == held.report {
                // The proxy shows nothing of it yet. A plain insert at the caret counts as landed at the deadline, so
                // the take is never stuck behind a report that does not move; the hold stays.
                guard flight.waitedMs >= Self.checkDeadlineMs else { return .wait }
                inFlight = nil
                events.append(.resync(.assumed))
            } else if case .insert(let typed) = flight.op, Self.shows(report, insert: typed, after: held.report),
                      matches(report, anywhere: false) {
                guard confirm(flight, report: report) else { return .wait }
            } else {
                // Not the old text with the insert (it replaced a selection no report showed, or the field had
                // changed unseen): the report is the model. The piece goes on where its text stands before the caret.
                inFlight = nil
                reseed(report, flight: flight)
                if var span = spans[held.spanID], span.parked, !span.lastText.isEmpty, cursor == userCursor, selection == 0,
                   cursor >= span.lastText.count, text[(cursor - span.lastText.count)..<cursor].elementsEqual(span.lastText) {
                    span.start = cursor - span.lastText.count; span.end = cursor; span.parked = false
                    spans[held.spanID] = span
                }
            }
        }
        if hasUnverifiedInput, inFlight == nil {
            // The take's words still go in at the caret; everything else of the keyboard's own stays held.
            guard let item = userLane.first else { return next() }
            guard case .input(let input) = item else { return .idle }
            userLane.removeFirst()
            let op: ShadowOp
            switch input {
            case .insert(let value): op = .insert(value)
            case .deleteBackward: op = .deleteBackward(1)
            case .move(let amount): op = .move(units(to: max(0, min(text.count, userCursor + amount))))
            }
            let action = send(op, lane: .user) { _ in }
            inFlight?.acceptsRawUserReport = true
            return action
        }

        // Past the deadline (nothing of the keyboard's own may still land), a report at a place no op was going to is
        // the user's tap.
        if sinceSendMs >= Self.checkDeadlineMs, let tap = tappedElsewhere(report, flight: inFlight) {
            let flight = inFlight
            inFlight = nil
            userTapped(at: tap.at, flight: flight)
        }
        if let flight = inFlight {
            if let from = flight.hopFrom {
                // A hop of a running chunk: look where it landed before the chunk goes on.
                if case .move(let units) = flight.op, look(report, from: from, units: units) {
                    inFlight?.hopFrom = nil
                    return next()
                }
                guard flight.waitedMs >= Self.checkDeadlineMs else { return .wait }
                inFlight = nil
                events.append(.resync(.checkFailed))
                resync(report, pre: flight)
                return next()
            }
            // The chunk goes on: its ops go back to back (the check comes after its last op).
            if let current = unit, !current.ops.isEmpty { return next() }
            // A report that fits the state before the chunk as well proves nothing (an edit at the caret may still be on its
            // way). A chunk that ends with a move is shown by the report at its end: its edit may be out of the window
            // there (a burst lands whole, measured), and an edit inside the window would not fit.
            var endsWithMove = false
            if case .move = flight.op { endsWithMove = true }
            if matches(report, anywhere: flight.anywhere), flight.anywhere || endsWithMove || !pins(report, in: flight.pre) {
                guard confirm(flight, report: report) else { return .wait }
            } else if flight.waitedMs < Self.checkDeadlineMs {
                // Not shown yet: no seam. The user's input goes behind the chunk all the same (`plannedNext`).
                return userLane.isEmpty ? .wait : next()
            } else {
                // The check failed: the field does not show the chunk. Re-read; what is left is planned against it.
                inFlight = nil
                if landedElsewhere(report, flight: flight) {
                    // The user tapped while their key was on its way: it landed where they tapped.
                    events.append(.resync(.cursorMoved))
                    return next()
                }
                events.append(.resync(.checkFailed))
                resync(report, pre: flight)
            }
        } else if !consistent(report) {
            // Within the deadline of the keyboard's own last op the host may still be applying it: no seam yet.
            if sinceSendMs < Self.checkDeadlineMs { return userLane.isEmpty ? .wait : next() }
            resync(report, pre: nil)
        } else if reportStableMs == 0 {
            merge(report)
        }
        return next()
    }

    /// After a hop: the report shows the caret at the hop's target (the chunk goes on), or exactly where the same move
    /// lands counted in the other unit (UTF-16 code units or graphemes: hosts differ, measured): the caret is there, the
    /// field's unit is learned, and the chunk's next hop corrects by what is left. Anything else may be a late report
    /// (Safari's first callback after a move shows the old place; a host still applying earlier ops shows its older
    /// state): the chunk waits, and at the deadline its check has failed.
    private mutating func look(_ report: Report, from: Int, units: Int) -> Bool {
        guard report.selected == nil, selection == 0 else { return false }
        let found = doc.positions(of: report)
        if found.contains(cursor) { return true }
        let byCharacters = !movesByCharacters
        var at = from, left = abs(units)
        while left > 0, units > 0 ? at < text.count : at > 0 {
            let c = units > 0 ? text[at] : text[at - 1]
            left -= byCharacters ? 1 : String(c).utf16.count
            at += units > 0 ? 1 : -1
        }
        guard at != cursor, found == [at], hasEvidence(report) else { return false }
        cursor = at
        learnedByCharacters = byCharacters
        return true
    }

    /// The report shows the chunk in flight as the model has it: it is confirmed.
    private mutating func confirm(_ flight: InFlight, report: Report) -> Bool {
        if flight.anywhere { relocate(report) }
        guard coordinator.confirm(matches: true) else { return false }
        events.append(.confirmed(waitedMs: flight.waitedMs))
        userActed = false
        merge(report)
        inFlight = nil
        return true
    }

    /// The report shows what `held` showed with `insert` typed at its caret. An insert that replaced a selection no
    /// report showed leaves only itself: text the window showed before is gone.
    static func shows(_ report: Report, insert: String, after held: Report) -> Bool {
        guard report.selected == nil else { return false }
        let before = FieldReader.trusted(before: report.before), old = FieldReader.trusted(before: held.before)
        guard before.hasSuffix(insert) else { return false }
        let kept = before.dropLast(insert.count)
        return kept.isEmpty == old.isEmpty && (kept.hasSuffix(old) || old.hasSuffix(kept))
            && report.after.isEmpty == held.after.isEmpty && (report.after.hasPrefix(held.after) || held.after.hasPrefix(report.after))
    }

    // MARK: Choosing the next op

    private mutating func next() -> Action {
        if recoveryRequest != nil, !paused { return .wait }
        guard coordinator.available || inFlight != nil else { return .wait }
        return plannedNext()
    }

    private mutating func plannedNext() -> Action {
        if hasUnverifiedInput { return inFlight == nil ? heldSpeechNext() : .wait }
        if inFlight != nil {
            // The running chunk goes on to its end; behind it only the user's input goes before the check.
            if let current = unit, !current.ops.isEmpty { return nextInUnit() }
            guard !userLane.isEmpty, !paused, swap == nil, userLost == nil, strayInsertion == nil, selection == 0 else { return .wait }
            if let current = unit { unit = nil; finishUnit(current.owner) }
            guard cursor == userCursor else { return .wait }
            return nextUser() ?? .wait
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
        // The stop's swap deleted the take: its final text goes in before anything else.
        if swap != nil, let action = nextSwap() { return action }
        if paused {
            abortUnit()
            if cursor != userCursor, selection == 0 { return send(.move(units(to: userCursor)), lane: .user, moveTo: userCursor) }
            return .wait
        }
        // User input first; a unit that has not started gives the caret back first.
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
            abortUnit()
            if cursor != userCursor, selection == 0 { return send(.move(units(to: userCursor)), lane: .user, moveTo: userCursor) }
            if let action = nextUser() { return action }
        }
        // A tap can redirect an already-issued OS write. Reconcile its landing before any
        // further automated jump/edit, rather than racing a second operation against that write.
        if tapRace != nil { return .wait }
        if quietAfterMove {
            // Ops sent before the tap may still be landing where the user tapped: nothing of the keyboard's own
            // goes until the field holds still and shows what the model expects.
            guard reportStableMs >= Self.quietMs, let report = lastReport, consistent(report) else { return .wait }
            quietAfterMove = false
        }
        // Nothing of the keyboard's own starts, and no jump goes out, on a model the field's report does not show at the
        // caret (another field's report can fit it elsewhere): it waits, and a report that holds still so reseeds.
        let shown = lastReport.map(consistent) ?? true
        if prioritizesSpeech, case .edit(_, .edit)? = unit?.owner {
            // Return to the speaking head. The edit is replanned from confirmed text in the next gap, never replayed
            // from its old cursor offsets.
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
        // The caret away from the user's cursor with nothing under way (an edit's unit or a walk that stopped): it goes back.
        if cursor != userCursor, userLost == nil { return send(.move(units(to: userCursor)), lane: .edit, moveTo: userCursor) }
        if prioritizesSpeech {
            if let action = nextLiveAppend() { return action }
            for ri in runs.indices { ack(ri) }
            return .idle
        }
        if let action = nextEdit() { return action }
        if let action = nextLive() { return action }
        return .idle
    }

    private mutating func nextUser() -> Action? {
        while let item = userLane.first {
            if !item.isMove { for (id, span) in spans where span.parked { spans[id]?.userActedParked = true } }
            switch item {
            case .input(let input):
                if case .insert(let key) = input, let finish = finishWordBeforeKey(key) { userLane.removeFirst(); return finish }
                userLane.removeFirst()
                if case .move = input { closeOpenPieces(.cursor) } else { closeOpenPieces(.keystroke) }
                if let action = sendUser(input) { return action }
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

    private mutating func sendUser(_ input: Input) -> Action? {
        switch input {
        case .insert(let key):
            let action = send(.insert(key), lane: .user) { q in
                if q.selection > 0 { q.removeRange(q.cursor, q.cursor + q.selection, owner: nil); q.selection = 0 }
                q.insertAtCursor(Array(key), owner: nil)
                q.userCursor = q.cursor
            }
            inFlight?.input = .insert(key)
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
            inFlight?.input = input
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

    /// What the open piece still appends at its end (the cursor): its untyped end.
    private func heldAppend(_ piece: Piece, in run: LiveRun, span: Span) -> [Character] {
        let desired = Array(desiredText(piece, in: run)), current = chars(of: span)
        return desired.starts(with: current) ? Array(desired[current.count...]) : []
    }

    /// A key at the open piece's end while the typewriter has shown only part of a word: the word's rest goes in
    /// with the key, in one insert (with a space when the key starts a word), so the key lands after the word.
    private mutating func finishWordBeforeKey(_ key: String) -> Action? {
        guard let restChars = openPieceWordRest(), let (ri, pi) = openPieceIndex() else { return nil }
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
        guard !prioritizesSpeech else { return nil }
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
                    if lane == .edit, state.unplacedMs < Self.checkDeadlineMs { return .wait }
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
        if state.revision == nil, span.userChanged { drop(state, .userEdited); return .done }
        if span.parked {
            // Behind a seam: explored with a read where the adapter can, else found again by the observer within the
            // deadline, or dropped (the app keeps the result in History; a cleanup gets one fresh pass).
            requestRecoveryIfNeeded()
            if recoveryRequest != nil { return .wait }
            state.unplacedMs += stepElapsedMs
            if lane == .edit, state.unplacedMs < Self.checkDeadlineMs { return .wait }
            drop(state, .unplaceable); return .done
        }
        let current = chars(of: span)
        if var revision = state.revision {
            // Replanning after a key protects changes made since our last confirmed partial text.
            state.edit.target = String(conditionalRevisionTarget(base: revision.baseline, current: current,
                                                               proposal: Array(state.edit.target), span: span))
            revision.baseline = current
            state.revision = revision
            spans[id]?.userChanged = false
        }
        let target = Array(state.edit.target)
        if current == target {
            if state.edit.cursorAtEnd, userCursor != span.end {
                state.failures += 1
                guard state.failures <= Self.failureLimit else { drop(state, .unplaceable); return .done }
                unit = Unit(ops: [.moveToSpanEnd(id), .setUserCursorToCursor], owner: .edit(state, lane))
                return .started
            }
            if cursor != userCursor {
                unit = Unit(ops: [.moveToUser], owner: .edit(state, lane))
                return .started
            }
            applied(state)
            return .done
        }
        guard state.revision != nil || state.failures <= Self.failureLimit else { drop(state, .unplaceable); return .done }
        guard let next = chunk(spanID: id, from: current, to: target) else { drop(state, .changed); return .done }
        state.plannedFrom = current
        let back: [QOp] = next.last && state.edit.cursorAtEnd ? [.moveToSpanEnd(id), .setUserCursorToCursor] : [.moveToUser]
        unit = Unit(ops: next.ops + back, owner: .edit(state, lane))
        return .started
    }

    /// Chunks of an edit whose check failed, or that changed nothing, in a row before it drops.
    static let failureLimit = 4

    /// The next chunk of a change of span `spanID` from `current` to `target`: its last group of nearby changes
    /// (`SpanPlanner`, back to front so earlier offsets stay valid), as hops to its place and that place's deletes and
    /// inserts. Every unchanged character stays in the host, except that a single change ending a few characters before
    /// the user's caret is rewritten from the caret (no hop; the few characters between are typed again). `last`: no
    /// group is left after this one.
    private func chunk(spanID: Int, from current: [Character], to target: [Character]) -> (ops: [QOp], last: Bool)? {
        guard let span = spans[spanID] else { return nil }
        let groups = SpanPlanner.spans(from: current, to: target, leaveTailAppend: false, paceMs: 0, moveSettleMs: 0, editSettleMs: 0)
        guard let group = groups.last else { return nil }
        let base = span.start
        var ops: [QOp] = []
        let between = userCursor - (base + group.end)
        if group.hunks.count == 1, cursor == userCursor, between >= 0, between <= SpanPlanner.mergeGap, base + group.end + between <= span.end,
           !text[(base + group.end)..<userCursor].contains(where: \.isNewline),
           between > 0 || !emptiesLine(base + group.start, base + group.end) {
            // At the caret: one delete run back to the group's start, one insert of its new text and what stood between.
            let kept = String(text[(base + group.end)..<userCursor])
            let count = group.end - group.start + between
            if count > 0 { ops.append(.delete(count, owner: spanID)) }
            let typed = String(group.text) + kept
            if !typed.isEmpty { ops.append(.insert(typed, owner: spanID)) }
            return (ops, groups.count == 1)
        }
        for hunk in group.hunks.reversed() {
            if emptiesLine(base + hunk.start, base + hunk.end), !hunk.text.isEmpty {
                // Never an empty line mid-replacement: a rich editor puts a placeholder line break into a line that
                // becomes empty (and may drop the line's list or block). The line's last old grapheme stays until the
                // new text stands before it.
                ops.append(.moveInSpan(spanID, offset: hunk.end - 1))
                if hunk.end - 1 > hunk.start { ops.append(.delete(hunk.end - 1 - hunk.start, owner: spanID)) }
                ops.append(.insert(String(hunk.text), owner: spanID))
                ops.append(.moveInSpan(spanID, offset: hunk.start + hunk.text.count + 1))
                ops.append(.delete(1, owner: spanID))
                continue
            }
            ops.append(.moveInSpan(spanID, offset: hunk.end))
            if hunk.end > hunk.start { ops.append(.delete(hunk.end - hunk.start, owner: spanID)) }
            if !hunk.text.isEmpty { ops.append(.insert(String(hunk.text), owner: spanID)) }
        }
        return (ops, groups.count == 1)
    }

    /// Deleting the model's `a..<b` leaves its line empty: a line break (or the known text's edge) on both sides, and a
    /// real line break on at least one. A single-line field (or text the model knows no line break around) has no line
    /// for a rich editor to fill, so a whole replacement there goes as one block.
    private func emptiesLine(_ a: Int, _ b: Int) -> Bool {
        let breakBefore = a > 0 && text[a - 1].isNewline, breakAfter = b < text.count && text[b].isNewline
        return b > a && (a == 0 || breakBefore) && (b == text.count || breakAfter) && (breakBefore || breakAfter)
    }

    /// The running chunk's next op: back to back, no wait between them. A move is a hop within sight, looked at before
    /// the chunk goes on (`look`); it stays first until the caret is at its target.
    private mutating func nextInUnit() -> Action {
        while var current = unit {
            guard let op = current.ops.first else {
                // Its check confirms it first (the field shows the model at the caret).
                if inFlight != nil { return .wait }
                unit = nil
                finishUnit(current.owner)
                return next()
            }
            switch op {
            case .moveInSpan(let id, let offset):
                guard let span = spans[id], !span.parked else { unit = nil; requeue(current.owner); return .wait }
                let target = min(max(0, span.start + offset), text.count)
                if target != cursor { return hop(to: target, span: id) }
                current.ops.removeFirst(); current.hops = 0; unit = current
            case .moveToUser:
                if userCursor != cursor { return hop(to: userCursor, span: nil) }
                current.ops.removeFirst(); current.hops = 0; unit = current
            case .moveToSpanEnd(let id):
                if let end = spans[id]?.end, end != cursor { return hop(to: end, span: id) }
                current.ops.removeFirst(); current.hops = 0; unit = current
            case .setUserCursorToCursor:
                current.ops.removeFirst(); unit = current
                userCursor = cursor
            case .startRegion(let runID, let tStart, let anchor):
                current.ops.removeFirst(); unit = current
                if let ri = runs.firstIndex(where: { $0.runID == runID }) {
                    let id = addSpan(Span(start: userCursor, end: userCursor))
                    // In front of text without a space (a caret put inside a word or before one): the space after the
                    // piece goes in at its end once the take is done (the caret never goes back for it).
                    let glued = userCursor < text.count && !FieldInsertion.trailingSeparator(after: "x", before: text[userCursor]).isEmpty
                    runs[ri].pieces.append(Piece(spanID: id, tStart: tStart, anchor: anchor, startSegment: startSegment(at: tStart, in: runs[ri]),
                                                 spaceAfter: glued))
                    events.append(.regionStarted(runID: runID, anchorChars: anchor.count))
                }
            case .delete(let count, let owner):
                guard cursor >= count, count > 0 else { unit = nil; requeue(current.owner); return .wait }
                current.ops.removeFirst(); unit = current
                // One delete run: `count` single deletes back to back (the adapter's dispatch).
                return send(.deleteBackward(count), lane: lane(of: current.owner)) { q in q.removeRange(q.cursor - count, q.cursor, owner: owner) }
            case .insert(let chars, let owner):
                current.ops.removeFirst(); unit = current
                return send(.insert(chars), lane: lane(of: current.owner)) { q in q.insertAtCursor(Array(chars), owner: owner) }
            }
        }
        return next()
    }

    /// A hop toward `target`, never past what the field showed on that side: a host drops a move that overshoots its
    /// text (WhatsApp) and counts in its own units (UTF-16, or graphemes in Safari), so a far target takes several hops,
    /// each looked at and corrected (`look`). One character past an empty window is allowed where the model knows a line
    /// break there (a window cut at the line). Too many hops, or nothing to see on that side, fail the chunk.
    private mutating func hop(to target: Int, span id: Int?) -> Action {
        guard var current = unit else { return .wait }
        let lane = lane(of: current.owner)
        var visible = abs(target - cursor)
        if let report = lastReport {
            visible = target < cursor ? FieldReader.trusted(before: report.before).count : (report.selected ?? "").count + report.after.count
        }
        if visible == 0 {
            let edge = target < cursor ? cursor - 1 : cursor
            if edge >= 0, edge < text.count, text[edge].isNewline { visible = 1 }
        }
        current.hops += 1
        guard current.hops <= Self.hopLimit, visible > 0 else {
            // The model's text is not where the field could show it: a seam. The chunk stops; its owner is planned again.
            unit = nil
            if case .edit(var state, let lane) = current.owner { state.failures += 1; requeue(.edit(state, lane)) } else { requeue(current.owner) }
            events.append(.resync(.checkFailed))
            if let report = lastReport { reseed(report, flight: nil) }
            return .wait
        }
        unit = current
        let to = target < cursor ? cursor - min(cursor - target, visible) : cursor + min(target - cursor, visible)
        let from = cursor
        let action = send(.move(units(to: to)), lane: lane, moveTo: to)
        inFlight?.hopFrom = from
        if let id { inFlight?.jumpSpan = id }
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
            // The next chunk, planned against the model as it is now. A chunk that changed nothing counts as failed.
            if state.plannedFrom == chars(of: span) { state.failures += 1 } else { state.failures = 0 }
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
        if let revision = state.revision,
           let ri = runs.firstIndex(where: { $0.runID == revision.runID }),
           let pi = runs[ri].pieces.firstIndex(where: { $0.spanID == id }) {
            runs[ri].pieces[pi].swapped = chars(of: span)
            runs[ri].pieces[pi].swappedEnd = revision.through
            runs[ri].pieces[pi].proposal = revision.proposal
            runs[ri].pieces[pi].revisedVersion = revision.version
            return
        }
        spans[id] = nil; finishSpan(state.anchorID)
        events.append(.applied(id: state.edit.id, cursor: cursorUnits))
    }

    private mutating func drop(_ state: EditState, _ reason: DropReason) {
        if let revision = state.revision,
           let ri = runs.firstIndex(where: { $0.runID == revision.runID }),
           let pi = runs[ri].pieces.firstIndex(where: { $0.spanID == state.spanID }) {
            runs[ri].pieces[pi].failedRevisionVersion = revision.version
            // These words were already delivered before the failed jump. Never start them again
            // at a new caret; only speech beyond that original frontier may append there.
            runs[ri].pieces[pi].tEnd = max(runs[ri].pieces[pi].tEnd ?? 0, revision.through)
            return
        }
        var partial: String?
        if let id = state.spanID, let span = spans[id], !span.parked, inFlight == nil { partial = String(chars(of: span)) }
        finishSpan(state.spanID); finishSpan(state.anchorID)
        events.append(.dropped(Drop(id: state.edit.id, runID: nil, kind: state.edit.kind, reason: reason,
                                    text: state.edit.target, partial: partial)))
    }

    private mutating func finishSpan(_ id: Int?) { if let id { spans[id] = nil } }

    // MARK: Live

    typealias SpeechDelivery = LegatoKeyboardCore.SpeechDelivery

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
        /// It stands in front of text without a space: one goes in at its end when the take is done.
        var spaceAfter = false
        /// The text a swap put in, standing for the delivered words before `swappedEnd`.
        var swapped: [Character]?
        var swappedEnd = 0
        /// Latest model proposal remains separate from the user's protected actual text.
        var proposal: [Character]?
        var revisedVersion: Int?
        var failedRevisionVersion: Int?
    }

    private func runNeedsWork(_ run: LiveRun) -> Bool {
        if run.pending != nil || swap?.runID == run.runID { return true }
        if !run.speaking, run.speech.hasDeferredRevision,
           run.pieces.contains(where: { $0.revisedVersion != run.version && $0.failedRevisionVersion != run.version }) { return true }
        if run.complete, run.version != nil, run.settledVersion != run.version, !run.pieces.isEmpty { return true }
        if run.complete, run.settledVersion == run.version, run.pieces.last?.spaceAfter == true { return true }
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

    private func liveRevision(for piece: Piece) -> LiveRevision? {
        if let queued = editLane.first(where: { $0.spanID == piece.spanID && $0.revision != nil })?.revision { return queued }
        if case .edit(let state, _)? = unit?.owner, state.spanID == piece.spanID { return state.revision }
        return nil
    }

    private func rawAppendPending(_ run: LiveRun) -> Bool {
        if untypedRest(of: run) != nil { return true }
        guard let piece = run.pieces.last(where: { $0.tEnd == nil }), let span = spans[piece.spanID],
              !span.parked, !span.userChanged, !span.edited, span.end == userCursor else { return false }
        if let revision = liveRevision(for: piece) {
            // A confirmed deletion in a partial correction is not newly missing speech. Only words beyond
            // that revision's original delivered frontier can interrupt it as a raw append.
            return run.delivered.count > revision.through
        }
        return !heldAppend(piece, in: run, span: span).isEmpty
    }

    /// Raw appends share the ordinary verified writer, but never wait behind a paused cleanup's remaining hunks.
    private mutating func nextLiveAppend() -> Action? {
        for ri in runs.indices where rawAppendPending(runs[ri]) {
            if let piece = runs[ri].pieces.last(where: { $0.tEnd == nil }), liveRevision(for: piece) != nil {
                closeOpenPieces(.edit, ri: ri, freeze: false)
            }
            if let action = typeOpenPiece(ri) { return action }
            if let action = startUntypedRest(ri) { return action }
        }
        return nil
    }

    /// While the selection or context is unverified (`hasUnverifiedInput`), a take's words still to be typed go in
    /// at the caret, as the user's keys do: a region's start with its separator and the open piece's untyped end,
    /// through the ordinary writer. Only ever an insert, never a move or a delete: a piece that needs more than an
    /// append (a revision, a lost place, a caret away from the user's) waits for the hold to lift. An insert that
    /// replaces a selection no report showed is accepted, as for a key; its report then becomes the model (`step`).
    private mutating func heldSpeechNext() -> Action {
        // An op that never confirmed may still be on its way: nothing follows it before the host's transit.
        if case .space? = unit?.owner { return nextInUnit() }
        guard !paused, unit == nil, swap == nil, strayInsertion == nil, tapRace == nil, userLost == nil, userLane.isEmpty,
              selection == 0, cursor == userCursor, let report = lastReport else { return .idle }
        for ri in runs.indices { applyPending(ri) }
        for ri in runs.indices where rawAppendPending(runs[ri]) {
            guard let piece = runs[ri].pieces.last(where: { $0.tEnd == nil }) else {
                if let action = startUntypedRest(ri, held: true) { return action }
                continue
            }
            guard liveRevision(for: piece) == nil, let span = spans[piece.spanID] else { continue }
            let rest = heldAppend(piece, in: runs[ri], span: span)
            guard !rest.isEmpty else { continue }
            let action = append(rest, to: piece)
            if case .send = action { inFlight?.heldSpeech = HeldSpeech(report: report, spanID: piece.spanID) }
            return action
        }
        return .idle
    }

    /// The open piece's next words at the caret, in one insert (speech is one chunk).
    private mutating func append(_ rest: [Character], to piece: Piece) -> Action {
        let spanID = piece.spanID
        return send(.insert(String(rest)), lane: .live) { q in
            q.insertAtCursor(rest, owner: spanID)
            q.userCursor = q.cursor
        }
    }

    private mutating func startUntypedRest(_ ri: Int, held: Bool = false) -> Action? {
        guard let from = untypedRest(of: runs[ri]) else { return nil }
        // The piece starts at the user's cursor (a reseed can leave the caret away from it).
        if cursor != userCursor { return held ? nil : send(.move(units(to: userCursor)), lane: .live, moveTo: userCursor) }
        // Held: no move to the word's end, the words go in where the caret is.
        if !held, let action = liveStart(ri) { return action }
        let anchor = String(text[max(0, userCursor - 200)..<userCursor])
        unit = Unit(ops: [.startRegion(run: runs[ri].runID, tStart: from, anchor: anchor)], owner: .space)
        return nextInUnit()
    }

    private mutating func nextLive() -> Action? {
        for ri in runs.indices { applyPending(ri) }
        for ri in runs.indices {
            if let action = settleFinal(ri) { return action }
            if runs[ri].complete, runs[ri].settledVersion == runs[ri].version, let action = separateFollowingText(ri) { return action }
            if let action = typeOpenPiece(ri) { return action }
            if let action = startUntypedRest(ri) { return action }
            if !runs[ri].speaking, let action = revisePieces(ri) { return action }
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

    private static func isWordCharacter(_ c: Character) -> Bool { c.isLetter || c.isNumber }

    /// A take that starts with the caret inside a word goes to the word's end first (nobody acted in it yet): nil when
    /// its next piece starts at the user's caret. Words that go on after the user put the caret inside a word are typed
    /// there with a space on each side (no move after the user acted; the space after goes in when the take is done).
    private mutating func liveStart(_ ri: Int) -> Action? {
        let at = userCursor
        guard runs[ri].pieces.isEmpty, !runs[ri].userActed, selection == 0,
              at > 0, at < text.count, Self.isWordCharacter(text[at - 1]), Self.isWordCharacter(text[at]) else { return nil }
        var end = at
        while end < text.count, Self.isWordCharacter(text[end]) { end += 1 }
        let action = send(.move(units(to: end)), lane: .live, moveTo: end)
        userCursor = cursor
        return action
    }

    /// The open piece of run `ri` at the user's caret: its delivered words go in one grapheme at a time; a revision of
    /// its last words (`nearChars`) goes in once the report shows the text it deletes.
    private mutating func typeOpenPiece(_ ri: Int) -> Action? {
        guard let pi = runs[ri].pieces.lastIndex(where: { $0.tEnd == nil }) else { return nil }
        let piece = runs[ri].pieces[pi]
        if spans[piece.spanID]?.parked == true {
            // Out of sight after a resync: it waits a moment to be found again at the caret.
            parkedPieceMs += stepElapsedMs
            guard parkedPieceMs >= Self.checkDeadlineMs else { return .wait }
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
        if desired.starts(with: current) { return append(Array(desired[current.count...]), to: piece) }
        // A verified revision of the last words: what differs goes, then is typed again.
        let k = current.count - Self.commonPrefix(current, desired)
        guard !runs[ri].userActed, k <= Self.nearChars, verifiesBefore(k, span: span) else {
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
        // Hosts with activity admission use the shared conditional lane during pauses; never
        // tail-retype unchanged characters while prioritizing incoming speech.
        guard !config.prioritizeSpeech, !run.complete, !run.userActed, run.speech.hasDeferredRevision,
              let span = spans[piece.spanID] else { return false }
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

    /// The field shows the run's newest version and that is still to be said (`Event.liveApplied`).
    private func ackDue(_ run: LiveRun) -> Bool {
        // A deferred revision is not in the field yet: the version is not shown.
        let unsettledRevision = run.speech.hasDeferredRevision && !run.complete
            && run.pieces.contains { $0.revisedVersion != run.version }
        guard !unsettledRevision, let version = run.version, run.pending == nil,
              run.ackedVersion != version, !runNeedsWork(run) else { return false }
        return true
    }

    private mutating func ack(_ ri: Int) {
        let run = runs[ri]
        guard ackDue(run), let version = run.version, inFlight == nil else { return }
        runs[ri].ackedVersion = version
        events.append(.liveApplied(runID: run.runID, version: version, complete: run.complete))
    }

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
    static func target(of snapshot: LiveDictationSnapshot) -> String { snapshot.text }

    static func joined(_ segments: some Sequence<LiveSegment>) -> String { LiveSegment.joined(segments.map(\.text)) }

    /// What a piece shows: its delivered words (after a swap's text), separated and capitalised against its anchor.
    private func desiredText(_ piece: Piece, in run: LiveRun) -> String {
        let delivered = run.delivered
        let end = min(delivered.count, piece.tEnd ?? delivered.count)
        if let swapped = piece.swapped {
            let from = min(piece.swappedEnd, end)
            return String(swapped) + FieldInsertion.prepare(String(delivered[from..<end]), contextBefore: piece.anchor + String(swapped),
                                                             capitalization: config.capitalization)
        }
        let start = min(piece.tStart, end)
        return FieldInsertion.prepare(String(delivered[start..<end]), contextBefore: piece.anchor, capitalization: config.capitalization)
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
        return Array(FieldInsertion.prepare(Self.joined(own), contextBefore: piece.anchor, capitalization: config.capitalization))
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
    /// typed so far. A user action (`freeze`) ends the keyboard's edits of the take (`LiveRun.userActed`).
    private mutating func closeOpenPieces(_ cause: CloseCause, ri only: Int? = nil, freeze: Bool? = nil) {
        // Anything but the next run may be the user's doing (a resync is a change the model cannot explain): the pieces
        // before it are never corrected.
        let freezes = freeze ?? (cause != .newRun && only == nil)
        for ri in runs.indices where only == nil || only == ri {
            if only == nil { applyPending(ri) }
            // A change nothing explains may be the user's too: the take is only appended to from now on.
            if freezes { runs[ri].userActed = true }
            guard let pi = runs[ri].pieces.lastIndex(where: { $0.tEnd == nil }) else { continue }
            let piece = runs[ri].pieces[pi]
            if let revision = liveRevision(for: piece) {
                // A partial revision is not missing speech. Preserve the delivered frontier it began with;
                // later appended words still start after the user's input, exactly once.
                runs[ri].pieces[pi].tEnd = revision.through
                events.append(.regionClosed(runID: runs[ri].runID, cause: cause))
                continue
            }
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
            let prepared = Array(FieldInsertion.prepare(String(slice), contextBefore: context, capitalization: config.capitalization))
            let trimmed = String(slice.dropFirst(lead)).trimmingCharacters(in: .whitespaces)
            let separator = max(0, prepared.count - trimmed.count)
            // How much of the delivered text the piece shows (a parked piece: as much as was typed).
            let typed = span?.parked == true ? max(0, (span.map { $0.end - $0.start } ?? 0) - prefix)
                : Self.commonPrefix(Array(current.dropFirst(prefix)), prepared)
            var end = min(delivered.count, base + lead + max(0, typed - separator))
            // Finish a word already started, never an entirely untyped word after a delivered space.
            // The short input budget makes this boundary common when Enter interrupts a stopped backlog.
            if end > 0, Self.isWordCharacter(delivered[end - 1]) {
                while end < delivered.count, !delivered[end].isWhitespace { end += 1 }
            }
            runs[ri].pieces[pi].tEnd = max(base, end)
            events.append(.regionClosed(runID: runs[ri].runID, cause: cause))
        }
    }

    /// Map only revisions entirely inside one delivered piece. A change crossing an intervening
    /// user boundary is left alone; no guessed distribution of a rewritten sentence across fields.
    private func revisionProposal(_ pi: Int, in run: LiveRun) -> [Character] {
        if run.complete, let final = finalText(pi, in: run) { return final }
        let piece = run.pieces[pi], delivered = run.delivered
        let a = min(piece.tStart, delivered.count), b = min(piece.tEnd ?? delivered.count, delivered.count)
        let target = run.complete ? Array(Self.joined(run.segments)) : run.speech.authoritative
        var raw = Array(delivered[a..<b])
        let contentStart = a + raw.prefix { $0.isWhitespace }.count
        for h in FieldEditCoordinator.changes(from: delivered, to: target).reversed() {
            guard h.start >= a, h.end <= b,
                  h.start < b || (pi == run.pieces.count - 1 && h.start == b) else { continue }
            // A cleaner's join punctuation belongs between speech pieces. The user may have
            // put a newline/list marker there; never move that joiner to the next line's start.
            if pi > 0, h.start < contentStart || (h.start == contentStart && h.end == h.start) { continue }
            raw.replaceSubrange((h.start - a)..<(h.end - a), with: h.text)
        }
        return Array(FieldInsertion.prepare(String(raw), contextBefore: piece.anchor, capitalization: config.capitalization))
    }

    private func conditionalRevisionTarget(base: [Character], current: [Character], proposal: [Character], span: Span) -> [Character] {
        // Punctuation typed immediately after the dictated scope is still the user's. Include
        // that evidence in the merge so cleanup cannot append a second terminal mark before it.
        let adjacent = Array(text[span.end...].prefix { character in
            character.unicodeScalars.allSatisfy { CharacterSet.punctuationCharacters.contains($0) }
        })
        let merged = FieldMerge.rebase(base: base, kept: current + adjacent, incoming: proposal).text
        guard adjacent.isEmpty || merged.suffix(adjacent.count).elementsEqual(adjacent) else { return current }
        return Array(merged.dropLast(adjacent.count))
    }

    /// Automatic corrections use the existing conditional edit lane. User input can abort and
    /// replan between confirmed graphemes; each jump still requires the queue's ordinary proof.
    private mutating func revisePieces(_ ri: Int) -> Action? {
        let run = runs[ri]
        guard run.complete || !run.speaking, let version = run.version,
              selection == 0, !hasUnverifiedInput, untypedRest(of: run) == nil else { return nil }
        if editLane.contains(where: { $0.revision?.runID == run.runID }) { return .wait }
        if case .edit(let state, _)? = unit?.owner, state.revision?.runID == run.runID { return .wait }
        for pi in run.pieces.indices {
            let piece = run.pieces[pi]
            guard piece.revisedVersion != version, piece.failedRevisionVersion != version else { continue }
            guard let span = spans[piece.spanID], !span.parked, !span.edited else {
                runs[ri].pieces[pi].failedRevisionVersion = version
                continue
            }
            let current = chars(of: span), expected = Array(desiredText(piece, in: run))
            // The speaking head must finish its heard append first; revisions never type missing speech twice.
            if piece.tEnd == nil, current.count < expected.count, expected.starts(with: current) { return nil }
            let proposal = revisionProposal(pi, in: run)
            let baseline = piece.proposal ?? expected
            let target = conditionalRevisionTarget(base: baseline, current: current, proposal: proposal, span: span)
            if target == current {
                runs[ri].pieces[pi].proposal = proposal
                runs[ri].pieces[pi].revisedVersion = version
                continue
            }
            var state = EditState(edit: Edit(id: "\(run.runID)#revision-\(piece.spanID)", kind: .version,
                target: String(target), cursorAtEnd: false))
            state.spanID = piece.spanID
            state.revision = LiveRevision(runID: run.runID, version: version, proposal: proposal,
                                          through: piece.tEnd ?? run.delivered.count, baseline: current)
            editLane.append(state)
            return nextEdit() ?? .wait
        }
        return nil
    }

    // MARK: Swap at stop

    /// The stop's one swap: the take, untouched by the user, goes in one delete and its final text in one insert at the
    /// caret, once the report's text before the caret showed the take's end as the model has it (the model is trusted
    /// beyond the window: the keyboard is the field's only writer). Keys wait for the insert once the delete went.
    struct Swap: Sendable, Equatable {
        var runID: String
        var version: Int
        var spanID: Int
        var text: [Character]
        /// The model's text around the take when the delete went: a report that does not fit the model after it may
        /// still show just this (Safari's block echo), the take gone from between.
        var before: [Character]
        var after: [Character]
        /// The delete went and the insert too: its confirmation is due.
        var inserted = false
    }
    private var swap: Swap?
    /// How long the open piece has been out of sight.
    private var parkedPieceMs = 0.0
    /// A revision while speaking edits at most this many characters before the caret.
    public static let nearChars = 60
    /// The swap needs the report to show this much of the take before the caret (all of a shorter take).
    static let tailChars = 16

    /// Settle a completed version through minimal conditional edits first. A failed jump may use the strict
    /// untouched end-verified swap; otherwise keep the field and recover the proposal in History.
    private mutating func settleFinal(_ ri: Int) -> Action? {
        let run = runs[ri]
        guard run.complete, let version = run.version, run.settledVersion != version, swap == nil,
              let pi = run.pieces.indices.last, untypedRest(of: run) == nil else { return nil }
        let piece = run.pieces[pi]
        func keep(_ reason: DropReason?) -> Action? {
            // The take's words still to type go in first (at the caret); it settles once they are in.
            if piece.tEnd == nil, let span = spans[piece.spanID], !span.parked, chars(of: span) != Array(desiredText(piece, in: run)) { return nil }
            runs[ri].settledVersion = version
            reportFallback(ri, reason)
            return separateFollowingText(ri)
        }
        if let action = revisePieces(ri) { return action }
        let revised = runs[ri]
        if revised.pieces.allSatisfy({ $0.revisedVersion == version }) { return keep(run.userActed ? .userEdited : nil) }
        // A verified jump failed: only the old end-verified, untouched block swap may still recover it.
        if run.userActed { return keep(.userEdited) }
        guard let final = finalText(pi, in: run) else { return keep(.changed) }
        guard let span = spans[piece.spanID], !span.parked else { return keep(.unplaceable) }
        let current = chars(of: span)
        if current == final { return keep(nil) }
        // The delivered words are the final text: typing gets there.
        if piece.tEnd == nil, Array(desiredText(piece, in: run)) == final, final.starts(with: current) { return nil }
        guard !span.userChanged, !span.edited, selection == 0, span.end == userCursor, cursor == userCursor else { return keep(.changed) }
        guard showsTake(span) else {
            events.append(.resync(.swapRefused))
            return keep(.changed)
        }
        swap = Swap(runID: run.runID, version: version, spanID: piece.spanID, text: final,
                    before: Array(text[max(0, span.start - 200)..<span.start]), after: Array(text[span.end..<min(text.count, span.end + 200)]))
        guard span.end > span.start else { return nextSwap() }
        let id = piece.spanID
        return send(.deleteBackward(span.end - span.start), lane: .live) { q in q.removeRange(span.start, span.end, owner: id) }
    }

    /// The report's text before the caret (its visible tail) shows the take's end as the model has it: `tailChars` of
    /// it at least (all of a shorter take), and the report fits the model at the caret.
    private func showsTake(_ span: Span) -> Bool {
        guard let report = lastReport, report.selected == nil, span.end == cursor,
              FieldReader.trusted(before: report.before).count >= min(span.end - span.start, Self.tailChars) else { return false }
        return FieldMatch.positions(in: text, reportedBefore: report.before, reportedAfter: report.after).contains(cursor)
    }

    /// The report's text right next to the caret (`contextChars` a side) is the text that stood around the take.
    static func showsGap(_ report: Report, before: [Character], after: [Character]) -> Bool {
        guard report.selected == nil else { return false }
        let b = Array(FieldReader.trusted(before: report.before).suffix(contextChars)), a = Array(report.after.prefix(contextChars))
        return b.count >= min(contextChars, before.count) && before.suffix(b.count).elementsEqual(b)
            && a.count <= after.count && after.prefix(a.count).elementsEqual(a)
    }

    /// The swap's insert, once its delete went: the final text goes where the take was. Nil once the swap is over.
    private mutating func nextSwap() -> Action? {
        guard var s = swap else { return nil }
        guard let ri = runs.firstIndex(where: { $0.runID == s.runID }) else { swap = nil; return nil }
        if !s.inserted {
            if spans[s.spanID]?.parked == true, !runs[ri].userActed, cursor == userCursor, selection == 0, let report = lastReport,
               Self.showsGap(report, before: s.before, after: s.after) {
                // The report after the delete did not fit the model, but the caret stands between the text that was
                // around the take (Safari's block echo read differently): the caret is where the take was.
                spans[s.spanID] = Span(start: cursor, end: cursor)
            }
            // Anything else after the delete (a tap or another change raced with it), or the user acting: nothing goes in
            // where the take was not seen to go (the take is in History).
            guard !runs[ri].userActed, let span = spans[s.spanID], !span.parked, span.start == span.end, cursor == span.start, userCursor == cursor else {
                failSwap(); return nil
            }
            guard !s.text.isEmpty else { finishSwap(); return nil }
            s.inserted = true; swap = s
            let id = s.spanID, text = s.text
            return send(.insert(String(text)), lane: .live) { q in
                q.insertAtCursor(text, owner: id)
                q.userCursor = q.cursor
            }
        }
        // The insert confirmed with the final text in place: done. Anything else (a resync on its way) leaves it unknown.
        guard let span = spans[s.spanID], !span.parked, chars(of: span) == s.text, span.end == cursor else { failSwap(); return nil }
        finishSwap()
        return nil
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

    /// The take is done and its last piece stands in front of text without a space: one goes in at its end, where the
    /// caret is (an insert, never a move back). Not when the user is elsewhere.
    private mutating func separateFollowingText(_ ri: Int) -> Action? {
        guard let pi = runs[ri].pieces.indices.last, runs[ri].pieces[pi].spaceAfter else { return nil }
        runs[ri].pieces[pi].spaceAfter = false
        guard let span = spans[runs[ri].pieces[pi].spanID], !span.parked, span.end == cursor, cursor == userCursor, selection == 0,
              cursor < text.count, !FieldInsertion.trailingSeparator(after: String(text.prefix(cursor)), before: text[cursor]).isEmpty else { return nil }
        return send(.insert(" "), lane: .live) { q in
            q.insertAtCursor([" "], owner: nil)
            q.userCursor = q.cursor
        }
    }

    /// The swap stops after its delete went: the take's characters are gone from the field, and a drop says so (the
    /// final text is in History). Nothing of the take is edited again.
    private mutating func failSwap() {
        guard let s = swap else { return }
        swap = nil
        events.append(.resync(.swapRefused))
        guard let ri = runs.firstIndex(where: { $0.runID == s.runID }) else { return }
        runs[ri].settledVersion = s.version
        runs[ri].settledThrough = runs[ri].delivered.count
        closeOpenPieces(.resync, ri: ri, freeze: true)
        reportFallback(ri, .unplaceable, force: true)
    }

    /// The run's final text does not stand whole in the field (a piece kept raw, or the user's edits in it): the app
    /// keeps it in History. Reported once per run; `force`: without looking (the field is known not to show it).
    private mutating func reportFallback(_ ri: Int, _ reason: DropReason?, force: Bool = false) {
        let run = runs[ri]
        guard !run.fallbackReported, run.complete else { return }
        // An untouched take's raw version kept as typed says nothing yet: its cleanup comes next and is tried on its own.
        guard force || run.cleaned || run.userActed else { return }
        let whole = Self.joined(run.segments)
        var shown = !force
        for pi in run.pieces.indices where shown {
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

    /// Sends one op of a chunk: the model takes it at once (`apply`, or the caret at `moveTo`). The first op of a chunk
    /// opens its check (the state before it is what a report must not merely show); later ops, and the user's input
    /// behind a chunk, join that check.
    private mutating func send(_ op: ShadowOp, lane: Lane, anywhere: Bool = false, moveTo: Int? = nil,
                               _ apply: (inout FieldQueue) -> Void = { _ in }) -> Action {
        let joining = inFlight
        if joining == nil {
            let isCursorMove: Bool
            if case .move = op { isCursorMove = true } else { isCursorMove = false }
            guard coordinator.begin(isCursorMove ? .move : .edit) else { return .wait }
        }
        let opPre = doc
        let rollback: RevisionRollback?
        if case .edit(let state, _)? = unit?.owner, let revision = state.revision {
            rollback = RevisionRollback(editID: state.edit.id, baseline: revision.baseline)
        } else { rollback = nil }
        if let moveTo { cursor = moveTo } else { apply(&self) }
        var flight = InFlight(op: op, lane: lane, anywhere: anywhere || joining?.anywhere == true, pre: joining?.pre ?? opPre)
        flight.ops = (joining?.ops ?? []) + [op]
        flight.sentOn = joining?.sentOn ?? lastReport
        flight.jumpSpan = joining?.jumpSpan
        flight.input = joining?.input
        inFlight = flight
        coordinator.dispatched()
        lastSentOp = op; lastSentLane = lane
        recentSends.append(Sent(op: op, lane: lane, pre: opPre, revisionRollback: rollback))
        if recentSends.count > 16 { recentSends.removeFirst() }
        sinceSendMs = 0
        events.append(.sent(op, lane))
        return .send(op)
    }

    /// The field's units from the cursor to `index` (UTF-16, or characters in a field that moves by characters).
    private func units(to index: Int) -> Int { doc.units(to: index, byCharacters: movesByCharacters) }

    /// The field's unit for moves: as configured, or as a look found it (`look`).
    private var movesByCharacters: Bool { learnedByCharacters ?? config.movesByCharacters }

    // MARK: Model

    private mutating func insertAtCursor(_ chars: [Character], owner: Int?) {
        guard !chars.isEmpty else { return }
        record(.insert(at: cursor, count: chars.count, owner: owner))
        doc.insertAtCursor(chars, owner: owner)
        updateRevisionBaseline(owner: owner)
    }

    private mutating func removeRange(_ a: Int, _ b: Int, owner: Int?) {
        guard a < b, a >= 0, b <= text.count else { return }
        record(.remove(a, b, owner: owner))
        doc.removeRange(a, b, owner: owner)
        updateRevisionBaseline(owner: owner)
    }

    private mutating func updateRevisionBaseline(owner: Int?) {
        guard let owner, let span = spans[owner],
              case .edit(var state, let lane)? = unit?.owner,
              state.spanID == owner, var revision = state.revision else { return }
        revision.baseline = chars(of: span)
        state.revision = revision
        unit?.owner = .edit(state, lane)
    }

    private mutating func prepend(_ chars: [Character]) {
        guard !chars.isEmpty else { return }
        record(.grow(chars.count))
        if let from = userLost?.from { userLost?.from = from + chars.count }
        doc.prepend(chars)
    }

    private func chars(of span: Span) -> [Character] { doc.chars(of: span) }

    private mutating func addSpan(_ span: Span) -> Int { doc.addSpan(span) }

    private mutating func seed(_ report: Report) {
        doc.seed(report)
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
        let extra = before.count - cursor
        let grown = Array(before.prefix(extra)) + text
        return FieldMatch.positions(in: grown, reportedBefore: report.before, reportedAfter: (report.selected ?? "") + report.after) == [cursor + extra]
    }

    private func fitsSelection(_ p: Int, _ selected: String) -> Bool { doc.fitsSelection(p, selected) }

    /// The report fits the state at its cursor, wholly inside its text (no reaching past either end).
    private func fitsInside(_ report: Report, in state: ModelState) -> Bool { state.fitsInside(report) }

    /// The report fits the state at its cursor, perhaps elsewhere too.
    private func fits(_ report: Report, in state: ModelState) -> Bool { state.fits(report) }

    private func pins(_ report: Report, in state: ModelState) -> Bool { state.pins(report) }

    /// The report pins a unique place in the model: the cursor (and selection) is there.
    private mutating func relocate(_ report: Report) {
        let selected = report.selected ?? ""
        let found = FieldMatch.positions(in: text, reportedBefore: report.before, reportedAfter: selected + report.after)
        guard found.count == 1 else { return }
        cursor = found[0]; userCursor = cursor; selection = selected.count
    }

    /// A confirmed report that shows more than the model knows extends it.
    private mutating func merge(_ report: Report) {
        let grown = doc.extend(with: report)
        if grown.front > 0 {
            record(.grow(grown.front))
            if let from = userLost?.from { userLost?.from = from + grown.front }
        }
        unparkSpans()
    }

    private mutating func restore(_ state: ModelState) {
        // The changes since a read no longer lead to this text.
        readMarks = []
        doc.restore(state)
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
            let from = flight.hopFrom ?? flight.pre.cursor
            let stayed = flight.hopFrom != nil ? found.contains(from) : fits(report, in: flight.pre)
            let short = found.count == 1 && min(from, cursor) < found[0] && found[0] < max(from, cursor)
            if short || stayed || found.count > 1 {
                jumpFailed(to: target, flight: flight, report: report, caret: short ? found[0] : from)
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
        if found.count > 1, flight != nil || reportStableMs < Self.checkDeadlineMs {
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
                                units: movesByCharacters ? oldUser - oldCursor : units, homed: false)
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
                let moved = movesByCharacters ? b - a : String(text[a..<b]).utf16.count
                if moved < abs(lost.units) { userCursor = from }
            }
        } else if hits.count == 1, let p = hits.first {
            userCursor = p; userLost = nil
        }
    }

    /// A speculative revision write landed somewhere else. Its missing intended character is our
    /// interrupted operation, not a user's deletion, so conditional merge must use the pre-send baseline.
    private mutating func restoreRevisionBaseline(_ rollback: RevisionRollback?) {
        guard let rollback else { return }
        if case .edit(var state, let lane)? = unit?.owner, state.edit.id == rollback.editID {
            state.revision?.baseline = rollback.baseline
            unit?.owner = .edit(state, lane)
        }
        for index in editLane.indices where editLane[index].edit.id == rollback.editID {
            editLane[index].revision?.baseline = rollback.baseline
        }
    }

    /// The report fits the known text (or the text before the chunk in flight, shown late) at one place inside it that is
    /// neither where the chunk left the caret nor where it was before: no op went there, so the user tapped. Returns that
    /// place in the current text.
    private func tappedElsewhere(_ report: Report, flight: InFlight?) -> (at: Int, seen: ModelState?)? {
        let current = doc
        let pre = flight?.pre ?? current
        guard report.selected == nil, selection == 0, !fits(report, in: pre), !fits(report, in: current),
              // As much agreeing text as finding text again: a short window at an edge may be another field's.
              hasEvidence(report) else { return nil }
        // The text before the chunk only when the report fits the current text nowhere (old text shown at the tap);
        // repetitive text that fits here several times says nothing.
        let fitsNow = !FieldMatch.positions(in: text, reportedBefore: report.before, reportedAfter: report.after).isEmpty
        let states = [current] + (fitsNow ? [] : [pre])
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
            // At that state's own caret it is that state, late: not a tap.
            guard p != state.cursor, here != cursor, here != pre.cursor else { return nil }
            var seen = state
            seen.cursor = p; seen.userCursor = p; seen.selection = 0
            return (here, state.text == text ? nil : seen)
        }
        return nil
    }

    /// The user tapped at `at` (current text) while a chunk was on its way: everything stops there.
    private mutating func userTapped(at: Int, flight: InFlight?) {
        recoveryRevision &+= 1; recoveryRequest = nil
        abortUnit()
        cursor = at; userCursor = at; selection = 0
        closeOpenPieces(.cursor)
        quietAfterMove = true
        // The last ops may still be landing where the user tapped.
        if !recentSends.isEmpty { tapRace = (recentSends, 0) }
        events.append(.resync(.cursorMoved))
    }

    /// The last inserts that were on their way at the tap (one or several of one lane) show right before the tapped
    /// caret: they landed there, not where they were sent for. The model takes them there (and back out where they were
    /// meant to go). The user's own keys stay, and so does dictation's (nothing is deleted after the user's tap; the
    /// take is reported); an edit's text comes out again (`strayInsertion`).
    private mutating func tapRaceLanded(_ report: Report) -> Bool {
        guard let race = tapRace, report.selected == nil, let last = race.sends.last else { return false }
        if case .deleteBackward(let count) = last.op { return tapRaceDeleteLanded(report, count: count, pre: last.pre, rollback: last.revisionRollback) }
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
            restoreRevisionBaseline(sent.revisionRollback)
            cursor = p; userCursor = p; selection = 0
            insertAtCursor(Array(key), owner: -1)
            if last.lane == .user { userCursor = cursor } else if last.lane == .live {
                // Dictation never deletes after the user's tap: its text stays where it landed, the caret after it (the
                // take's later words follow there), and the take is reported (its text is in History).
                userCursor = cursor
                if let run = runs.last {
                    events.append(.dropped(Drop(id: "stray:" + run.runID, runID: run.runID, kind: nil, reason: .unplaceable,
                                                text: run.complete ? Self.joined(run.segments) : String(run.delivered), partial: key)))
                }
            } else {
                userCursor = p
                strayInsertion = StrayInsertion(text: key,
                    before: String(sent.pre.text[max(0, p - Self.relocateChars)..<p]),
                    after: String(sent.pre.text[p..<min(sent.pre.text.count, p + Self.relocateChars)]), lane: last.lane)
            }
            tapRace = nil
            return true
        }
        return false
    }

    /// Never keep typing captive to missing ownership evidence. An uncertain repair is a failed delivery,
    /// not permission to delete at a new caret or to continue the interrupted take's automatic edits.
    private mutating func refuseStrayInsertion() {
        guard let stray = strayInsertion else { return }
        strayInsertion = nil
        events.append(.resync(.recoveryRefused))
        events.append(.dropped(Drop(id: "stray:" + UUID().uuidString, runID: nil, kind: nil,
                                    reason: .unplaceable, text: stray.text, partial: nil)))
    }

    /// The delete that was on its way at the tap landed there: the report shows the text before it with the characters
    /// in front of the tapped place gone (fewer at the text's start). The model takes that; what it deleted was not the
    /// keyboard's to delete, so it goes back in, and the user's cursor is where they tapped.
    private mutating func tapRaceDeleteLanded(_ report: Report, count: Int, pre: ModelState, rollback: RevisionRollback?) -> Bool {
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
        restoreRevisionBaseline(rollback)
        let deleted = Array(text[hit.q..<(hit.q + hit.n)])
        removeRange(hit.q, hit.q + hit.n, owner: nil)
        cursor = hit.q; userCursor = hit.q; selection = 0
        tapRace = nil
        if !deleted.isEmpty { unit = Unit(ops: [.insert(String(deleted), owner: nil), .setUserCursorToCursor], owner: .space) }
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
        // A span parked for an unverified edit is found by a fresh read only: the model's own text proves nothing.
        for (id, var span) in spans where span.parked && span.landedText == nil {
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
