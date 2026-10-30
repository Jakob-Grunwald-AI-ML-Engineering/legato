import Foundation

/// Lets the host's text appear in the field like typing instead of in chunks: it plans against a prefix of
/// the host's text (`ProxyEditPlanner` does the rest) and grows that prefix with `TypewriterDrain` on
/// every tick. The keyboard calls `plan` for each host update and for each tick while `needsTicks`.
///
/// - The reveal counts characters of `committed + volatile`. Text the host revises behind the revealed
///   part, or shortens below it, is not animated: the reveal jumps to the full text and the planner's
///   diff applies the revision at once. A revision of the part not yet revealed just moves the target.
/// - A run's final state is reported (`AppliedCursor.finalApplied`) only once all of it is in the field.
/// - A new run starts at nothing; the same run met again (a restarted keyboard) continues from what the
///   cursor says is typed.
/// - Right after an insert the field can still report the old context, and the planner would take the
///   tentative text it can't find at the end of it for the user's and type it again. So while the context
///   doesn't end with the cursor's tentative text, ticks wait (`settleLimitMs` at most, then it is
///   planned against as before: the user did move on). Host updates don't use up that wait.
/// - Nothing is drained without a field to type into (no field, another field, not the keyboard's run).
/// - Cleanup delivery (`HostState.delivery`): with `.replace` the streamed text is revealed like any other; a
///   swap for the final text (a run off the link) waits until all of it is in the field and the field's context
///   shows it (`settleLimitMs` at most), and is then one edit. With `.live`, after a sent boundary the reveal goes
///   on from the boundary; tentative text sent with the message holds it until the committed text shows where
///   that text ends (`ProxyEditPlanner.awaitsSentTentative`, on the whole state).
/// - Rush (`rush`, the field edit queue's path): while edits wait behind the reveal, it drains `rushFactor` times
///   faster and is done at the latest `rushLimitMs` after it started rushing, so queued edits are not held up.
public struct TypewriterReveal: Sendable, Equatable {
    /// How long a tick waits for the field's context to show the tentative text before giving up.
    public static let settleLimitMs = 250.0
    /// How much faster a rushing reveal drains.
    public static let rushFactor = 8.0
    /// A rushing reveal has revealed everything at the latest this long after it started rushing.
    public static let rushLimitMs = 150.0

    /// More ticks are needed: text is left to reveal, or a tick is waiting for the context.
    public private(set) var needsTicks = false

    private var runID: String?
    private var text = ""
    private var revealed = 0
    private var waitedMs = 0.0
    /// The cursor's `sentCount` last seen: a new sent boundary empties the field of the run.
    private var sentCount = 0
    /// How long the reveal has been rushing (0 while it is not).
    private var rushedMs = 0.0

    public init() {}

    /// The edits that bring the field closer to `state`. `elapsedMs` is the time since the last tick (0 for
    /// a host update: it follows the new text but reveals nothing more); `animated` false (Reduce Motion,
    /// or a flush) reveals everything now. `rush`: edits wait behind the reveal (see the type's notes).
    public mutating func plan(
        state: HostState, cursor: AppliedCursor?, contextBefore: String, documentID: String?, animated: Bool,
        elapsedMs: Double = 0, rush: Bool = false
    ) -> ProxyPlan {
        needsTicks = false
        if !rush { rushedMs = 0 }
        guard let documentID, state.target == .keyboard, let runID = state.runID,
              cursor == nil || cursor?.runID != runID || cursor?.documentID == documentID
        else {
            return ProxyEditPlanner.plan(state: state, cursor: cursor, contextBefore: contextBefore, documentID: documentID)
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

        if let cursor, cursor.runID == runID, waitedMs < Self.settleLimitMs,
           (!cursor.volatile.isEmpty && !contextBefore.hasSuffix(cursor.volatile)) || swapWaits {
            waitedMs += elapsedMs
            needsTicks = true
            return ProxyPlan(ops: [], cursor: cursor)
        }
        waitedMs = 0

        if !animated {
            revealed = total
        } else if elapsedMs > 0, rush {
            rushedMs += elapsedMs
            revealed = rushedMs >= Self.rushLimitMs
                ? total : TypewriterDrain.step(revealed: revealed, target: total, dtMs: elapsedMs * Self.rushFactor)
        } else if elapsedMs > 0 {
            revealed = TypewriterDrain.step(revealed: revealed, target: total, dtMs: elapsedMs)
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
        return plan
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
