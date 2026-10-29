import Foundation

/// The keyboard's host-text writes through the field edit queue that have not landed yet, in order, each with
/// the applied cursor it was planned from and the one it leads to: where the cursor goes when one fails.
///
/// The cursor says what of the run is in the field. A write that may still land keeps its progress (the
/// coordinator waits out stale reads and reports a write the keyboard left unverified as `unconfirmed`), so only
/// a write the queue failed rewinds it, once:
/// - a stream chunk: back to before it, so the next plan types it again; every later write planned on top of it
///   (the next tick waiting behind it) is withdrawn and planned again with it, so nothing is typed twice or lost;
/// - a Live revision: marked skipped (never retried, as when the user edited the run's text);
/// - the Replace swap: marked not replaced (the app falls back to the clipboard).
/// A cursor that moved on by other means (a new run, a sent boundary) keeps its progress; only those flags apply.
public struct HostWriteLedger: Sendable, Equatable {
    public struct Failure: Sendable, Equatable {
        /// The cursor to take.
        public var cursor: AppliedCursor?
        /// Later writes planned on top of the failed one: withdraw them (those that already ran settle alone).
        public var withdraw: [UUID]

        public init(cursor: AppliedCursor?, withdraw: [UUID]) {
            self.cursor = cursor
            self.withdraw = withdraw
        }
    }

    private struct Entry: Sendable, Equatable {
        var id: UUID
        var previous: AppliedCursor?
        var planned: AppliedCursor?
    }

    private var entries: [Entry] = []

    public init() {}

    public var isEmpty: Bool { entries.isEmpty }

    /// A write submitted, planned from `previous` to `planned`.
    public mutating func record(_ id: UUID, previous: AppliedCursor?, planned: AppliedCursor?) {
        entries.append(Entry(id: id, previous: previous, planned: planned))
    }

    /// Confirmed, unconfirmed (it may have landed) or withdrawn: it never rewinds the cursor.
    public mutating func landed(_ id: UUID) {
        entries.removeAll { $0.id == id }
    }

    /// The write `id` failed with the cursor at `cursor`; nil when it is not recorded (landed, or already handed
    /// back: a write rewinds the cursor once).
    public mutating func failed(_ id: UUID, cursor: AppliedCursor?) -> Failure? {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return nil }
        let entry = entries[index]
        let chain = entries[index...]
        entries.removeSubrange(index...)
        let onChain = cursor == entry.previous || chain.contains { $0.planned == cursor }
        var reverted = onChain ? entry.previous : cursor
        if var flagged = reverted, let planned = entry.planned, planned.runID == flagged.runID {
            if planned.revisionHandled > (entry.previous?.revisionHandled ?? 0) {
                flagged.revisionHandled = max(flagged.revisionHandled, planned.revisionHandled)
                flagged.revisionSkipped = true
                flagged.finalApplied = false
            }
            if planned.finalReplaced == true, entry.previous?.finalReplaced == nil {
                flagged.finalReplaced = false
                flagged.finalApplied = false
            }
            reverted = flagged
        }
        return Failure(cursor: reverted, withdraw: chain.dropFirst().map(\.id))
    }
}
