import Foundation

/// Lands an instruction's `ScopedEdit` in the field: checks that the field still shows the scope the model was shown,
/// then diffs the target into it with the bundle 1 planner (`ShadowEditPlanner`, `coarse`: few ops, a slow host confirms
/// each one), back to front, the cursor returning to its logical place. Pure: the keyboard feeds it the windows and carries out the ops.
public enum ScopedEditPlanner {
    public struct Plan: Sendable, Equatable {
        public var ops: [ShadowOp]
        /// Cursor after the ops, in UTF-16 units into the target.
        public var cursor: Int
        /// The field's text before the cursor once the ops ran, as far as the scope covers it.
        public var targetBefore: String
    }

    public enum Refusal: Error, Sendable, Equatable {
        /// The windows around the cursor no longer agree with the scope (the user typed, moved or switched fields).
        case changed
        /// The scope was a selection, and it is not selected any more.
        case selectionChanged

        public var message: String {
            switch self {
            case .changed: "The text changed, so nothing was edited."
            case .selectionChanged: "The selection changed, so nothing was edited."
            }
        }
    }

    public static func plan(_ edit: ScopedEdit, windowBefore: String, windowAfter: String, selected: String?) -> Result<Plan, Refusal> {
        if let scope = edit.selected {
            // The host replaces a selection with the inserted text; the cursor ends after it.
            guard selected == scope else { return .failure(.selectionChanged) }
            return .success(Plan(ops: edit.target.isEmpty ? [.deleteBackward(1)] : [.insert(edit.target)],
                                 cursor: edit.target.utf16.count, targetBefore: edit.target))
        }
        guard selected?.isEmpty != false,
              agrees(scope: edit.before, window: windowBefore, atEnd: true),
              agrees(scope: edit.after, window: windowAfter, atEnd: false) else { return .failure(.changed) }
        if edit.after.isEmpty, let ops = lineRetype(edit.before, to: edit.target, limit: retypeChars) {
            // The cursor ends the scope and the first change is near it: delete back to it and type the rest. No moves,
            // so nothing a page can put back after its input events (a controlled text area moves its caret silently).
            return .success(Plan(ops: ops, cursor: edit.target.utf16.count, targetBefore: edit.target))
        }
        let shadow = edit.before + edit.after
        let plan = ShadowEditPlanner.plan(shadow: shadow, cursor: edit.before.utf16.count, target: edit.target, coarse: true)
        let before = String(decoding: Array(edit.target.utf16.prefix(plan.cursor)), as: UTF16.self)
        return .success(Plan(ops: plan.ops, cursor: plan.cursor, targetBefore: before))
    }

    /// `ShadowEditPlanner.retypeTail` within one line: the deleted part holds no line break. Deleting across one in a
    /// block-based host (Safari's `contenteditable`) can leave an empty block, which takes more deletes than characters
    /// and whose window shows nothing to confirm by.
    static func lineRetype(_ shadow: String, to target: String, limit: Int) -> [ShadowOp]? {
        guard let ops = ShadowEditPlanner.retypeTail(shadow: shadow, target: target, limit: limit) else { return nil }
        let deleted = ops.reduce(0) { if case .deleteBackward(let n) = $1 { return $0 + n }; return $0 }
        return shadow.suffix(deleted).contains(where: \.isNewline) ? nil : ops
    }

    /// An edit whose first change is at most this far back from the cursor (at the scope's end) is retyped from there;
    /// a smaller change further back goes by words, with moves.
    public static let retypeChars = 400

    /// A window (cut short by the host) and the scope agree where they overlap: next to the cursor. An empty window
    /// agrees only with an empty scope side: "nothing before the cursor" is not the end of any text.
    static func agrees(scope: String, window: String, atEnd: Bool) -> Bool {
        if scope.isEmpty { return true }
        if window.isEmpty { return false }
        if atEnd {
            // A block-based host's window may start with its boundary as "\n " (`FieldReader.trusted(before:)`).
            let trusted = FieldReader.trusted(before: window)
            return scope.hasSuffix(window) || window.hasSuffix(scope) || (!trusted.isEmpty && scope.hasSuffix(trusted))
        }
        return scope.hasPrefix(window) || window.hasPrefix(scope)
    }

    /// The undo of a landed edit: the text the edit produced (split where the cursor ended) goes back to what it replaced.
    public static func undo(of edit: ScopedEdit, cursor: Int, id: String = UUID().uuidString) -> ScopedEdit {
        let units = Array(edit.target.utf16)
        let split = min(max(0, cursor), units.count)
        return ScopedEdit(id: id, instructionID: edit.instructionID, documentID: edit.documentID,
                          before: String(decoding: units[..<split], as: UTF16.self),
                          after: String(decoding: units[split...], as: UTF16.self),
                          target: edit.scopeText)
    }
}

/// Carries out a `ScopedEditPlanner.Plan` like the live run's edit queue (`RunShadow`): one op in flight, the next only
/// once the field's report pins the cursor where the last one leaves it (`RunShadow.confirms`, strict: at that place and
/// no other), so a host that reports late never gets an op at a wrong offset. Pure: the keyboard feeds it the field's
/// report and carries out the op it hands over.
///
/// A page that puts its caret back after a move (a re-rendered, controlled text area) is met like in the live run: a
/// field known to do so (`avoidsMoves`), or a move whose old place the report keeps pinning (`RunShadow.caretResetReports`
/// over `caretResetMs`), turns the rest of the edit into a retype at the cursor (`ShadowEditPlanner.retypeTail`: delete
/// back to the first change, type the new text; no moves). That needs the text after the cursor to stay as it is and at
/// most `RunShadow.cleanupRetypeChars` deleted; otherwise the edit stops, as it does when an op does not confirm within
/// `RunShadow.confirmLimitMs` (or a selection appears or stays), or past `limitMs`: the rest is never sent. Where the
/// field then shows a known state, `Partial` is the scope's text there (the scope itself when nothing landed), so the
/// app can still undo; otherwise it is unknown.
public struct ScopedEditQueue: Sendable, Equatable {
    public enum Action: Sendable, Equatable {
        /// Carry out this op; the next step checks that the field shows it.
        case send(ShadowOp)
        /// The field has not confirmed the last op yet: step again on the next tick.
        case wait
        /// Every op went out and the field confirmed the last one.
        case done
        /// The field did not confirm in time, or the edit needs moves the field undoes; nothing more is sent. Nil: the
        /// field shows no known state.
        case stopped(Partial?)
    }

    /// The scope's text as the field shows it where the edit stopped, and the cursor in it (UTF-16).
    public struct Partial: Sendable, Equatable {
        public var text: String
        public var cursor: Int
    }

    /// The scope around the cursor before any op and after each one. `selected`: the scope is still selected (`before`
    /// is the selection then, and the field's text before the cursor ends before it).
    struct State: Sendable, Equatable {
        var before: String
        var after: String
        var selected: Bool
    }

    /// The field's text before the scope, as far as it was shown. Grows when a report shows more (the scope was longer
    /// than the host's window), so the cursor can be pinned once little of the scope is left before it.
    private var kept: String
    private let movesByCharacters: Bool
    private let target: String
    private var ops: [ShadowOp]
    private var states: [State]
    private var sent = 0
    private var confirmed = 0
    private var waitedMs = 0.0
    private var totalMs = 0.0
    private var stopped = false
    private var resetReport: String?
    private var resetReports = 0
    private var resetMs = 0.0
    private var started = false
    private var observedMs: Double?
    /// The whole edit's budget: past it no further op is sent (the app waits `LinkChannel.editLandTimeout` for the ack).
    public static let limitMs = 20_000.0
    /// Ops that had to wait for the field to confirm them.
    public private(set) var waits = 0
    /// The field put its caret back after a move (seen during this edit): the keyboard should avoid moves from now on.
    public private(set) var caretReset = false
    /// The edit lands (or landed) by retyping at the cursor, without moves.
    public private(set) var retypes = false
    /// The edit needs moves the field does not keep, and retyping cannot stand in: nothing was sent.
    public private(set) var needsMoves = false
    /// The field did not show the text the plan was made for before the first op: nothing was sent.
    public private(set) var textChanged = false

    /// `windowBefore`: the field's text before the cursor when the plan was made (the scope's `before` ends it).
    /// `avoidsMoves`: the field is known to put its caret back after a move.
    /// `keptBefore`: the field's text before the scope, read for this edit (the scope reaches past the host's window).
    /// `movesByCharacters`: the field moves one unit per character (an emoji is one, not two; `FieldReader`).
    public init(_ edit: ScopedEdit, plan: ScopedEditPlanner.Plan, windowBefore: String, avoidsMoves: Bool = false, keptBefore: String? = nil,
                movesByCharacters: Bool = false) {
        target = edit.target
        self.movesByCharacters = movesByCharacters
        if let selection = edit.selected {
            // The host replaces the selection with the insert (or deletes it); the cursor ends after the new text.
            kept = windowBefore
            ops = plan.ops
            states = [State(before: selection, after: "", selected: true), State(before: edit.target, after: "", selected: false)]
            return
        }
        kept = keptBefore ?? String(windowBefore.dropLast(min(windowBefore.count, edit.before.count)))
        let start = State(before: edit.before, after: edit.after, selected: false)
        ops = []; states = [start]
        if avoidsMoves, plan.ops.contains(where: { if case .move = $0 { true } else { false } }) {
            guard let retype = Self.retype(from: start, to: edit.target) else { needsMoves = true; stopped = true; return }
            retypes = true
            replan(from: start, ops: retype)
        } else {
            replan(from: start, ops: plan.ops)
        }
    }

    /// Ops that bring `state` to `target` by deleting back from the cursor and typing, with the text after the cursor
    /// kept; nil when that text changes or the deletion is too long.
    static func retype(from state: State, to target: String) -> [ShadowOp]? {
        guard target.hasSuffix(state.after) else { return nil }
        let newBefore = String(target.dropLast(state.after.count))
        if newBefore == state.before { return [] }
        return ScopedEditPlanner.lineRetype(state.before, to: newBefore, limit: RunShadow.cleanupRetypeChars)
    }

    private mutating func replan(from state: State, ops: [ShadowOp]) {
        self.ops = ops; sent = 0; confirmed = 0; waitedMs = 0; observedMs = nil
        var text = state.before + state.after, cursor = state.before.utf16.count
        states = [state]
        for op in ops {
            (text, cursor) = ShadowEditPlanner.simulate(ops: [op], shadow: text, cursor: cursor)
            let units = Array(text.utf16)
            states.append(State(before: String(decoding: units[..<cursor], as: UTF16.self),
                                after: String(decoding: units[cursor...], as: UTF16.self), selected: false))
        }
    }

    /// The last operation's prediction, kept separate from host observations by the shared coordinator.
    public var predictedWindow: (before: String, after: String, selected: Bool) {
        let state = states[min(sent, states.count - 1)]
        return (kept + (state.selected ? "" : state.before), state.after, state.selected)
    }
    /// A matching old window cannot prove an emitted operation was dropped rather than delayed.
    public var hasUnconfirmedOperation: Bool { confirmed < sent }

    /// The field's text before the cursor once the whole edit landed.
    public var expectedBefore: String { kept + (states.last?.before ?? "") }
    /// Where the cursor ends, in UTF-16 units into the target (the undo splits the target there).
    public var finalCursor: Int { states.last.map { $0.selected ? target.utf16.count : $0.before.utf16.count } ?? 0 }

    public mutating func step(reportedBefore: String, reportedAfter: String, hasSelection: Bool, elapsedMs: Double) -> Action {
        guard !stopped else { return .stopped(needsMoves || textChanged ? partial(states[0]) : nil) }
        totalMs += elapsedMs
        if !started {
            // Nothing goes out before the field pins the cursor in the text the plan was made for: text typed or changed
            // since the read (another keyboard, a paste) refuses the edit untouched.
            guard shows(states[0], reportedBefore: reportedBefore, reportedAfter: reportedAfter, hasSelection: hasSelection) else {
                waitedMs += elapsedMs
                guard waitedMs >= RunShadow.confirmLimitMs else { return .wait }
                stopped = true; textChanged = true
                return .stopped(partial(states[0]))
            }
            started = true; waitedMs = 0
        }
        if confirmed < sent {
            guard shows(states[sent], reportedBefore: reportedBefore, reportedAfter: reportedAfter, hasSelection: hasSelection) else {
                observedMs = nil
                if waitedMs == 0 { waits += 1 }
                waitedMs += elapsedMs
                let before = states[sent - 1]
                if case .move = ops[sent - 1], shows(before, reportedBefore: reportedBefore, reportedAfter: reportedAfter, hasSelection: hasSelection) {
                    // The report keeps the cursor where it was before the move: lagging for a moment, or a page that put
                    // its caret back. Held steady, it is the page: the rest goes in by retyping at the cursor.
                    let report = reportedBefore + "\u{0}" + reportedAfter
                    if report == resetReport { resetReports += 1; resetMs += elapsedMs } else { resetReport = report; resetReports = 1; resetMs = 0 }
                    if resetReports >= RunShadow.caretResetReports, resetMs >= RunShadow.caretResetMs {
                        caretReset = true; resetReport = nil; resetReports = 0; resetMs = 0
                        guard let retype = Self.retype(from: before, to: target) else { stopped = true; return .stopped(partial(before)) }
                        retypes = true
                        replan(from: before, ops: retype)
                        return next(reportedBefore: reportedBefore)
                    }
                } else {
                    resetReport = nil; resetReports = 0; resetMs = 0
                }
                guard waitedMs >= RunShadow.confirmLimitMs else { return .wait }
                stopped = true
                // Even a report matching the old state cannot prove the emitted operation will not land later.
                return .stopped(nil)
            }
            // An immediate echo can precede a controlled editor's asynchronous caret reset or text rollback.
            // Require the expected position/text to survive a later host turn before another destructive operation.
            observedMs = observedMs.map { $0 + elapsedMs } ?? 0
            if (observedMs ?? 0) < RunShadow.moveVerifyMs { return .wait }
            confirmed = sent; waitedMs = 0; observedMs = nil; resetReport = nil; resetReports = 0; resetMs = 0
            learnKept(from: reportedBefore, at: states[sent])
        }
        if sent < ops.count, totalMs >= Self.limitMs {
            stopped = true
            return .stopped(partial(states[confirmed]))
        }
        return next(reportedBefore: reportedBefore)
    }

    /// A confirmed report that reaches back past the known text shows the text before the scope: it is kept.
    private mutating func learnKept(from reportedBefore: String, at state: State) {
        guard !state.selected, kept.count < Self.keptWanted else { return }
        let shown = String(FieldReader.trusted(before: reportedBefore))
        let known = kept + state.before
        guard shown.count > known.count, shown.hasSuffix(known) else { return }
        kept = String(shown.dropLast(state.before.count))
    }
    static let keptWanted = 40

    /// The next op. A delete never takes more than the field's report (the field pins the cursor in the known text, so
    /// the report is that text) shows before the cursor: a longer one goes in parts, each shown first. Text the report did
    /// not show is never deleted; where it differs, the next part does not confirm and the edit stops.
    private mutating func next(reportedBefore: String) -> Action {
        guard sent < ops.count else { return .done }
        if case .deleteBackward(let count) = ops[sent], !states[sent].selected {
            // Never across a block's boundary: a window that starts at its block ("\n ") shows the block, not the break.
            let shown = FieldReader.trusted(before: reportedBefore).count
            guard shown > 0 else { stopped = true; return .stopped(partial(states[sent])) }
            var part = min(count, shown)
            // With little known before the scope, a delete stops while enough of the scope is left before the cursor to
            // pin it by (`RunShadow.reverseMatchChars`); the report there shows the text before the scope, which is kept.
            let left = states[sent].before.count - part, floor = RunShadow.reverseMatchChars
            if kept.count < floor, left < floor, states[sent].before.count - floor > 0, part > states[sent].before.count - floor { part = states[sent].before.count - floor }
            if part < count {
                let rest = Array(ops[(sent + 1)...])
                replan(from: states[sent], ops: [.deleteBackward(part), .deleteBackward(count - part)] + rest)
            }
        }
        sent += 1
        if movesByCharacters, case .move = ops[sent - 1], !states[sent - 1].selected {
            // The plan counts UTF-16 units; this field counts characters.
            return .send(.move(states[sent].before.count - states[sent - 1].before.count))
        }
        return .send(ops[sent - 1])
    }

    private func partial(_ state: State) -> Partial {
        Partial(text: state.before + state.after, cursor: state.selected ? 0 : state.before.utf16.count)
    }

    private func shows(_ state: State, reportedBefore: String, reportedAfter: String, hasSelection: Bool) -> Bool {
        guard state.selected == hasSelection else { return false }
        return RunShadow.confirms(expectedBefore: kept + (state.selected ? "" : state.before), expectedAfter: state.after,
                                  reportedBefore: reportedBefore, reportedAfter: reportedAfter)
    }
}

/// The text Legato typed in this keyboard appearance that still ends at the cursor: the instruction scope `session`.
/// Live runs extend it; an instruction's edit rewrites it; anything the user does at the cursor (a key, a move, a
/// selection, another field) ends it.
public struct SessionSpan: Sendable, Equatable {
    /// Ends at the cursor; empty when no session text is known.
    public private(set) var text = ""
    /// The text begins at the field's start (the first run started in an empty field).
    public private(set) var startsField = false
    /// What stood before the current run's region.
    private var base = ""
    private var region = ""
    private var runID: String?
    /// The next region continues the session (after an instruction's edit) instead of starting a new one.
    private var contiguous = false

    public init() {}

    /// A live run's region after a step: `anchor` is what the field held before it when it began.
    public mutating func track(runID: String, anchor: String, region: String) {
        if region.isEmpty { self.region = ""; return }
        if self.region.isEmpty || runID != self.runID {
            // A region begins: it continues the session only when nothing broke it since, and the field before it still
            // ends with the session text (the host may have changed the field without the keyboard, e.g. emptied it).
            let continues = contiguous && !text.isEmpty && OwnEditEcho.isSame(expected: text, reported: anchor)
            base = continues ? text : ""
            if !continues { startsField = anchor.isEmpty }
            contiguous = true
        }
        self.runID = runID; self.region = region
        text = base + region
    }

    /// The user took over at the cursor (a key, a move, a selection, another field): the session text is gone.
    public mutating func broken() { self = SessionSpan() }

    /// Legato edited the text before the cursor: the last `before.count` characters became `newBefore`. A region that
    /// was open is closed (the live run was frozen for the edit); the next region continues from the edited text.
    public mutating func edited(before: String, newBefore: String) {
        if before.count >= text.count {
            // The edit covered the whole session text: its result is Legato's text now.
            if before.count > text.count { startsField = false }
            text = newBefore
        } else {
            text = String(text.dropLast(before.count)) + newBefore
        }
        base = text; region = ""; contiguous = true
    }
}
