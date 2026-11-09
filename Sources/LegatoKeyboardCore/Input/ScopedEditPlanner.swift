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
        let shadow = edit.before + edit.after
        let plan = ShadowEditPlanner.plan(shadow: shadow, cursor: edit.before.utf16.count, target: edit.target, coarse: true)
        let before = String(decoding: Array(edit.target.utf16.prefix(plan.cursor)), as: UTF16.self)
        return .success(Plan(ops: plan.ops, cursor: plan.cursor, targetBefore: before))
    }

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
/// once the field's report shows the last one (`RunShadow.confirms`), so a host that reports late never gets an op at a
/// wrong offset. Pure: the keyboard feeds it the field's report and carries out the op it hands over.
///
/// An op the field does not confirm within `RunShadow.confirmLimitMs` (or a selection that appears or stays), or an edit
/// past `limitMs`, stops it: the rest is never sent. Where the field then shows what was expected after the last confirmed op, `Partial` is
/// the scope's text there (the scope itself when nothing landed), so the app can still undo; otherwise it is unknown.
public struct ScopedEditQueue: Sendable, Equatable {
    public enum Action: Sendable, Equatable {
        /// Carry out this op; the next step checks that the field shows it.
        case send(ShadowOp)
        /// The field has not confirmed the last op yet: step again on the next tick.
        case wait
        /// Every op went out and the field confirmed the last one.
        case done
        /// The field did not confirm in time; nothing more is sent. Nil: the field shows neither state.
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

    private let kept: String
    private let ops: [ShadowOp]
    private let states: [State]
    private var sent = 0
    private var confirmed = 0
    private var waitedMs = 0.0
    private var totalMs = 0.0
    private var stopped = false
    /// The whole edit's budget: past it no further op is sent (the app waits `LinkChannel.editLandTimeout` for the ack).
    public static let limitMs = 20_000.0
    /// Ops that had to wait for the field to confirm them.
    public private(set) var waits = 0

    /// `windowBefore`: the field's text before the cursor when the plan was made (the scope's `before` ends it).
    public init(_ edit: ScopedEdit, plan: ScopedEditPlanner.Plan, windowBefore: String) {
        ops = plan.ops
        if let selection = edit.selected {
            // The host replaces the selection with the insert (or deletes it); the cursor ends after the new text.
            kept = windowBefore
            states = [State(before: selection, after: "", selected: true), State(before: edit.target, after: "", selected: false)]
        } else {
            kept = String(windowBefore.dropLast(min(windowBefore.count, edit.before.count)))
            var text = edit.before + edit.after, cursor = edit.before.utf16.count
            var states = [State(before: edit.before, after: edit.after, selected: false)]
            for op in plan.ops {
                (text, cursor) = ShadowEditPlanner.simulate(ops: [op], shadow: text, cursor: cursor)
                let units = Array(text.utf16)
                states.append(State(before: String(decoding: units[..<cursor], as: UTF16.self),
                                    after: String(decoding: units[cursor...], as: UTF16.self), selected: false))
            }
            self.states = states
        }
    }

    /// The field's text before the cursor once the whole edit landed.
    public var expectedBefore: String { kept + (states.last?.before ?? "") }

    public mutating func step(reportedBefore: String, reportedAfter: String, hasSelection: Bool, elapsedMs: Double) -> Action {
        guard !stopped else { return .stopped(nil) }
        totalMs += elapsedMs
        if confirmed < sent {
            guard shows(states[sent], reportedBefore: reportedBefore, reportedAfter: reportedAfter, hasSelection: hasSelection) else {
                if waitedMs == 0 { waits += 1 }
                waitedMs += elapsedMs
                guard waitedMs >= RunShadow.confirmLimitMs else { return .wait }
                stopped = true
                // The op in flight may still land, or was lost: only a field that shows the last confirmed state is known.
                let last = states[confirmed]
                guard shows(last, reportedBefore: reportedBefore, reportedAfter: reportedAfter, hasSelection: hasSelection) else { return .stopped(nil) }
                return .stopped(Partial(text: last.before + last.after, cursor: last.selected ? 0 : last.before.utf16.count))
            }
            confirmed = sent; waitedMs = 0
        }
        guard sent < ops.count else { return .done }
        if totalMs >= Self.limitMs {
            stopped = true
            let last = states[confirmed]
            return .stopped(Partial(text: last.before + last.after, cursor: last.selected ? 0 : last.before.utf16.count))
        }
        sent += 1
        return .send(ops[sent - 1])
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
