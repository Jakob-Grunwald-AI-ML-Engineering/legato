import Foundation

/// Reveals host text one character at a time. Pure producer for the field queue (`FieldQueue`): each plan proposes at
/// most one edit (`pendingEdit`, the change of the text before the cursor as minimal character edits), and nothing more
/// until the queue reports it `landed` (then the applied cursor is acknowledged) or `dropped` (that run stops, without
/// further mutations). Context and document identity protect user edits and field changes.
public struct TypewriterReveal: Sendable, Equatable {
    /// How long a tick waits for the field's context to show the tentative text before giving up.
    public static let settleLimitMs = 250.0

    /// More ticks are needed: text is left to reveal, or a tick is waiting for the context.
    public private(set) var needsTicks = false

    private struct Pending: Sendable, Equatable {
        var edit: FieldQueue.Edit
        var cursor: AppliedCursor?
        var runID: String?
        var documentID: String
        var appendOnly: Bool
    }
    private var pending: Pending?
    private var stoppedRun: String?
    private var runID: String?
    private var text = ""
    private var revealed = 0
    private var waitedMs = 0.0
    /// The cursor's `sentCount` last seen: a new sent boundary empties the field of the run.
    private var sentCount = 0

    public init() {}

    /// The edit waiting in the field queue (enqueue it once; its id names it in `landed` and `dropped`).
    public var pendingEdit: FieldQueue.Edit? { pending?.edit }

    /// A host Send is evidence that even an unacknowledged appended character left with the message.
    /// This cursor is only for clear detection; it never confirms a partially applied rewrite.
    public func cursorBeforeFieldClear(fallback: AppliedCursor?) -> AppliedCursor? {
        guard let pending, pending.appendOnly else { return fallback }
        var sent = pending.cursor
        sent?.finalApplied = false
        return sent
    }

    /// The queue landed the pending edit: its cursor is the run's applied cursor now.
    public mutating func landed(_ id: String) -> AppliedCursor? {
        guard let transaction = pending, transaction.edit.id == id else { return nil }
        pending = nil
        // Reconcile a newer host snapshot on the next tick.
        needsTicks = true
        return transaction.cursor
    }

    /// The queue dropped the pending edit (its text changed under it): the run stops; the returned cursor says what
    /// was not applied.
    public mutating func dropped(_ id: String, state: HostState, cursor: AppliedCursor?) -> AppliedCursor? {
        guard let transaction = pending, transaction.edit.id == id else { return nil }
        stoppedRun = transaction.runID; pending = nil
        var failed = cursor
        failed?.finalApplied = false
        if transaction.cursor?.finalReplaced != nil { failed?.finalReplaced = false }
        let handled = max(transaction.cursor?.revisionHandled ?? 0, state.delivery == .live ? state.revision?.n ?? 0 : 0)
        if handled > (failed?.revisionHandled ?? 0) {
            failed?.revisionHandled = handled
            failed?.revisionSkipped = true
        }
        return failed
    }

    /// The edits that bring the field closer to `state`. `elapsedMs` is the time since the last tick (0 for
    /// a host update: it follows the new text but reveals nothing more); `animated` false (Reduce Motion,
    /// or a flush) reveals everything now.
    public mutating func plan(
        state: HostState, cursor: AppliedCursor?, contextBefore: String, documentID: String?, animated: Bool,
        elapsedMs: Double = 0, contextAfter: String = "", hasSelection: Bool = false
    ) -> ProxyPlan {
        needsTicks = false
        if hasSelection {
            pending = nil; stoppedRun = state.runID
            var failed = cursor; failed?.finalApplied = false
            return ProxyPlan(ops: [], cursor: failed)
        }
        if let stoppedRun, stoppedRun == state.runID { return ProxyPlan(ops: [], cursor: cursor) }
        if let transaction = pending {
            guard transaction.runID == state.runID, transaction.documentID == documentID else {
                let previous = cursorBeforeFieldClear(fallback: cursor)
                pending = nil
                // A final publication may be the only update for this new run. Start it now;
                // returning with no ticks would silently drop the entire insertion.
                return plan(state: state, cursor: previous, contextBefore: contextBefore, documentID: documentID,
                            animated: animated, elapsedMs: elapsedMs, contextAfter: contextAfter, hasSelection: hasSelection)
            }
            if state.delivery == .live, let cursor, cursor.runID == transaction.runID,
               cursor.sentCount != (transaction.cursor?.sentCount ?? 0) {
                // The host sent the currently shown text; no queued mutation of that text may follow it.
                pending = nil
            } else {
                // The queue is landing the last edit: nothing more until it says how that went.
                needsTicks = true
                var waiting = cursor
                waiting?.finalApplied = false
                return ProxyPlan(ops: [], cursor: waiting)
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

    /// The plan's ops as one edit of the text before the cursor, for the field queue. The returned plan carries the ops
    /// (for a caller that applies them itself) and the cursor as it stands until the edit lands.
    private mutating func play(_ plan: ProxyPlan, state: HostState, cursor: AppliedCursor?, contextBefore: String,
                               contextAfter: String, documentID: String?, elapsedMs: Double) -> ProxyPlan {
        guard !plan.ops.isEmpty, let documentID else { return plan }
        let ops: [ShadowOp] = plan.ops.map { op in
            switch op {
            case .move(let units): .move(units)
            case .deleteBackward(let count): .deleteBackward(count)
            case .insert(let text): .insert(text)
            }
        }
        let result = ShadowEditPlanner.simulate(ops: ops, shadow: contextBefore, cursor: contextBefore.utf16.count)
        let old = Array(contextBefore), new = Array(result.text)
        var common = 0
        while common < min(old.count, new.count), old[common] == new[common] { common += 1 }
        let edit = FieldQueue.Edit(kind: .host, before: String(old[common...]), target: String(new[common...]), cursorAtEnd: true)
        pending = Pending(edit: edit, cursor: plan.cursor, runID: state.runID, documentID: documentID,
                          appendOnly: ops.allSatisfy { if case .insert = $0 { true } else { false } })
        needsTicks = true
        var waiting = cursor
        waiting?.finalApplied = false
        return ProxyPlan(ops: plan.ops, cursor: waiting)
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
