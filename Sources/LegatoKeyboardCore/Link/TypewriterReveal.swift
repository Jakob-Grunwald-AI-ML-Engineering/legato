import Foundation

/// Reveals host text one character at a time. Revisions and final cleanup preserve surviving characters
/// through the same verified edit queue as magic. A host update received during an edit waits until its
/// operations confirm; only then is its applied cursor acknowledged. A failed transaction stops that run
/// without issuing further mutations. Context and document identity protect user edits and field changes.
public struct TypewriterReveal: Sendable, Equatable {
    /// How long a tick waits for the field's context to show the tentative text before giving up.
    public static let settleLimitMs = 250.0

    /// More ticks are needed: text is left to reveal, or a tick is waiting for the context.
    public private(set) var needsTicks = false

    private struct Pending: Sendable, Equatable {
        var queue: ScopedEditQueue
        var cursor: AppliedCursor?
        var runID: String?
        var documentID: String
        var appendOnly: Bool
    }
    private var pending: Pending?
    private var stoppedRun: String?
    private var movesByCharacters = false
    private var runID: String?
    private var text = ""
    private var revealed = 0
    private var waitedMs = 0.0
    /// The cursor's `sentCount` last seen: a new sent boundary empties the field of the run.
    private var sentCount = 0

    public init() {}

    /// A host Send is evidence that even an unacknowledged appended character left with the message.
    /// This cursor is only for clear detection; it never confirms a partially applied rewrite.
    public func cursorBeforeFieldClear(fallback: AppliedCursor?) -> AppliedCursor? {
        guard let pending, pending.appendOnly,
              pending.queue.predictedWindow.before == pending.queue.expectedBefore else { return fallback }
        var sent = pending.cursor
        sent?.finalApplied = false
        return sent
    }

    /// The edits that bring the field closer to `state`. `elapsedMs` is the time since the last tick (0 for
    /// a host update: it follows the new text but reveals nothing more); `animated` false (Reduce Motion,
    /// or a flush) reveals everything now.
    public mutating func plan(
        state: HostState, cursor: AppliedCursor?, contextBefore: String, documentID: String?, animated: Bool,
        elapsedMs: Double = 0, contextAfter: String = "", hasSelection: Bool = false, movesByCharacters: Bool = false
    ) -> ProxyPlan {
        self.movesByCharacters = movesByCharacters
        needsTicks = false
        if hasSelection {
            pending = nil; stoppedRun = state.runID
            var failed = cursor; failed?.finalApplied = false
            return ProxyPlan(ops: [], cursor: failed)
        }
        if let stoppedRun, stoppedRun == state.runID { return ProxyPlan(ops: [], cursor: cursor) }
        if let transaction = pending {
            guard transaction.runID == state.runID, transaction.documentID == documentID else {
                pending = nil
                return ProxyPlan(ops: [], cursor: cursor)
            }
            if state.delivery == .live, let cursor, cursor.runID == transaction.runID,
               cursor.sentCount != (transaction.cursor?.sentCount ?? 0) {
                // The host sent the currently shown text; no queued mutation of that text may follow it.
                pending = nil
            } else {
                return advance(state: state, cursor: cursor, contextBefore: contextBefore, contextAfter: contextAfter, elapsedMs: elapsedMs)
            }
        }
        guard let documentID, state.target == .keyboard, let runID = state.runID, state.delivery != .hold,
              cursor == nil || cursor?.runID != runID || cursor?.documentID == documentID
        else {
            let plan = ProxyEditPlanner.plan(state: state, cursor: cursor, contextBefore: contextBefore, documentID: documentID)
            return play(plan, state: state, cursor: cursor, contextBefore: contextBefore, contextAfter: contextAfter,
                        documentID: documentID, elapsedMs: elapsedMs)
        }

        let target = state.committed + state.volatile
        let total = target.count
        if runID != self.runID {
            self.runID = runID
            waitedMs = 0
            sentCount = cursor?.runID == runID ? cursor?.sentCount ?? 0 : 0
            if let cursor, cursor.runID == runID {
                revealed = min(total, cursor.committedCount + cursor.volatile.count)
            } else {
                revealed = 0
            }
        } else if !TypewriterDrain.isPrefixGrowth(prev: String(text.prefix(revealed)), next: target) {
            revealed = total
        }
        text = target

        // `.live` after a sent boundary: the field shows the run only from the boundary on, and tentative text
        // sent with the message holds everything back until the committed text shows where it ends. This is
        // decided on the host's whole state, never on the revealed part of it.
        var cursor = cursor
        if state.delivery == .live, var sent = cursor, sent.runID == runID {
            if sent.sentCount != sentCount {
                sentCount = sent.sentCount
                revealed = min(total, sent.committedCount + sent.volatile.count)
            }
            if ProxyEditPlanner.awaitsSentTentative(state: state, cursor: &sent) {
                revealed = min(total, sent.committedCount)
                return ProxyPlan(ops: [], cursor: sent)
            }
            revealed = max(revealed, min(total, sent.sentBase))
            cursor = sent
        }

        // A swap for the cleaned text is due: it needs all of the streamed text in the field first.
        let swapDue = state.isFinal && state.delivery == .replace && ProxyEditPlanner.cleanedText(state) != nil
            && cursor?.finalReplaced == nil
        let streamedLanded = cursor?.runID == runID && cursor?.committedCount == state.committed.count
            && cursor?.volatile.isEmpty == true
        let span = ProxyEditPlanner.streamedSpan(of: state.committed)
        let swapWaits = swapDue && streamedLanded && !span.isEmpty && !contextBefore.hasSuffix(span)

        let revisionWaits = Self.revisionAwaitsContext(state: state, cursor: cursor, contextBefore: contextBefore)

        if let cursor, cursor.runID == runID, waitedMs < Self.settleLimitMs,
           (!cursor.volatile.isEmpty && !contextBefore.hasSuffix(cursor.volatile)) || swapWaits || revisionWaits {
            waitedMs += elapsedMs
            needsTicks = true
            return ProxyPlan(ops: [], cursor: cursor)
        }
        waitedMs = 0

        if !animated {
            revealed = total
        } else if elapsedMs > 0 {
            revealed = min(total, revealed + 1)
        }

        // The swap is a step of its own, after the streamed text has settled in the field.
        let streamOnly = swapDue && !streamedLanded
        var shown = Self.shown(state, count: revealed)
        if streamOnly { shown.finalText = nil }
        var plan = ProxyEditPlanner.plan(
            state: shown, cursor: cursor, contextBefore: contextBefore, documentID: documentID)
        if revealed < total || streamOnly {
            plan.cursor?.finalApplied = false
            needsTicks = true
        }
        return play(plan, state: state, cursor: cursor, contextBefore: contextBefore, contextAfter: contextAfter,
                    documentID: documentID, elapsedMs: elapsedMs)
    }

    /// Use the same confirmed edit queue as magic, including for held takes and final cleanup.
    private mutating func play(_ plan: ProxyPlan, state: HostState, cursor: AppliedCursor?, contextBefore: String,
                               contextAfter: String, documentID: String?, elapsedMs: Double) -> ProxyPlan {
        guard !plan.ops.isEmpty, let documentID else { return plan }
        let ops: [ShadowOp] = plan.ops.flatMap { op -> [ShadowOp] in
            switch op {
            case .move(let units): return [.move(units)]
            case .deleteBackward(let count): return Array(repeating: .deleteBackward(1), count: count)
            case .insert(let text): return text.map { .insert(String($0)) }
            }
        }
        let result = ShadowEditPlanner.simulate(ops: ops, shadow: contextBefore + contextAfter, cursor: contextBefore.utf16.count)
        let edit = ScopedEdit(instructionID: "host", documentID: documentID, before: contextBefore, after: contextAfter, target: result.text)
        let scoped = ScopedEditPlanner.Plan(ops: ops, cursor: result.cursor,
            targetBefore: String(decoding: result.text.utf16.prefix(result.cursor), as: UTF16.self))
        pending = Pending(queue: ScopedEditQueue(edit, plan: scoped, windowBefore: contextBefore, movesByCharacters: movesByCharacters), cursor: plan.cursor,
                          runID: state.runID, documentID: documentID,
                          appendOnly: ops.allSatisfy { if case .insert = $0 { true } else { false } })
        return advance(state: state, cursor: cursor, contextBefore: contextBefore, contextAfter: contextAfter, elapsedMs: elapsedMs)
    }

    private mutating func advance(state: HostState, cursor: AppliedCursor?, contextBefore: String, contextAfter: String, elapsedMs: Double) -> ProxyPlan {
        guard var transaction = pending else { return ProxyPlan(ops: [], cursor: cursor) }
        var waitingCursor = cursor
        waitingCursor?.finalApplied = false
        let action = transaction.queue.step(reportedBefore: contextBefore, reportedAfter: contextAfter,
                                           hasSelection: false, elapsedMs: elapsedMs)
        switch action {
        case .send(let op):
            pending = transaction; needsTicks = true
            let proxy: ProxyOp = switch op {
            case .move(let units): .move(units)
            case .deleteBackward(let count): .deleteBackward(count)
            case .insert(let text): .insert(text)
            }
            return ProxyPlan(ops: [proxy], cursor: waitingCursor)
        case .wait:
            pending = transaction; needsTicks = true
            return ProxyPlan(ops: [], cursor: waitingCursor)
        case .done:
            pending = nil
            // Reconcile a newer host snapshot on the next tick after acknowledging this transaction.
            needsTicks = true
            return ProxyPlan(ops: [], cursor: transaction.cursor)
        case .stopped:
            stoppedRun = transaction.runID; pending = nil
            var failed = cursor
            failed?.finalApplied = false
            if transaction.cursor?.finalReplaced != nil { failed?.finalReplaced = false }
            let handled = max(transaction.cursor?.revisionHandled ?? 0, state.delivery == .live ? state.revision?.n ?? 0 : 0)
            if handled > (failed?.revisionHandled ?? 0) {
                failed?.revisionHandled = handled
                failed?.revisionSkipped = true
            }
            return ProxyPlan(ops: [], cursor: failed)
        }
    }

    /// `.live`: a revision not yet handled replaces the run text typed on earlier ticks, which the planner looks
    /// for at the end of the field's context (before the tentative text). True while the context does not
    /// show that text yet.
    private static func revisionAwaitsContext(state: HostState, cursor: AppliedCursor?, contextBefore: String) -> Bool {
        guard state.delivery == .live, let cursor, cursor.runID == state.runID, let revision = state.revision,
              revision.n > cursor.revisionHandled, revision.start == cursor.sentBase, !cursor.revisionSkipped
        else { return false }
        let typed = min(cursor.committedCount, state.committed.count)
        let shown = ProxyEditPlanner.runText(cursor: cursor, committed: state.committed, upTo: typed)
        return !contextBefore.hasSuffix(shown + cursor.volatile)
    }

    /// `state` cut to its first `count` characters of `committed + volatile`.
    private static func shown(_ state: HostState, count: Int) -> HostState {
        var shown = state
        let committed = state.committed.count
        if count < committed {
            shown.committed = String(state.committed.prefix(count))
            shown.volatile = ""
        } else {
            shown.volatile = String(state.volatile.prefix(count - committed))
        }
        return shown
    }
}
