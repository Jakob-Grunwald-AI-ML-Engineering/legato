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
///   short by a key is finished first); later words start a new region at the user's cursor. Revisions of closed
///   regions still land as jump units while their text is unchanged.
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
        /// Inserts go one grapheme per tick (`charMs`) when animating.
        public var paced: Bool
        public init(id: String = UUID().uuidString, kind: Kind, before: String = "", after: String = "", selected: String? = nil,
                    target: String, atCursor: Bool = false, cursorAtEnd: Bool = true, paced: Bool = false) {
            self.id = id; self.kind = kind; self.before = before; self.after = after
            self.selected = selected?.isEmpty == true ? nil : selected
            self.target = target; self.atCursor = atCursor; self.cursorAtEnd = cursorAtEnd; self.paced = paced
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
    /// How long user input waits behind the op in flight.
    public static let userBoundMs = 150.0
    /// A new region starts only once the report held still this long.
    public static let stableMs = 150.0
    /// The typewriter pace of paced inserts.
    public static let charMs = 30.0
    /// Measured on Safari (no field puts its caret back after a move): the proxy reports a move at once, before the
    /// host applied it (25–50 ms later), and the host can apply ops sent close together out of order. So a move is
    /// confirmed only by a report at least `moveSettleMs` after it, and no op follows the last one sooner than
    /// `sendGapMs`. An edit the proxy has not reported after `nudgeAfterMs` gets a zero-offset move (its report can
    /// stay stale until a move).
    public static let moveSettleMs = 80.0
    public static let sendGapMs = 50.0
    public static let nudgeAfterMs = 250.0
    /// An op whose result the report cannot tell from the state before it (a delete with nothing known before the
    /// cursor, a collapsing move) is taken as landed only after the host's longest measured transit.
    public static let transitMs = 150.0
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
    }
    struct LiveRun: Sendable, Equatable {
        var runID: String
        var version: Int?
        var complete = false
        var pending: LiveDictationSnapshot?
        var target: [Character] = []
        var regions: [Region] = []
        var ackedVersion: Int?
    }
    private(set) var runs: [LiveRun] = []

    private enum QOp: Sendable, Equatable {
        /// To this offset into a span (resolved when sent: the model may have grown in front of it meanwhile).
        case moveInSpan(Int, offset: Int)
        case moveToUser
        case moveToSpanEnd(Int)
        case delete(owner: Int?)
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

    public init(config: Config = Config()) { self.config = config }

    // MARK: Inspection

    public var isIdle: Bool {
        inFlight == nil && unit == nil && userLane.isEmpty && editLane.isEmpty && !runs.contains(where: { runNeedsWork($0) })
    }
    public var hasUserInput: Bool { !userLane.isEmpty }
    public var hasOpInFlight: Bool { inFlight != nil }
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

    /// The queue's state in one line, for traces and the edit journal.
    public var debugState: String {
        var parts = ["user=\(userLane.count)", "edits=\(editLane.count)", "unit=\(unit.map { "\($0.ops.count)" } ?? "-")",
                     "flight=\(inFlight != nil)", "sel=\(selection)"]
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
    }

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
        lagging = lagging.filter { $0.ageMs + elapsedMs < Self.confirmLimitMs }.map { ($0.state, $0.ageMs + elapsedMs) }
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

        if var flight = inFlight {
            // The proxy shows a move at once, before the host applied it: only a report after the settle gap counts.
            let settled = sinceSendMs >= flight.settleMs
            // A report that fits the state before the op as well proves nothing (the op may still be on its way), and
            // neither does one that shows a state the host lags behind.
            if settled, matches(report, anywhere: flight.anywhere), flight.anywhere || !pins(report, in: flight.pre),
               !lagging.contains(where: { pins(report, in: $0.state) }) {
                if flight.anywhere { relocate(report) }
                events.append(.confirmed(waitedMs: flight.waitedMs))
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
                let pinsPre = pins(report, in: flight.pre)
                if !flight.nudged, !flight.isMove, flight.waitedMs >= Self.nudgeAfterMs, selection == 0, report.selected == nil {
                    // An edit the proxy has not reported yet (it can stay on its last report): a zero-offset move makes
                    // it report the field afresh. It moves nothing, so it cannot land out of order.
                    flight.nudged = true; flight.settleMs = Self.moveSettleMs
                    inFlight = flight
                    sinceSendMs = 0
                    events.append(.nudged)
                    return .send(.move(0))
                }
                if !userLane.isEmpty, flight.waitedMs >= Self.userBoundMs, pinsPre {
                    // The host lags: the op counts as landed so the user's input can go.
                    inFlight = nil
                    lagging.append((flight.pre, 0))
                    events.append(.resync(.assumed))
                } else if flight.waitedMs < Self.confirmLimitMs, lagging.contains(where: { pins(report, in: $0.state) }) {
                    inFlight = flight
                    return .wait
                } else if flight.waitedMs >= Self.confirmLimitMs
                            || (!pinsPre && flight.waitedMs >= Self.userBoundMs && reportStableMs >= Self.userBoundMs / 2)
                            || (!userLane.isEmpty && flight.waitedMs >= 2 * Self.userBoundMs) {
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
            resync(report, pre: nil)
        } else if reportStableMs == 0 {
            merge(report)
        }
        return next()
    }

    // MARK: Choosing the next op

    private mutating func next() -> Action {
        // Ops sent close together can land out of order: the next waits for the gap.
        if sinceSendMs < Self.sendGapMs {
            if inFlight == nil { for ri in runs.indices { ack(ri) } }
            return .wait
        }
        // User input first; a running unit gives the caret back first.
        if !userLane.isEmpty {
            abortUnit()
            if cursor != userCursor, selection == 0 { return send(.move(units(to: userCursor)), lane: .user, moveTo: userCursor) }
            if let action = nextUser() { return action }
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

    /// Back to front: move to each change, delete its old characters, insert its new ones.
    private func plan(spanID: Int, from current: [Character], to target: [Character], paced: Bool, leaveTailAppend: Bool = false) -> [QOp] {
        guard spans[spanID] != nil else { return [] }
        var ops: [QOp] = []
        var hunks = ShadowEditPlanner.diff(current, target)
        // Growth at the end of the open region at the cursor is typed by the append path (the typewriter drain), not
        // one grapheme per op inside a unit.
        if leaveTailAppend, let last = hunks.last, last.start == current.count, last.end == current.count { hunks.removeLast() }
        for hunk in hunks.reversed() {
            ops.append(.moveInSpan(spanID, offset: hunk.end))
            ops += Array(repeating: .delete(owner: spanID), count: hunk.end - hunk.start)
            if !hunk.text.isEmpty {
                if paced { ops += hunk.text.map { .insert(String($0), owner: spanID) } }
                else { ops.append(.insert(String(hunk.text), owner: spanID)) }
            }
        }
        return ops
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
            case .delete(let owner):
                guard cursor > 0 else { unit = nil; requeue(current.owner); return .wait }
                current.ops.removeFirst(); unit = current
                return send(.deleteBackward(1), lane: lane(of: current.owner)) { q in q.removeRange(q.cursor - 1, q.cursor, owner: owner) }
            case .insert(let chars, let owner):
                if current.paced, sinceSendMs < Self.charMs { return .wait }
                current.ops.removeFirst(); unit = current
                return send(.insert(chars), lane: lane(of: current.owner)) { q in q.insertAtCursor(Array(chars), owner: owner) }
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
            guard let span = spans[region.spanID], !span.parked, !span.userChanged, !span.edited else { continue }
            if chars(of: span) != Array(desiredText(region, in: run)) { return true }
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
                if region.abandoned || span.userChanged || span.edited {
                    runs[ri].regions[gi].abandoned = true
                    // Only a revision the region had not shown yet is lost (once each); the user's own change is no drop.
                    guard desired != region.landed else { continue }
                    runs[ri].regions[gi].landed = desired
                    events.append(.dropped(Drop(id: "\(runs[ri].runID)#\(gi)", runID: runs[ri].runID, kind: nil,
                                                reason: span.userChanged ? .userEdited : .changed,
                                                text: String(desired), partial: String(current))))
                    continue
                }
                guard desired != current else { runs[ri].regions[gi].landed = desired; continue }
                if region.tEnd == nil, span.end == userCursor, cursor == userCursor, desired.starts(with: current) {
                    // Typewriter append at the cursor.
                    let remaining = desired.count - current.count
                    var count = remaining
                    if config.animated {
                        guard sinceSendMs >= Self.charMs else { return .wait }
                        count = TypewriterDrain.step(revealed: 0, target: remaining, dtMs: min(sinceSendMs, 2 * Self.charMs))
                    }
                    let slice = Array(desired[current.count..<(current.count + count)])
                    let spanID = region.spanID
                    return send(.insert(String(slice)), lane: .live) { q in
                        q.insertAtCursor(slice, owner: spanID)
                        q.userCursor = q.cursor
                    }
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
        let settled = runs.filter { $0.runID != newest && !runNeedsWork($0) && $0.ackedVersion == $0.version && $0.complete }.map(\.runID)
        runs.removeAll { settled.contains($0.runID) }
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
        runs[ri].complete = snapshot.complete
        let target = Array(Self.target(of: snapshot))
        let dropsAll = snapshot.complete && !snapshot.segments.isEmpty && snapshot.segments.allSatisfy { $0.final && $0.cleaned }
        guard !target.isEmpty || dropsAll else { return }
        let old = runs[ri].target
        guard old != target else { return }
        let hunks = ShadowEditPlanner.diff(old, target)
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
            if let end = runs[ri].regions[gi].tEnd { runs[ri].regions[gi].tEnd = max(runs[ri].regions[gi].tStart, min(target.count, map(end))) }
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
            var end = min(run.target.count, start + lead + max(0, typed - separator))
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
            if desired != current {
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
        sinceSendMs = 0
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
        text = state.text; cursor = state.cursor; userCursor = state.userCursor; selection = state.selection; spans = state.spans
    }

    /// The report does not show what the model expects: find out what happened and go on from there.
    private mutating func resync(_ report: Report, pre flight: InFlight?) {
        let selected = report.selected ?? ""
        let found = FieldMatch.positions(in: text, reportedBefore: report.before, reportedAfter: selected + report.after)
        if found.contains(cursor), selected.count == selection {
            if found.count > 1 { events.append(.resync(.ambiguous)) }
            return
        }
        if let flight, pins(report, in: flight.pre) {
            restore(flight.pre)
            abortUnit()
            events.append(.resync(.opLost))
            // A user's key or delete the host lost goes once more.
            if let input = flight.input, !flight.retried {
                if case .move = input {} else { userLane.insert(.input(input, retried: true), at: 0) }
            }
            return
        }
        if found.count == 1, fitsSelection(found[0], selected) {
            abortUnit()
            cursor = found[0]; userCursor = cursor; selection = selected.count
            closeOpenRegions(selected.isEmpty ? .cursor : .selection)
            events.append(.resync(.cursorMoved))
            merge(report)
            return
        }
        if found.count > 1 {
            events.append(.resync(.ambiguous))
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
        carryUserCursor(from: oldText, cursor: oldCursor, user: oldUser)
        events.append(.resync(.reseeded))
        unparkSpans()
    }

    /// A resync while a unit had the caret away from the user: the user's cursor keeps its distance from the caret when
    /// the text between them agrees with the new model as far as the model shows it (the rest comes from the old model).
    private mutating func carryUserCursor(from old: [Character], cursor oldCursor: Int, user oldUser: Int) {
        let d = oldUser - oldCursor
        guard d != 0 else { return }
        if d > 0 {
            let segment = old[oldCursor..<oldUser]
            let known = min(d, text.count - cursor)
            guard known == d || known >= Self.contextChars, text[cursor..<(cursor + known)].elementsEqual(segment.prefix(known)) else { return }
            if known < d { text += segment.suffix(d - known) }
            userCursor = cursor + d
        } else {
            let segment = old[oldUser..<oldCursor]
            let known = min(-d, cursor)
            guard known == -d || known >= Self.contextChars, text[(cursor - known)..<cursor].elementsEqual(segment.suffix(known)) else { return }
            if known < -d { prepend(Array(segment.prefix(-d - known))) }
            userCursor = cursor + d
        }
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

    private enum Placement: Equatable { case placed(Int), ambiguous, absent }

    /// Where an edit's scope is in the model: at the user's cursor (the model may grow by the scope's text beyond what
    /// it knows), else at its one occurrence in the model.
    private mutating func place(_ edit: Edit, anchor: Int? = nil) -> Placement {
        let before = Array(edit.before), after = Array(edit.after)
        func fitsWithGrowth(_ p: Int) -> (front: Int, back: Int)? {
            guard p >= 0, p <= text.count else { return nil }
            let k = min(p, before.count)
            guard text[(p - k)..<p].elementsEqual(before[(before.count - k)...]), k == before.count || p - k == 0 else { return nil }
            let m = min(text.count - p, after.count)
            guard text[p..<(p + m)].elementsEqual(after[..<m]), m == after.count || p + m == text.count else { return nil }
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
