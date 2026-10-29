import Foundation

/// The serial, position-mapped edit queue over one field (pure value type; the owner drives it on one thread).
///
/// Sources ``submit(_:lane:)`` transactions; the executor takes one ``FieldWrite`` at a time from ``next()``,
/// runs it and hands the next host read to ``settle(_:)``; host updates the queue did not cause go to
/// ``observe(_:)``. Every landed step moves the pending edits (before it: unchanged; after it: shifted; inside
/// it: conflict). Outcomes come out of ``takeEvents()`` and, for the field's readers, the seq-numbered ``feed``.
public struct FieldEditQueue: Sendable {
    /// The field as predicted after every issued write.
    public private(set) var document: ShadowDocument
    public private(set) var feed: FeedLog

    private struct Pending: Sendable {
        var transaction: EditTransaction  // steps mapped to `document.version`
        var lane: Lane
    }

    private struct Landed: Sendable {
        var version: FieldVersion  // after the step
        var step: EditStep
        var transaction: UUID?
        var owner: String?
        var byUser: Bool
    }

    private struct Unverified: Sendable {
        var write: FieldWrite
        var window: String  // the predicted window once it has landed
    }

    private var pending: [Pending] = []
    private var unverified: [Unverified] = []
    /// Every step landed since the last reset, for mapping stale submissions.
    private var history: [Landed] = []
    /// The version of the last reset; edits based before it are out of window.
    private var epoch: FieldVersion
    /// The window as last confirmed by a host read.
    private var confirmedWindow: String
    private var events: [QueueEvent] = []

    public init(_ snapshot: FieldSnapshot, version: FieldVersion = FieldVersion(0)) {
        document = ShadowDocument(
            window: snapshot.window, windowBase: snapshot.windowBase, caret: snapshot.caret, version: version)
        feed = FeedLog(version: version)
        epoch = version
        confirmedWindow = snapshot.window
    }

    /// Whether any edit is waiting to be written.
    public var hasPending: Bool { !pending.isEmpty }

    /// The events since the last call, oldest first.
    public mutating func takeEvents() -> [QueueEvent] {
        defer { events = [] }
        return events
    }

    // MARK: Submitting

    /// Queues `transaction` in `lane` (default: its origin's lane), mapped from its base to the current version.
    public mutating func submit(_ transaction: EditTransaction, lane: Lane? = nil) {
        guard transaction.base >= epoch else { return conflict(transaction.id, Conflict(.outOfWindow)) }
        var transaction = transaction
        transaction.steps.sort { $0.span.location < $1.span.location }
        for (a, b) in zip(transaction.steps, transaction.steps.dropFirst()) where b.span.location < a.span.end {
            return conflict(transaction.id, Conflict(.overlap))
        }
        for landed in history where landed.version > transaction.base {
            guard let mapped = rebase(transaction, through: landed) else { return }
            transaction = mapped
        }
        if let key = transaction.coalesce {
            for item in pending where item.transaction.coalesce == key {
                events.append(.superseded(item.transaction.id, by: transaction.id))
            }
            pending.removeAll { $0.transaction.coalesce == key }
        }
        pending.append(Pending(transaction: transaction, lane: lane ?? transaction.origin.lane))
    }

    // MARK: Writing

    /// The next write to run: the oldest edit of the highest lane whose guards hold. Edits failing a guard are
    /// handed back on the way. While issued writes await a host read only the user lane runs; the rest wait.
    public mutating func next() -> FieldWrite? {
        while let index = nextIndex() {
            let item = pending.remove(at: index)
            if let reason = check(item.transaction) {
                conflict(item.transaction.id, Conflict(reason, byUser: reason == .ownerTainted))
                continue
            }
            return issue(item)
        }
        return nil
    }

    private func nextIndex() -> Int? {
        let eligible = pending.indices.filter { unverified.isEmpty || pending[$0].lane == .user }
        guard let top = eligible.map({ pending[$0].lane }).max() else { return nil }
        return eligible.first { pending[$0].lane == top }
    }

    /// Why `transaction` must not be written now, if anything.
    private func check(_ transaction: EditTransaction) -> Conflict.Reason? {
        let window = document.window
        for step in transaction.steps {
            guard step.span.location >= 0, step.span.end <= window.utf16.count else { return .outOfWindow }
            guard step.matches(window) else { return .expectMismatch }
            if !transaction.origin.isUser, document.tainted.contains(where: { touches(step.span, $0) }) {
                return .ownerTainted
            }
        }
        return nil
    }

    private mutating func issue(_ item: Pending) -> FieldWrite {
        let transaction = item.transaction
        let caretBias: Bias = transaction.origin.isUser || transaction.origin == .asr ? .after : .before
        let ordered = Array(transaction.steps.reversed())
        var caret = document.caret
        for step in ordered {
            caret = StepMap(step).map(position: caret, bias: caretBias)
            land(step, transaction: transaction.id, owner: transaction.owner, byUser: transaction.origin.isUser)
        }
        document.caret = transaction.caret ?? caret
        let write = FieldWrite(
            id: transaction.id, origin: transaction.origin, lane: item.lane, steps: ordered,
            caret: document.caret, version: document.version)
        unverified.append(Unverified(write: write, window: document.window))
        return write
    }

    // MARK: Host reads

    /// Checks the host read after issued writes against the prediction.
    public mutating func settle(_ snapshot: FieldSnapshot) {
        guard !unverified.isEmpty else { return observe(snapshot) }
        if byteEqual(snapshot.window, document.window) {
            for item in unverified { events.append(.applied(item.write.id, version: item.write.version)) }
            unverified = []
            confirmedWindow = document.window
            document.caret = snapshot.caret
        }
    }

    /// A host update the queue did not write: a caret move, a foreign change, or a window it cannot align.
    public mutating func observe(_ snapshot: FieldSnapshot) {
        if !unverified.isEmpty { return settle(snapshot) }
        if byteEqual(snapshot.window, document.window) {
            document.caret = snapshot.caret
            return
        }
        guard let step = ContiguousPatch.between(document.window, snapshot.window, at: 0) else { return }
        land(step, transaction: nil, owner: nil, byUser: true)
        confirmedWindow = document.window
        document.caret = snapshot.caret
    }

    public mutating func reset(_ snapshot: FieldSnapshot, reason: ResetReason) {}

    // MARK: Landing

    /// Applies one landed step (own or foreign) to the shadow document and moves everything through it.
    private mutating func land(_ step: EditStep, transaction: UUID?, owner: String?, byUser: Bool) {
        let map = StepMap(step)
        document.window = document.window.replacing(step.span, with: step.text)
        document.version = document.version.next
        let landed = Landed(
            version: document.version, step: step, transaction: transaction, owner: owner, byUser: byUser)
        history.append(landed)

        let written = Span(location: step.span.location, length: map.insertedLength)
        var tainted = document.tainted.compactMap { map.adjust($0) }
        var owned: [OwnedSpan] = []
        for span in document.owned {
            guard byUser, touches(step.span, span.span) else {
                if let moved = map.adjust(span.span) { owned.append(OwnedSpan(owner: span.owner, span: moved)) }
                continue
            }
            // The user changed owned text: their text stays inside the owner's span, and is tainted.
            tainted.append(written)
            let kept = map.adjust(span.span) ?? written
            let start = min(kept.location, written.location), end = max(kept.end, written.end)
            owned.append(OwnedSpan(owner: span.owner, span: Span(location: start, length: end - start)))
        }
        if !byUser, let owner, !written.isEmpty { owned.append(OwnedSpan(owner: owner, span: written)) }
        document.owned = owned
        document.tainted = tainted

        pending = pending.compactMap { item in
            rebase(item.transaction, through: landed).map { Pending(transaction: $0, lane: item.lane) }
        }
    }

    /// `transaction` moved through `landed`, or nil after handing it back (superseded or in conflict).
    private mutating func rebase(_ transaction: EditTransaction, through landed: Landed) -> EditTransaction? {
        let map = StepMap(landed.step)
        var transaction = transaction
        for index in transaction.steps.indices {
            guard case .moved(let span) = map.map(transaction.steps[index].span, bias: transaction.origin.insertBias)
            else {
                if let owner = landed.owner, owner == transaction.owner, let by = landed.transaction {
                    events.append(.superseded(transaction.id, by: by))
                } else {
                    conflict(transaction.id, Conflict(.overlap, intervening: landed.step, byUser: landed.byUser))
                }
                return nil
            }
            transaction.steps[index].span = span
        }
        transaction.caret = transaction.caret.map { map.map(position: $0, bias: transaction.origin.insertBias) }
        return transaction
    }

    private mutating func conflict(_ id: UUID, _ conflict: Conflict) {
        events.append(.conflict(id, conflict))
    }
}

/// Whether an edit of `span` touches `other`: overlapping text, an insertion point strictly inside it, or (for a
/// zero-length `other`, a deletion mark) a range that reaches it.
func touches(_ span: Span, _ other: Span) -> Bool {
    switch (span.isEmpty, other.isEmpty) {
    case (false, false): span.location < other.end && other.location < span.end
    case (true, false): other.location < span.location && span.location < other.end
    case (false, true): span.location <= other.location && other.location <= span.end
    case (true, true): span.location == other.location
    }
}
