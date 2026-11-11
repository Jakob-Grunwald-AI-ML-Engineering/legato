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
///   dictation runs (`LiveDictationSnapshot`, coalesced to the newest per run).
/// - Planning happens when an item starts, against the model as it is then. A change away from the cursor is a jump
///   unit: move to the change, delete and insert only the differing characters (`ShadowEditPlanner.diff`), move back.
///   Nothing else goes out while a unit runs; user input ends the unit early (the caret goes back first) and the rest
///   is planned again later.
/// - Never freezes: a report that does not confirm leads to a resync (re-locate the model around the cursor, unique
///   matches only, or take the report as the new model) and planning goes on. An edit is dropped only when its text
///   cannot be placed or the user changed it (`Event.dropped`); a dictation region that is out of sight waits.
/// - Dictation regions: a run types at its open region's end. A user key or cursor move closes the region (a word cut
///   short by a key is finished first); later raw words start a new region at the user's cursor. Revisions and
///   cleanups of the run's text land in its regions as jump units (text added at the take's end goes to its last
///   region); in a region the user edited, only the changes that touch the user's words are dropped (`FieldMerge`).
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
        public init(animated: Bool = true, movesByCharacters: Bool = false, capitalization: AutoCapitalizationType = .none) {
            self.animated = animated; self.movesByCharacters = movesByCharacters; self.capitalization = capitalization
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
        /// From the user's first change on: who wrote each character, and the keyboard's characters the user deleted. A
        /// dictation region merges the run's newer text against the keyboard's view (`FieldMerge`), so the user's
        /// words stay and the rest lands.
        var cells: [Cell]?
    }
    enum Cell: Sendable, Equatable {
        case own(Character)
        case user(Character)
        /// The keyboard's, deleted by the user.
        case gone(Character)
        var shown: Character? { switch self { case .own(let c), .user(let c): c; case .gone: nil } }
    }

    /// The keyboard's view of a span the user changed (its text without the user's changes) and the user's changes as
    /// hunks of it.
    static func ownView(_ cells: [Cell]) -> (own: [Character], userHunks: [ShadowEditPlanner.Hunk]) {
        var own: [Character] = [], hunks: [ShadowEditPlanner.Hunk] = []
        var open: ShadowEditPlanner.Hunk?
        for cell in cells {
            switch cell {
            case .own(let c):
                if let h = open { hunks.append(h); open = nil }
                own.append(c)
            case .user(let c):
                if open == nil { open = .init(start: own.count, end: own.count, text: []) }
                open?.text.append(c)
            case .gone(let c):
                if open == nil { open = .init(start: own.count, end: own.count, text: []) }
                own.append(c); open?.end = own.count
            }
        }
        if let h = open { hunks.append(h) }
        return (own, hunks)
    }

    /// Where shown offset `r` is in the cells, past the deleted cells right there.
    private static func cellIndex(_ r: Int, in cells: [Cell]) -> Int {
        var shown = 0, i = 0
        while i < cells.count {
            if cells[i].shown != nil { if shown == r { break }; shown += 1 }
            i += 1
        }
        return i
    }

    /// A region the user edited: the run's text merged into the field's text where it touches no word the user changed.
    private func merged(_ span: Span, desired: [Character]) -> FieldMerge.Result? {
        guard let cells = span.cells else { return nil }
        let view = Self.ownView(cells)
        return FieldMerge.rebase(base: view.own, kept: chars(of: span), incoming: desired, keptHunks: view.userHunks)
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
    }
    private var userLane: [UserItem] = []
    private var editLane: [EditState] = []

    struct Region: Sendable, Equatable {
        var spanID: Int
        var tStart: Int
        /// nil: the open region (it takes all of the target after `tStart`).
        var tEnd: Int?
        var anchor: String
        var abandoned = false
        /// The text the region last held as the run wanted it: a user edit with no newer revision drops nothing.
        var landed: [Character] = []
        /// A revision the region could not take was reported: it drops once, not once per version.
        var dropped = false
    }
    struct LiveRun: Sendable, Equatable {
        var runID: String
        var version: Int?
        var complete = false
        var pending: LiveDictationSnapshot?
        var target: [Character] = []
        var regions: [Region] = []
        var ackedVersion: Int?
        /// The highest segment id seen so far: a cleaned segment up to it is a rewrite of known words, not new speech.
        var lastSegmentID = -1
        /// Every segment is cleaned: no later cleanup is coming.
        var cleaned = false
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
    private enum UnitOwner: Sendable, Equatable { case edit(EditState, Lane), region(run: String), space }
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
    }
    private var inFlight: InFlight?
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
    /// Characters of the keyboard's own that landed where the user tapped: they come out before anything else.
    private var strayChars = 0
    private var strayLane = Lane.live
    private var lastSendConfirmed = true
    private var lastSentOp: ShadowOp?
    /// How far the last paced insert went past its pace (the tick's overshoot), counted toward the next.
    private var paceCreditMs = 0.0
    private var lastSentLane = Lane.live
    static let quietMs = 250.0

    public init(config: Config = Config()) { self.config = config }

    // MARK: Inspection

    public var isIdle: Bool {
        inFlight == nil && unit == nil && userLane.isEmpty && editLane.isEmpty && !runs.contains(where: { runNeedsWork($0) })
    }
    public var hasUserInput: Bool { !userLane.isEmpty }
    /// The keyboard's own writes still to land (a unit, queued edits, dictation): a read for an instruction waits for
    /// them, so its scope already shows them.
    public var hasOwnWork: Bool {
        unit != nil || !editLane.isEmpty || runs.contains(where: { runNeedsWork($0) })
    }
    public var hasOpInFlight: Bool { inFlight != nil }
    /// Nothing in flight and the caret at the user's cursor: the field is as the user left it, as far as the queue goes.
    public var isHome: Bool { inFlight == nil && cursor == userCursor && sinceSendMs >= Self.transitMs }
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
    /// The open dictation region (for the instruction scope `session`): its run, anchor and text.
    public var openRegion: (runID: String, anchor: String, text: String)? {
        guard let run = runs.last, let region = run.regions.last, region.tEnd == nil, let span = spans[region.spanID] else { return nil }
        return (run.runID, region.anchor, String(chars(of: span)))
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
            for region in run.regions {
                let span = spans[region.spanID]
                parts.append("[\(region.tStart)..\(region.tEnd.map(String.init) ?? "open") parked=\(span?.parked ?? true) "
                             + "changed=\(span?.userChanged ?? false) abandoned=\(region.abandoned) "
                             + "has=\(String(span.map { chars(of: $0) } ?? []).debugDescription) wants=\(desiredText(region, in: run).debugDescription)]")
            }
            if let rest = untypedRest(of: run) { parts.append("rest@\(rest)") }
        }
        return parts.joined(separator: " ")
    }

    // MARK: Enqueue

    public mutating func enqueue(_ input: Input) {
        userLane.append(.input(input, retried: false))
    }

    /// `user`: an edit the user asked for (word row, undo, version swap): it goes in the user lane.
    public mutating func enqueue(_ edit: Edit, user: Bool = false) {
        var state = EditState(edit: edit)
        if seeded, !edit.atCursor, edit.selected == nil { state.anchorID = addSpan(Span(start: userCursor, end: userCursor, anchor: true)) }
        if user { userLane.append(.edit(state)) } else { editLane.append(state) }
    }

    /// A live run's newest snapshot. Snapshots of a run coalesce to the newest; a new run closes the last run's region.
    public mutating func enqueue(_ snapshot: LiveDictationSnapshot) {
        if let index = runs.firstIndex(where: { $0.runID == snapshot.runID }) {
            if let latest = runs[index].pending?.version ?? runs[index].version, snapshot.version <= latest, snapshot.complete == runs[index].complete { return }
            runs[index].pending = snapshot
            return
        }
        guard !retiredRunIDs.contains(snapshot.runID) else { return }
        closeOpenRegions(.newRun)
        var run = LiveRun(runID: snapshot.runID)
        run.pending = snapshot
        runs.append(run)
    }

    /// Ends work for a run: its unfinished text is reported as dropped (the app keeps the take in History).
    public mutating func cancelRun(_ runID: String) {
        guard let index = runs.firstIndex(where: { $0.runID == runID }) else { return }
        if case .region(let r)? = unit?.owner, r == runID { unit = nil }
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
        stepElapsedMs = elapsedMs
        sinceSendMs += elapsedMs
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
            let settled = sinceSendMs >= flight.settleMs
            // A report that fits the state before the op as well proves nothing (the op may still be on its way), and
            // neither does one that shows a state the host lags behind.
            // A stale check's zero-offset move changes nothing: a fresh report of the model is its confirmation.
            if settled, matches(report, anywhere: flight.anywhere),
               flight.anywhere || !pins(report, in: flight.pre) || (flight.staleCheck && flight.op == .move(0)),
               !lagging.contains(where: { pins(report, in: $0.state) }) {
                if flight.anywhere { relocate(report) }
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
                if !userLane.isEmpty, flight.waitedMs >= Self.userBoundMs, pinsPre {
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
                lost.homed = true; userLost = lost
                abortUnit()
                return send(.move(lost.units), lane: .edit, anywhere: true) { _ in }
            }
        }
        if paused {
            abortUnit()
            if cursor != userCursor, selection == 0 { return send(.move(units(to: userCursor)), lane: .user, moveTo: userCursor) }
            return .wait
        }
        // User input first; a running unit gives the caret back first.
        if strayChars > 0, selection == 0 {
            // The keyboard's own text that landed where the user tapped comes out first (the caret is right after it).
            let count = strayChars
            strayChars = 0
            abortUnit()
            return send(.deleteBackward(count), lane: strayLane) { q in
                q.removeRange(q.cursor - count, q.cursor, owner: -1)
                q.userCursor = q.cursor
            }
        }
        if !userLane.isEmpty {
            abortUnit()
            if cursor != userCursor, selection == 0 { return send(.move(units(to: userCursor)), lane: .user, moveTo: userCursor) }
            if let action = nextUser() { return action }
        }
        if quietAfterMove {
            // Ops sent before the tap may still be landing where the user tapped: nothing of the keyboard's own
            // goes until the field holds still and shows what the model expects.
            guard inFlight == nil, reportStableMs >= Self.quietMs, let report = lastReport, consistent(report) else { return .wait }
            quietAfterMove = false
        }
        if unit != nil { return nextInUnit() }
        if selection > 0 { return .idle }
        if let action = nextEdit() { return action }
        if let action = nextLive() { return action }
        return .idle
    }

    private mutating func nextUser() -> Action? {
        while let item = userLane.first {
            switch item {
            case .input(let input, let retried):
                if case .insert(let key) = input, let finish = finishWordBeforeKey(key) { userLane.removeFirst(); return finish }
                userLane.removeFirst()
                if case .move = input { closeOpenRegions(.cursor) } else { closeOpenRegions(.keystroke) }
                if let action = sendUser(input, retried: retried) { return action }
            case .edit(var state):
                userLane.removeFirst()
                closeOpenRegions(.edit)
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
        case .insert(let key):
            let action = send(.insert(key), lane: .user) { q in
                if q.selection > 0 { q.removeRange(q.cursor, q.cursor + q.selection, owner: nil); q.selection = 0 }
                q.insertAtCursor(Array(key), owner: nil)
                q.userCursor = q.cursor
            }
            inFlight?.input = input; inFlight?.retried = retried
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

    /// A key at the open region's end while the typewriter has shown only part of a word: the word's rest goes in
    /// with the key, in one insert (with a space when the key starts a word), so the key lands after the word.
    private mutating func finishWordBeforeKey(_ key: String) -> Action? {
        guard cursor == userCursor, selection == 0, let (ri, gi) = openRegionIndex(), let span = spans[runs[ri].regions[gi].spanID],
              !span.parked, span.end == userCursor else { return nil }
        let desired = Array(desiredText(runs[ri].regions[gi], in: runs[ri]))
        let current = chars(of: span)
        guard desired.count > current.count, desired.starts(with: current), let last = current.last,
              last.isLetter || last.isNumber, let first = desired[current.count...].first, first.isLetter || first.isNumber else { return nil }
        let rest = String(desired[current.count...].prefix { !$0.isWhitespace })
        let spacer = (key.first.map { $0.isLetter || $0.isNumber } ?? false) ? " " : ""
        let spanID = runs[ri].regions[gi].spanID
        let action = send(.insert(rest + spacer + key), lane: .user) { q in
            q.insertAtCursor(Array(rest), owner: spanID)
            q.closeOpenRegions(.keystroke)
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
                closeOpenRegions(.edit)
                return .sent(send(.move(0), lane: lane, anywhere: true) { q in q.selection = 0 })
            }
            if state.edit.atCursor {
                state.spanID = addSpan(Span(start: userCursor, end: userCursor))
            } else if let found = placeThroughRead(state.edit) {
                // Through the changes since the read: the user's cancel it, the keyboard's own merge into the target.
                guard case .placed(let id, let target) = found else { drop(state, .userEdited); return .done }
                state.spanID = id; state.edit.target = target
                finishSpan(state.anchorID); state.anchorID = nil
                if state.edit.kind == .magic { closeOpenRegions(.edit) }
            } else {
                let placement = place(state.edit, anchor: state.anchorID)
                switch placement {
                case .placed(let id): state.spanID = id; finishSpan(state.anchorID); state.anchorID = nil
                case .ambiguous, .absent:
                    // The report may still catch up with a cursor move; past the grace the text is not there.
                    state.unplacedMs += stepElapsedMs
                    if lane == .edit, state.unplacedMs < Self.placeGraceMs { return .wait }
                    drop(state, placement == .ambiguous ? .unplaceable : .changed); return .done
                }
                if state.edit.kind == .magic { closeOpenRegions(.edit) }
            }
        }
        guard let id = state.spanID, let span = spans[id] else { drop(state, .changed); return .done }
        if span.userChanged { drop(state, .userEdited); return .done }
        if span.parked {
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

    /// Back to front, span by span (`SpanPlanner`): jump to the span's end, then either one delete of it and its new
    /// text typed, or each change in it (move, delete its old characters, type its new ones). Typed one grapheme per
    /// op when paced, else in one op. `minimal`: only the differing characters, never a whole word or a block (in a
    /// region the user edited, those would delete and retype the user's own characters).
    private func plan(spanID: Int, from current: [Character], to target: [Character], paced: Bool, leaveTailAppend: Bool = false,
                      minimal: Bool = false) -> [QOp] {
        guard spans[spanID] != nil else { return [] }
        func typed(_ text: [Character]) -> [QOp] {
            guard !text.isEmpty else { return [] }
            return paced ? text.map { .insert(String($0), owner: spanID) } : [.insert(String(text), owner: spanID)]
        }
        var ops: [QOp] = []
        // Growth at the end of the open region at the cursor is typed by the append path, not inside a unit.
        let groups: [[SpanPlanner.Hunk]] = minimal
            ? ShadowEditPlanner.diff(current, target).map { [SpanPlanner.Hunk(start: $0.start, end: $0.end, text: $0.text)] }
            : SpanPlanner.spans(from: current, to: target, leaveTailAppend: leaveTailAppend, paceMs: paced ? SpanPlanner.calmMs : 0,
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

    /// Deleting the model's `a..<b` leaves its line empty: a line break (or the known text's edge) on both sides.
    private func emptiesLine(_ a: Int, _ b: Int) -> Bool {
        b > a && (a == 0 || text[a - 1].isNewline) && (b == text.count || text[b].isNewline)
    }

    /// Typed graphemes still to come besides the unit's: the open region's append, and the queued edits' estimates.
    private func queuedBacklog() -> Int {
        var count = editLane.reduce(0) { $0 + $1.typedEstimate }
        for item in userLane { if case .edit(let state) = item { count += state.typedEstimate } }
        for run in runs {
            for region in run.regions where region.tEnd == nil && !region.abandoned {
                guard let span = spans[region.spanID], !span.parked else { continue }
                count += max(0, desiredText(region, in: run).count - (span.end - span.start))
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
                if target != cursor { return send(.move(units(to: target)), lane: lane(of: current.owner), moveTo: target) }
            case .moveToUser:
                current.ops.removeFirst(); unit = current
                if userCursor != cursor { return send(.move(units(to: userCursor)), lane: lane(of: current.owner), moveTo: userCursor) }
            case .moveToSpanEnd(let id):
                current.ops.removeFirst(); unit = current
                if let end = spans[id]?.end, end != cursor { return send(.move(units(to: end)), lane: lane(of: current.owner), moveTo: end) }
            case .setUserCursorToCursor:
                current.ops.removeFirst(); unit = current
                userCursor = cursor
            case .startRegion(let runID, let tStart, let anchor):
                current.ops.removeFirst(); unit = current
                if let ri = runs.firstIndex(where: { $0.runID == runID }) {
                    let id = addSpan(Span(start: userCursor, end: userCursor))
                    runs[ri].regions.append(Region(spanID: id, tStart: tStart, tEnd: nil, anchor: anchor))
                    events.append(.regionStarted(runID: runID, anchorChars: anchor.count))
                }
            case .delete(let count, let owner):
                guard cursor >= count, count > 0 else { unit = nil; requeue(current.owner); return .wait }
                current.ops.removeFirst(); unit = current
                return send(.deleteBackward(count), lane: lane(of: current.owner)) { q in q.removeRange(q.cursor - count, q.cursor, owner: owner) }
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

    private func lane(of owner: UnitOwner) -> Lane {
        switch owner {
        case .edit(_, let lane): lane
        case .region, .space: .live
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

    private func runNeedsWork(_ run: LiveRun) -> Bool {
        if run.pending != nil { return true }
        for region in run.regions where !region.abandoned {
            guard let span = spans[region.spanID], !span.parked, !span.edited else { continue }
            let desired = Array(desiredText(region, in: run)), current = chars(of: span)
            if span.userChanged {
                if let merged = merged(span, desired: desired), merged.text != current { return true }
            } else if current != desired { return true }
        }
        return untypedRest(of: run) != nil
    }

    /// Target text after the last region that still has to be typed (the start of a new region), if any.
    private func untypedRest(of run: LiveRun) -> Int? {
        guard runs.last?.runID == run.runID, !run.regions.contains(where: { $0.tEnd == nil }) else { return nil }
        let from = run.regions.compactMap(\.tEnd).max() ?? 0
        guard from < run.target.count, run.target[from...].contains(where: { !$0.isWhitespace }) else { return nil }
        return from
    }

    private mutating func nextLive() -> Action? {
        for ri in runs.indices { applyPending(ri) }
        for ri in runs.indices {
            // The open region first: appends at the cursor, then revisions of closed regions.
            let order = runs[ri].regions.indices.sorted { a, b in
                (runs[ri].regions[a].tEnd == nil ? 0 : 1, a) < (runs[ri].regions[b].tEnd == nil ? 0 : 1, b)
            }
            for gi in order {
                let region = runs[ri].regions[gi]
                guard let span = spans[region.spanID], !span.parked else { continue }
                let desired = Array(desiredText(region, in: runs[ri]))
                let current = chars(of: span)
                if region.abandoned || span.edited || (span.userChanged && span.cells == nil) {
                    runs[ri].regions[gi].abandoned = true
                    // Only a revision the region had not shown yet is lost; the user's own change is no drop. The region
                    // drops once, not once per version.
                    guard desired != region.landed else { continue }
                    runs[ri].regions[gi].landed = desired
                    guard !region.dropped else { continue }
                    runs[ri].regions[gi].dropped = true
                    events.append(.dropped(Drop(id: "\(runs[ri].runID)#\(gi)", runID: runs[ri].runID, kind: nil,
                                                reason: span.userChanged ? .userEdited : .changed,
                                                text: String(desired), partial: String(current))))
                    continue
                }
                if span.userChanged, let merged = merged(span, desired: desired) {
                    // The user edited the region: their words stay, the run's changes elsewhere in it still land.
                    if desired != region.landed, merged.dropped > 0 || merged.text == current {
                        runs[ri].regions[gi].landed = desired
                        if merged.dropped > 0, !region.dropped {
                            runs[ri].regions[gi].dropped = true
                            events.append(.dropped(Drop(id: "\(runs[ri].runID)#\(gi)", runID: runs[ri].runID, kind: nil, reason: .userEdited,
                                                        text: String(desired), partial: String(current))))
                        }
                    }
                    guard merged.text != current else { continue }
                    let paced = config.animated
                    unit = Unit(ops: plan(spanID: region.spanID, from: current, to: merged.text, paced: paced, minimal: true) + [.moveToUser],
                                owner: .region(run: runs[ri].runID), paced: paced)
                    return nextInUnit()
                }
                guard desired != current else { runs[ri].regions[gi].landed = desired; continue }
                if region.tEnd == nil, span.end == userCursor, cursor == userCursor, desired.starts(with: current) {
                    // Typewriter append at the cursor.
                    let remaining = desired.count - current.count
                    // One grapheme per op when animated, at the backlog's pace.
                    var count = remaining, credit = 0.0
                    if config.animated {
                        let pace = paceAllows(ops: queuedBacklog())
                        guard pace.go else { return .wait }
                        count = 1; credit = pace.credit
                    }
                    let slice = Array(desired[current.count..<(current.count + count)])
                    let spanID = region.spanID
                    let action = send(.insert(String(slice)), lane: .live) { q in
                        q.insertAtCursor(slice, owner: spanID)
                        q.userCursor = q.cursor
                    }
                    paceCreditMs = credit
                    return action
                }
                let paced = config.animated
                unit = Unit(ops: plan(spanID: region.spanID, from: current, to: desired, paced: paced,
                                     leaveTailAppend: region.tEnd == nil && span.end == userCursor) + [.moveToUser],
                            owner: .region(run: runs[ri].runID), paced: paced)
                return nextInUnit()
            }
            if let from = untypedRest(of: runs[ri]) {
                guard reportStableMs >= Self.stableMs || !config.animated else { return .wait }
                let anchor = String(text[max(0, userCursor - 200)..<userCursor])
                var ops: [QOp] = []
                if userCursor < text.count, !text[userCursor].isWhitespace, !Self.closingMarks.contains(text[userCursor]) {
                    // The run starts in front of text without a space: one goes in behind it, and the caret stays before it.
                    ops = [.insertBehind(" "), .moveToUser]
                }
                ops.append(.startRegion(run: runs[ri].runID, tStart: from, anchor: anchor))
                unit = Unit(ops: ops, owner: .space, paced: false)
                return nextInUnit()
            }
            ack(ri)
        }
        let newest = runs.last?.runID
        // A finished run stays while its cleanup may still come (it lands in the run's own text, never at the caret),
        // up to the last few runs. A retired run's later versions are ignored.
        let finished = runs.filter { $0.runID != newest && !runNeedsWork($0) && $0.ackedVersion == $0.version && $0.complete }
        let keptFrom = runs.count - Self.keptRuns
        let settled = finished.filter { run in run.cleaned || (runs.firstIndex { $0.runID == run.runID } ?? 0) < keptFrom }.map(\.runID)
        runs.removeAll { settled.contains($0.runID) }
        retiredRunIDs += settled
        if retiredRunIDs.count > 32 { retiredRunIDs.removeFirst(retiredRunIDs.count - 32) }
        return nil
    }

    private mutating func ack(_ ri: Int) {
        let run = runs[ri]
        guard let version = run.version, run.pending == nil, run.ackedVersion != version, !runNeedsWork(run), inFlight == nil else { return }
        runs[ri].ackedVersion = version
        events.append(.liveApplied(runID: run.runID, version: version, complete: run.complete))
    }

    private static let closingMarks: Set<Character> = [",", ".", ";", ":", "!", "?", ")", "]", "}", "%", "…", "\u{2019}", "\u{201D}"]

    /// The newest snapshot of a run becomes its target: region bounds move with the text diff.
    private mutating func applyPending(_ ri: Int) {
        guard let snapshot = runs[ri].pending else { return }
        if case .region(let r)? = unit?.owner, r == runs[ri].runID { return }
        runs[ri].pending = nil
        runs[ri].version = snapshot.version
        let wasComplete = runs[ri].complete
        runs[ri].complete = snapshot.complete
        runs[ri].cleaned = snapshot.complete && !snapshot.segments.isEmpty && snapshot.segments.allSatisfy { $0.final && $0.cleaned }
        let lastSegmentID = runs[ri].lastSegmentID
        runs[ri].lastSegmentID = max(lastSegmentID, snapshot.segments.map(\.id).max() ?? -1)
        let target = Array(Self.target(of: snapshot))
        let dropsAll = snapshot.complete && !snapshot.segments.isEmpty && snapshot.segments.allSatisfy { $0.final && $0.cleaned }
        guard !target.isEmpty || dropsAll else { return }
        let old = runs[ri].target
        guard old != target else { return }
        let hunks = ShadowEditPlanner.diff(old, target)
        // Text added at the end is new speech only while the take goes on and its words are raw: a cleanup or rewrite of
        // words already heard (punctuation, a trailing word) belongs to the region that ends the run, wherever the user is.
        let tail = snapshot.segments.last { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
        let rewritesTail = wasComplete || (tail.map { $0.cleaned && $0.id <= lastSegmentID } ?? false)
        let lastRegion = rewritesTail ? runs[ri].regions.lastIndex(where: { $0.tEnd == old.count && $0.tStart < old.count }) : nil
        func map(_ x: Int) -> Int {
            var shift = 0
            // Text inserted right at a boundary belongs to what follows it (a closed region keeps its words; growth
            // at the end goes to the open or the next region).
            for h in hunks {
                if h.end < x || (h.end == x && h.start < h.end) { shift += h.text.count - (h.end - h.start) }
                else if h.start < x { return h.start + shift + h.text.count }
                else { break }
            }
            return x + shift
        }
        for gi in runs[ri].regions.indices {
            runs[ri].regions[gi].tStart = min(target.count, map(runs[ri].regions[gi].tStart))
            if let end = runs[ri].regions[gi].tEnd {
                runs[ri].regions[gi].tEnd = gi == lastRegion ? target.count : max(runs[ri].regions[gi].tStart, min(target.count, map(end)))
            }
        }
        runs[ri].target = target
    }

    /// A snapshot's text: its segments, trimmed, joined by a space (none before a line break).
    static func target(of snapshot: LiveDictationSnapshot) -> String {
        var raw = ""
        for segment in snapshot.segments {
            let text = segment.text.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { continue }
            if let last = raw.last, !last.isWhitespace, let first = text.first, !first.isNewline { raw += " " }
            raw += text
        }
        return raw
    }

    private func desiredText(_ region: Region, in run: LiveRun) -> String {
        let end = min(run.target.count, region.tEnd ?? run.target.count)
        let start = min(region.tStart, end)
        return DictationTypist.prepare(String(run.target[start..<end]), contextBefore: region.anchor, capitalization: config.capitalization)
    }

    private func openRegionIndex() -> (Int, Int)? {
        guard let ri = runs.indices.last, let gi = runs[ri].regions.lastIndex(where: { $0.tEnd == nil }) else { return nil }
        return (ri, gi)
    }

    /// The user took over: open regions end at the end of the word typed so far (its rest lands as a revision).
    private mutating func closeOpenRegions(_ cause: CloseCause) {
        if case .region? = unit?.owner { unit = nil }
        for ri in runs.indices {
            applyPending(ri)
            guard let gi = runs[ri].regions.lastIndex(where: { $0.tEnd == nil }) else { continue }
            let region = runs[ri].regions[gi]
            let span = spans[region.spanID] ?? Span(start: 0, end: 0)
            let typed = span.end - span.start
            if typed == 0 {
                spans[region.spanID] = nil
                runs[ri].regions.remove(at: gi)
                continue
            }
            let run = runs[ri]
            let start = min(region.tStart, run.target.count)
            let slice = run.target[start...]
            let lead = slice.prefix { $0.isWhitespace }.count
            let prepared = Array(desiredText(region, in: run))
            let trimmed = String(slice.dropFirst(lead)).trimmingCharacters(in: .whitespaces)
            let separator = max(0, prepared.count - trimmed.count)
            // How much of the target the region shows: its text's end mapped into the target (growth past it is untyped;
            // a revision cut short, say after a block delete, still covers what it is rewriting).
            var covered = typed
            if !span.parked {
                let current = chars(of: span)
                var hunks = ShadowEditPlanner.diff(current, prepared)
                if let last = hunks.last, last.start == current.count, last.end == current.count { hunks.removeLast() }
                covered = current.count + hunks.reduce(0) { $0 + $1.text.count - ($1.end - $1.start) }
            }
            var end = min(run.target.count, start + lead + max(0, covered - separator))
            while end < run.target.count, !run.target[end].isWhitespace { end += 1 }
            runs[ri].regions[gi].tEnd = end
            events.append(.regionClosed(runID: run.runID, cause: cause))
        }
    }

    private mutating func dropRun(at ri: Int, reason: DropReason) {
        let run = runs[ri]
        for (gi, region) in run.regions.enumerated() where !region.abandoned {
            let desired = desiredText(region, in: run)
            guard let span = spans[region.spanID] else { continue }
            let current = String(chars(of: span))
            // A region that dropped already is not reported again.
            if desired != current, !region.dropped {
                events.append(.dropped(Drop(id: "\(run.runID)#\(gi)", runID: run.runID, kind: nil, reason: span.parked ? .unplaceable : reason,
                                            text: desired, partial: span.parked ? nil : current)))
            }
            spans[region.spanID] = nil
        }
        if let from = untypedRest(of: run) {
            events.append(.dropped(Drop(id: "\(run.runID)#rest", runID: run.runID, kind: nil, reason: reason,
                                        text: String(run.target[from...]).trimmingCharacters(in: .whitespaces), partial: nil)))
        }
    }

    // MARK: Sending

    private mutating func send(_ op: ShadowOp, lane: Lane, anywhere: Bool = false, moveTo: Int? = nil,
                               _ apply: (inout FieldQueue) -> Void = { _ in }) -> Action {
        let pre = ModelState(text: text, cursor: cursor, userCursor: userCursor, selection: selection, spans: spans)
        if let moveTo { cursor = moveTo } else { apply(&self) }
        var isMove = false
        if case .move = op { isMove = true }
        inFlight = InFlight(op: op, lane: lane, anywhere: anywhere, pre: pre, isMove: isMove, settleMs: anywhere ? Self.transitMs : isMove ? Self.moveSettleMs : 0)
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
        for (id, var span) in spans where !span.parked && span.start <= i && i <= span.end && span.end <= text.count {
            // Into the span: strictly inside, or anywhere in it for its owner (the same rule as the bounds below).
            guard (span.start < i && i < span.end) || id == owner else { continue }
            if owner == nil, span.cells == nil { span.cells = text[span.start..<span.end].map { .own($0) } }
            guard var cells = span.cells else { continue }
            let at = Self.cellIndex(i - span.start, in: cells)
            cells.insert(contentsOf: chars.map { owner == nil ? .user($0) : .own($0) }, at: at)
            span.cells = cells; spans[id] = span
        }
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
        for (id, var span) in spans where !span.parked && span.start < b && a < span.end && span.end <= text.count {
            if owner == nil, span.cells == nil { span.cells = text[span.start..<span.end].map { .own($0) } }
            guard let cells = span.cells else { continue }
            // The user's deletes of the keyboard's characters stay as deleted cells; anything else goes.
            let from = max(a, span.start) - span.start, to = min(b, span.end) - span.start
            var shown = 0
            span.cells = cells.compactMap { cell -> Cell? in
                guard let c = cell.shown else { return cell }
                defer { shown += 1 }
                guard shown >= from, shown < to else { return cell }
                if case .own = cell, owner == nil { return .gone(c) }
                return nil
            }
            spans[id] = span
        }
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
        // after the cursor fits, which says nothing about where the cursor is.
        let after = selected.count + report.after.count
        let inside = found.filter { after <= text.count - $0 }
        if found.count == 1, inside == found, fitsSelection(found[0], selected) {
            abortUnit()
            // Reports of the state before the user moved, still on their way, are lag from now on.
            lagging.append((ModelState(text: text, cursor: cursor, userCursor: userCursor, selection: selection, spans: spans), 0))
            if let flight { lagging.append((flight.pre, 0)) }
            cursor = found[0]; userCursor = cursor; selection = selected.count
            closeOpenRegions(selected.isEmpty ? .cursor : .selection)
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
            closeOpenRegions(.keystroke)
            events.append(.resync(.outsideInsert))
            return
        }
        // The text around the cursor changed: the report is the new model; spans are found again by their text.
        abortUnit()
        closeOpenRegions(.resync)
        for (id, var span) in spans where !span.parked {
            span.lastText = chars(of: span)
            if !span.lastText.isEmpty {
                span.lastBefore = Array(text[max(0, span.start - Self.contextChars)..<span.start])
                span.lastAfter = Array(text[span.end..<min(text.count, span.end + Self.contextChars)])
            }
            span.parked = true; spans[id] = span
        }
        let oldText = text, oldCursor = cursor, oldUser = userCursor
        seed(report)
        // The user's own op on its way (a pan, a key): the caret is where the user put it.
        if flight?.lane == .user { userLost = nil }
        // Already searching (the homing move's landing is unknown to the model): the search alone decides. A carry that
        // fails after the user acted at the caret (a selection appeared) leaves the caret as the user's.
        else if userLost == nil, !carryUserCursor(from: oldText, cursor: oldCursor, user: oldUser), !userActed {
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
            // it may be stale, it is what the model got wrong).
            userCursor = cursor; userLost = nil
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
              report.before.count + report.after.count >= Self.relocateChars || report.before.isEmpty || report.after.isEmpty else { return nil }
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
        abortUnit()
        lagging.append((ModelState(text: text, cursor: cursor, userCursor: userCursor, selection: selection, spans: spans), 0))
        if let flight { lagging.append((flight.pre, 0)) }
        cursor = at; userCursor = at; selection = 0
        closeOpenRegions(.cursor)
        quietAfterMove = true
        // The last ops may still be landing (they confirmed on the proxy's own echo, or one is in flight; reports after a
        // tap can show the time before it for a while): where the user tapped.
        if !recentSends.isEmpty { tapRace = (recentSends, 0) }
        events.append(.resync(.cursorMoved))
    }

    /// The last inserts that were on their way at the tap (one or several of one lane) show right before the tapped
    /// caret: they landed there, not where they were sent for. The model takes them there (and back out where they were
    /// meant to go). The user's own keys stay; the keyboard's own text comes out again (`strayChars`), and its region
    /// makes that change again where it belongs.
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
            if last.lane == .user { userCursor = cursor } else { userCursor = p; strayChars = key.count; strayLane = last.lane }
            tapRace = nil
            lagging = []
            return true
        }
        return false
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
        closeOpenRegions(.cursor)
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

    /// The host has an older state than the model: the model goes back to it. The live run's regions and placed edits
    /// are planned again from there (their lost characters are made again); the user's keys that were lost go once more.
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
            closeOpenRegions(.cursor)
        }
        // Regions begun and edits placed since that state have no span in it: they are planned afresh.
        for ri in runs.indices { runs[ri].regions.removeAll { spans[$0.spanID] == nil } }
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
