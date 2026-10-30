import Foundation

/// The keyboard's host-text writes through the field edit queue that have not landed yet, in order, each with
/// the applied cursor it was planned from and the one it leads to: where the cursor goes when one fails.
///
/// The cursor says what of the run is in the field. A write that may still land keeps its progress (the
/// coordinator waits out stale reads and reports a write the keyboard left unverified as `unconfirmed`), so only
/// a write the queue failed rewinds it, once:
/// - a stream chunk: back to before it, so the next plan types it again; every later write planned on top of it
///   (the next tick waiting behind it) is withdrawn and planned again with it, so nothing is typed twice or lost;
/// - the Replace swap: marked not replaced (the app falls back to the clipboard).
/// A cursor that moved on by other means (a new run, a sent boundary) keeps its progress; only those flags apply.
///
/// The rewind keeps what landed: a write on top of the failed one that only took the tentative text out (the
/// user-lane write before a key, `prepareForTyping`) and landed, before or after the failure, keeps its change
/// in the rewound cursor. A later chunk that landed while the one under it failed leaves a hole the cursor
/// cannot say; it is rewound with it, as before.
///
/// Never typed twice (``failed(_:cursor:contextBefore:fieldEmpty:)``): a failed write keeps its progress, as if it
/// landed, when the field is empty after holding text (cleared or sent: a run boundary, not a failed write; a write
/// into an empty field counts only when ClearWatch saw the clear, ``fieldCleared()``), when the field shows the
/// text the write was to leave (it landed after all), or when it was planned from a point the cursor was already
/// rewound to once (it is that retype: a chunk is typed again at most once).
public struct HostWriteLedger: Sendable, Equatable {
    public struct Failure: Sendable, Equatable {
        /// The cursor to take.
        public var cursor: AppliedCursor?
        /// Later writes planned on top of the failed one: withdraw them (those that already ran settle alone).
        public var withdraw: [UUID]
        /// Why the write keeps its progress instead of rewinding; nil when it rewinds (or the old checks apply).
        public var kept: Kept?

        public init(cursor: AppliedCursor?, withdraw: [UUID], kept: Kept? = nil) {
            self.cursor = cursor
            self.withdraw = withdraw
            self.kept = kept
        }
    }

    /// Why a failed write is not typed again.
    public enum Kept: String, Sendable, Equatable {
        /// The field is empty: it was cleared (sent) under the write.
        case cleared
        /// The field shows the text the write was to leave.
        case shown
        /// The write is the retype of one already rewound.
        case retypedOnce
    }

    private struct Entry: Sendable, Equatable {
        var id: UUID
        var previous: AppliedCursor?
        var planned: AppliedCursor?
        /// The text before the caret the write leaves (its end), for whether the field shows it.
        var expected: String?
        /// The host's field held text when the write was planned: an empty read later can be a clear.
        var fieldHadText = true
        /// ClearWatch saw the host empty the field while the write was open.
        var clearSeen = false
        /// It landed while a write before it is still unresolved.
        var landed = false
    }

    private var entries: [Entry] = []
    /// Writes that ran on top of a failed one, not resolved yet: what they change still holds if they land.
    private var orphans: [UUID: Entry] = [:]
    /// The cursors a failure rewound to: a write planned from one of them again is a retype.
    private var rewoundTo: [AppliedCursor] = []
    /// How much of the text a write leaves must show at the end of the field for it to count as there.
    static let shownTail = 64

    public init() {}

    public var isEmpty: Bool { entries.isEmpty && orphans.isEmpty }

    /// A write submitted, planned from `previous` to `planned`. `expected`: the text before the caret once it ran.
    /// `fieldHadText`: the host's field (its last read) held text when the write was planned.
    public mutating func record(
        _ id: UUID, previous: AppliedCursor?, planned: AppliedCursor?, expected: String? = nil, fieldHadText: Bool = true
    ) {
        entries.append(Entry(id: id, previous: previous, planned: planned, expected: expected, fieldHadText: fieldHadText))
    }

    /// ``failed(_:cursor:)`` with the field as it reads now (`contextBefore`, and whether it holds no text at all):
    /// a write that must not be typed again keeps its progress (see the type's notes, ``Failure/kept``).
    public mutating func failed(
        _ id: UUID, cursor: AppliedCursor?, contextBefore: String, fieldEmpty: Bool = false
    ) -> Failure? {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return failed(id, cursor: cursor) }
        let entry = entries[index]
        let kept: Kept?
        if fieldEmpty, entry.fieldHadText || entry.clearSeen {
            // Empty only counts as cleared when there was text to clear (or ClearWatch saw it go): a first chunk
            // the host dropped into an empty field reads empty too, and is typed again.
            kept = .cleared
        } else if let expected = entry.expected, !expected.isEmpty,
            contextBefore.hasSuffix(String(expected.suffix(Self.shownTail)))
        {
            kept = .shown
        } else if let previous = entry.previous, rewoundTo.contains(previous) {
            kept = .retypedOnce
        } else {
            kept = nil
        }
        guard let kept else {
            let failure = failed(id, cursor: cursor)
            if let reverted = failure?.cursor, reverted != cursor {
                rewoundTo.append(reverted)
                if rewoundTo.count > 16 { rewoundTo.removeFirst() }
            }
            return failure
        }
        entries.remove(at: index)
        return Failure(cursor: cursor, withdraw: [], kept: kept)
    }

    /// ClearWatch saw the host empty the field (a send): for every open write, an empty read is that clear.
    public mutating func fieldCleared() {
        for index in entries.indices { entries[index].clearSeen = true }
        for id in orphans.keys { orphans[id]?.clearSeen = true }
    }

    /// Confirmed or unconfirmed (it may have landed): it never rewinds the cursor.
    public mutating func landed(_ id: UUID) {
        _ = landed(id, cursor: nil)
    }

    /// ``landed(_:)``, with the cursor now: the cursor to take instead when the write ran on top of one that
    /// failed and was rewound (what it changed holds), else nil.
    public mutating func landed(_ id: UUID, cursor: AppliedCursor?) -> AppliedCursor? {
        if let index = entries.firstIndex(where: { $0.id == id }) {
            entries[index].landed = true
            while entries.first?.landed == true { entries.removeFirst() }
            return nil
        }
        guard let orphan = orphans.removeValue(forKey: id), let cursor,
            let kept = Self.keeping(orphan, on: cursor), kept != cursor
        else { return nil }
        return kept
    }

    /// Withdrawn while it waited: never written, nothing of it holds.
    public mutating func withdrawn(_ id: UUID) {
        entries.removeAll { $0.id == id }
        orphans[id] = nil
    }

    /// The write `id` failed with the cursor at `cursor`; nil when it is not recorded (landed, or already handed
    /// back: a write rewinds the cursor once).
    public mutating func failed(_ id: UUID, cursor: AppliedCursor?) -> Failure? {
        guard let index = entries.firstIndex(where: { $0.id == id }) else {
            orphans[id] = nil
            return nil
        }
        let entry = entries[index]
        let chain = entries[index...]
        entries.removeSubrange(index...)
        let onChain = cursor == entry.previous || chain.contains { $0.planned == cursor }
        var reverted = onChain ? entry.previous : cursor
        if var flagged = reverted, let planned = entry.planned, planned.runID == flagged.runID {
            if planned.finalReplaced == true, entry.previous?.finalReplaced == nil {
                flagged.finalReplaced = false
                flagged.finalApplied = false
            }
            reverted = flagged
        }
        let later = chain.dropFirst()
        if onChain {
            for landed in later where landed.landed {
                if let current = reverted, let kept = Self.keeping(landed, on: current) { reverted = kept }
            }
        }
        for open in later where !open.landed { orphans[open.id] = open }
        return Failure(cursor: reverted, withdraw: later.filter { !$0.landed }.map(\.id))
    }

    /// `cursor` with what `write` changed, when it only took the tentative text out (its volatile text, the
    /// separator and the final flag) on the same run; nil for any other write.
    private static func keeping(_ write: Entry, on cursor: AppliedCursor) -> AppliedCursor? {
        guard let from = write.previous, let to = write.planned, from.runID == cursor.runID, to.runID == from.runID
        else { return nil }
        var tentativeOnly = to
        tentativeOnly.volatile = from.volatile
        tentativeOnly.needsSeparator = from.needsSeparator
        tentativeOnly.finalApplied = from.finalApplied
        guard tentativeOnly == from else { return nil }
        var kept = cursor
        if from.volatile != to.volatile { kept.volatile = to.volatile }
        if from.needsSeparator != to.needsSeparator { kept.needsSeparator = to.needsSeparator }
        if from.finalApplied != to.finalApplied { kept.finalApplied = to.finalApplied }
        return kept
    }
}
