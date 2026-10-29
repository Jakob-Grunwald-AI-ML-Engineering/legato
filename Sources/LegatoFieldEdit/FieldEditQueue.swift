import Foundation

/// What a host read did to the issued writes (``FieldEditQueue/settle(_:final:)``).
public enum SettleOutcome: Sendable, Hashable {
    /// Every issued write shows in the field.
    case confirmed
    /// At least one write did not land: it and every write after it failed (`verifyFailed`) and were rolled back.
    case diverged
    /// The read shows only the oldest writes, or none yet (only with `final: false`): those it shows are confirmed
    /// and the rest wait for the next read.
    case notYet
}

/// The serial, position-mapped edit queue over one field (pure value type; the owner drives it on one thread).
///
/// Sources ``submit(_:lane:)`` transactions; the executor takes one ``FieldWrite`` at a time from ``next()``,
/// runs it and hands the next host read to ``settle(_:final:)`` (or ``abort(_:requeue:reason:)`` when it did not
/// run it); host updates the queue did not cause go to ``observe(_:)``. Every landed step moves the pending edits
/// (before it: unchanged; after it: shifted; inside it: conflict). Outcomes come out of ``takeEvents()`` and, for
/// the field's readers, the seq-numbered ``feed``.
///
/// Versions: ``document`` is the field predicted after every issued write, ``feed`` the field confirmed by host
/// reads; both name their state with a ``FieldVersion`` of this instance (``session``). Version numbers are never
/// reused: a write that fails is rolled back out of the history and its version is dead.
public struct FieldEditQueue: Sendable {
    /// The field as predicted after every issued write.
    public private(set) var document: ShadowDocument
    public private(set) var feed: FeedLog
    /// This queue instance; edits based on another instance's versions are out of window.
    public let session: UUID

    /// Where an edit's own caret goes: into (or at an edge of) one of its steps' text, or a position of the field
    /// before its steps. Mapped with the steps, resolved when the edit is written.
    private enum CaretAnchor: Sendable {
        case inStep(Int, offset: Int)
        case position(Int)
    }

    private struct Pending: Sendable {
        var transaction: EditTransaction  // steps mapped to `document.version`, sorted by location
        var lane: Lane
        var caret: CaretAnchor?
    }

    /// A change positions are mapped through.
    private enum Change: Sendable {
        case step(EditStep)
        /// The caret-relative window's edges moved: offset `p` is now `p + shift`, visible in `0...count`.
        case edges(shift: Int, count: Int)

        func map(_ span: Span, bias: Bias) -> Span? {
            switch self {
            case .step(let step):
                guard case .moved(let moved) = StepMap(step).map(span, bias: bias) else { return nil }
                return moved
            case .edges(let shift, let count):
                let moved = Span(location: span.location + shift, length: span.length)
                return moved.location >= 0 && moved.end <= count ? moved : nil
            }
        }

        func map(position p: Int, bias: Bias) -> Int {
            switch self {
            case .step(let step): StepMap(step).map(position: p, bias: bias)
            case .edges(let shift, let count): min(max(p + shift, 0), count)
            }
        }
    }

    private struct Landed: Sendable {
        var version: FieldVersion  // after the change
        var change: Change
        var transaction: UUID?
        var owner: String?
        var byUser: Bool
    }

    private struct Unverified: Sendable {
        var write: FieldWrite
        var item: Pending  // as it was issued, against `before`
        var before: ShadowDocument
    }

    /// How a host read follows from a document: an optional foreign change at the caret, then a window edge shift.
    private struct Alignment: Sendable {
        var step: EditStep?
        var shift: Int
        var window: String
        var caret: Int
    }

    private var pending: [Pending] = []
    private var unverified: [Unverified] = []
    /// Every change landed since `floor`, own or foreign, for mapping stale submissions.
    private var history: [Landed] = []
    /// The oldest version edits may be based on (the last reset or pruning point).
    private var floor: FieldVersion
    /// The newest version number handed out.
    private var lastVersion: Int
    private var events: [QueueEvent] = []

    public init(_ snapshot: FieldSnapshot, version: FieldVersion = FieldVersion(0), session: UUID = UUID()) {
        document = ShadowDocument(
            window: snapshot.window, windowBase: snapshot.windowBase, caret: snapshot.caret, version: version)
        feed = FeedLog(version: version, window: snapshot.window, session: session)
        self.session = session
        floor = version
        lastVersion = version.rawValue
    }

    /// Whether any edit is waiting to be written.
    public var hasPending: Bool { !pending.isEmpty }

    /// Records recognized text streamed into the run (Mac), in order with the field's own events.
    public mutating func appendASR(_ delta: String) { feed.append(.asrDelta(delta)) }

    /// The events since the last call, oldest first.
    public mutating func takeEvents() -> [QueueEvent] {
        defer { events = [] }
        return events
    }

    // MARK: Submitting

    /// Queues `transaction` in `lane` (default: its origin's lane), mapped from its base to the current version.
    /// A base this queue cannot map from (see ``EditTransaction``) is handed back as `outOfWindow`.
    public mutating func submit(_ transaction: EditTransaction, lane: Lane? = nil) {
        guard transaction.session == nil || transaction.session == session, isKnown(transaction.base) else {
            return conflict(transaction.id, Conflict(.outOfWindow))
        }
        var transaction = transaction
        transaction.steps.sort { $0.span.location < $1.span.location }
        for (a, b) in zip(transaction.steps, transaction.steps.dropFirst()) where b.span.location < a.span.end {
            return conflict(transaction.id, Conflict(.overlap))
        }
        var item = Pending(
            transaction: transaction, lane: lane ?? transaction.origin.lane,
            caret: transaction.caret.map { Self.anchor($0, in: transaction.steps) })
        for landed in history where landed.version > transaction.base {
            guard let mapped = rebase(item, through: landed) else { return }
            item = mapped
        }
        if let key = transaction.coalesce {
            for old in pending where old.transaction.coalesce == key { supersede(old.transaction.id, by: transaction.id) }
            pending.removeAll { $0.transaction.coalesce == key }
        }
        pending.append(item)
    }

    /// Drops the history older than `version` (never past the confirmed field): edits based before it are out of
    /// window from now on.
    public mutating func pruneHistory(before version: FieldVersion) {
        let limit = min(version, unverified.first?.before.version ?? document.version)
        let kept = ([floor] + history.map(\.version)).filter { $0 <= limit }.max() ?? floor
        history.removeAll { $0.version <= kept }
        floor = kept
    }

    /// Drops the feed entries up to and including `seq` (``FeedLog/trim(through:)``).
    public mutating func trimFeed(through seq: Int) { feed.trim(through: seq) }

    private func isKnown(_ base: FieldVersion) -> Bool {
        base == floor || history.contains { $0.version == base }
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

    /// Why `transaction` must not be written now, if anything. A span that splits a Character (a surrogate pair,
    /// a grapheme cluster) is an expect mismatch: the field does not hold whole text there.
    private func check(_ transaction: EditTransaction) -> Conflict.Reason? {
        let window = document.window
        let boundaries = window.characterBoundaries
        for step in transaction.steps {
            guard step.span.location >= 0, step.span.end <= window.utf16.count else { return .outOfWindow }
            guard step.matches(window) else { return .expectMismatch }
            guard boundaries.contains(step.span.location), boundaries.contains(step.span.end) else {
                return .expectMismatch
            }
            if !transaction.origin.isUser, document.tainted.contains(where: { touches(step.span, $0) }) {
                return .ownerTainted
            }
        }
        return nil
    }

    private mutating func issue(_ item: Pending) -> FieldWrite {
        let before = document
        let transaction = item.transaction
        let caretBias: Bias = transaction.origin.isUser || transaction.origin == .asr ? .after : .before
        let ordered = Array(transaction.steps.reversed())
        var caret = document.caret
        for step in ordered {
            caret = StepMap(step).map(position: caret, bias: caretBias)
            land(step, transaction: transaction.id, owner: transaction.owner, byUser: transaction.origin.isUser)
        }
        if let anchor = item.caret { caret = Self.resolve(anchor, steps: transaction.steps) }
        document.caret = caret
        let write = FieldWrite(
            id: transaction.id, origin: transaction.origin, owner: transaction.owner, lane: item.lane,
            steps: ordered, caret: caret, version: document.version)
        unverified.append(Unverified(write: write, item: item, before: before))
        return write
    }

    /// Hands back a write ``next()`` issued that the executor did not run (a pre-write re-read found the user
    /// typing, the field is unreadable, the write call failed, focus moved). The write and every write issued
    /// after it are rolled back; `id` is requeued (front of its lane, mapped through what lands next) or handed
    /// back with `reason`; the later writes are always requeued. Call it before handing the read to ``observe(_:)``.
    public mutating func abort(_ id: UUID, requeue: Bool, reason: Conflict.Reason) {
        guard let index = unverified.firstIndex(where: { $0.write.id == id }) else { return }
        rollBack(from: index, requeueFirst: requeue, requeueRest: true, reason: reason)
    }

    // MARK: Host reads

    /// Checks a host read after issued writes against the predictions, in one step. The read is matched against
    /// the newest prediction it is consistent with: byte-identical first, then the same text with the iOS
    /// window's edges moved, then the prediction plus a foreign change at the caret that leaves the written text
    /// alone (the user typed on after the write). Every write up to that prediction is confirmed (`applied`);
    /// a foreign remainder lands as a `byUser` step, an edge move as a re-base.
    ///
    /// Writes the read does not show: with `final` (the Mac's synchronous readback, or the last read before a
    /// timeout) they fail with `verifyFailed` and are rolled back by inverting their steps; without it, a read
    /// that only lags (shows the oldest writes or none, with no foreign change) returns `notYet` and they wait.
    /// A read consistent with no prediction fails them all and is then observed against the confirmed field.
    @discardableResult
    public mutating func settle(_ snapshot: FieldSnapshot, final: Bool = true) -> SettleOutcome {
        guard !unverified.isEmpty else {
            observe(snapshot)
            return .confirmed
        }
        let predictions = unverified.map(\.before) + [document]
        // The text the writes up to each prediction wrote, in that prediction's offsets.
        var written: [[Span]] = [[]]
        var spans: [Span] = []
        for item in unverified {
            for step in item.write.steps {
                let map = StepMap(step)
                spans = spans.compactMap { map.adjust($0) }
                spans.append(Span(location: step.span.location, length: map.insertedLength))
            }
            written.append(spans)
        }

        var choice: (k: Int, alignment: Alignment?)?
        let indices = Array(predictions.indices.reversed())
        if !windowBaseMoved(snapshot) {
            if let k = indices.first(where: { byteEqual(predictions[$0].window, snapshot.window) }) {
                choice = (k, nil)
            } else if !snapshot.window.isEmpty {
                let candidates = indices.map { (k: $0, alignments: alignments(predictions[$0], snapshot)) }
                if let edge = candidates.first(where: { $0.alignments.edges != nil }) {
                    choice = (edge.k, edge.alignments.edges)
                } else if let typed = candidates.first(where: { candidate in
                    guard let step = candidate.alignments.typing?.step else { return false }
                    return !written[candidate.k].contains { touches(step.span, $0) }
                }) {
                    choice = (typed.k, typed.alignments.typing)
                }
            }
        }

        guard let choice else {
            rollBack(from: 0, requeueFirst: false, requeueRest: false, reason: .verifyFailed)
            observe(snapshot)
            return .diverged
        }
        for item in unverified[..<choice.k] {
            events.append(.applied(item.write.id, version: item.write.version))
            feed.append(.applied(item.write.id, origin: item.write.origin, steps: item.write.steps, version: item.write.version))
        }
        unverified.removeFirst(choice.k)
        if !unverified.isEmpty {
            if !final, choice.alignment?.step == nil { return .notYet }
            rollBack(from: 0, requeueFirst: false, requeueRest: false, reason: .verifyFailed)
        }
        apply(choice.alignment, snapshot)
        return choice.k == predictions.count - 1 ? .confirmed : .diverged
    }

    /// A host update the queue did not write. The same window is a caret-only move (offsets re-based exactly, no
    /// text search). Otherwise the read is aligned at the caret: on the Mac (absolute window) any change becomes
    /// one foreign `byUser` step, its common prefix capped at the lower caret; on iOS a change at the caret
    /// (typing, deleting, pasting: the text before the caret changed at its end, the text after it only at its far
    /// edge) is a foreign step, and a read that only moved the window's edges is a re-base that taints nothing.
    /// Anything else is not alignable and resets; so does an emptied field. While writes await verification this
    /// settles them first (`final`).
    public mutating func observe(_ snapshot: FieldSnapshot) {
        if !unverified.isEmpty {
            settle(snapshot)
            return
        }
        if windowBaseMoved(snapshot) { return reset(snapshot, reason: .unaligned) }
        if byteEqual(document.window, snapshot.window) {
            document.caret = snapshot.caret
            return
        }
        if snapshot.window.isEmpty { return reset(snapshot, reason: .cleared) }
        let candidates = alignments(document, snapshot)
        guard let alignment = candidates.typing ?? candidates.edges else { return reset(snapshot, reason: .unaligned) }
        apply(alignment, snapshot)
    }

    /// Drops the shadow document for a fresh read: issued writes fail (`verifyFailed`, or `focusLost` on a focus
    /// change), pending edits are handed back (`outOfWindow` / `focusLost`) and edits based before the reset are
    /// out of window. Owned and tainted spans start over.
    public mutating func reset(_ snapshot: FieldSnapshot, reason: ResetReason) {
        let focus = reason == .focusChanged
        for item in unverified { conflict(item.write.id, Conflict(focus ? .focusLost : .verifyFailed)) }
        for item in pending { conflict(item.transaction.id, Conflict(focus ? .focusLost : .outOfWindow)) }
        unverified = []
        pending = []
        history = []
        floor = nextVersion()
        document = ShadowDocument(
            window: snapshot.window, windowBase: snapshot.windowBase, caret: snapshot.caret, version: floor)
        feed.append(.reset(reason, window: snapshot.window, version: floor))
    }

    // MARK: Aligning reads

    private func windowBaseMoved(_ snapshot: FieldSnapshot) -> Bool {
        guard let base = document.windowBase, let read = snapshot.windowBase else { return false }
        return base != read
    }

    /// How `read` can follow from `document`: `typing`, a foreign change at the caret; `edges`, the same text
    /// with the caret-relative window's edges moved (iOS only).
    private func alignments(_ document: ShadowDocument, _ read: FieldSnapshot) -> (typing: Alignment?, edges: Alignment?) {
        if document.windowBase != nil, read.windowBase != nil {
            let step = ContiguousPatch.between(
                document.window, read.window, at: 0, prefixLimit: min(document.caret, read.caret))
            return (Alignment(step: step, shift: 0, window: read.window, caret: read.caret), nil)
        }
        let predicted = FieldSnapshot(window: document.window, caret: document.caret)
        let (before, after) = (predicted.before, predicted.after)
        guard after.hasUnitPrefix(read.after) || read.after.hasUnitPrefix(after) else { return (nil, nil) }
        var edges: Alignment?
        if before.hasUnitSuffix(read.before) || read.before.hasUnitSuffix(before) {
            edges = Alignment(step: nil, shift: read.caret - document.caret, window: read.window, caret: read.caret)
        }
        // Typing keeps the window's left edge: the change runs from the common prefix to the caret. A change that
        // shares no prefix and both removes and inserts is not typing (the edge or the caret moved).
        var typing: Alignment?
        if let step = ContiguousPatch.between(before, read.before, at: 0, prefixLimit: .max, suffix: false),
            step.span.location > 0 || step.expect.isEmpty || step.text.isEmpty
        {
            typing = Alignment(step: step, shift: 0, window: read.window, caret: read.caret)
        }
        return (typing, edges)
    }

    /// Lands an alignment of `snapshot` against the current document: a foreign step, then a window re-base.
    private mutating func apply(_ alignment: Alignment?, _ snapshot: FieldSnapshot) {
        guard let alignment else {
            document.caret = snapshot.caret
            return
        }
        if let step = alignment.step {
            land(step, transaction: nil, owner: nil, byUser: true)
            feed.append(.foreign(step, byUser: true, version: document.version))
        }
        if alignment.shift != 0 || !byteEqual(document.window, alignment.window) {
            shiftWindow(to: alignment.window, shift: alignment.shift)
        }
        document.caret = alignment.caret
    }

    // MARK: Landing

    private mutating func nextVersion() -> FieldVersion {
        lastVersion += 1
        return FieldVersion(lastVersion)
    }

    /// Applies one landed step (own or foreign) to the shadow document and moves everything through it.
    private mutating func land(_ step: EditStep, transaction: UUID?, owner: String?, byUser: Bool) {
        let map = StepMap(step)
        document.window = document.window.replacing(step.span, with: step.text)
        document.version = nextVersion()
        let landed = Landed(
            version: document.version, change: .step(step), transaction: transaction, owner: owner, byUser: byUser)
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

        pending = pending.compactMap { rebase($0, through: landed) }
    }

    /// The caret-relative window now reads `window` with old offsets moved by `shift`: no text changed, so
    /// nothing is tainted; pending edits that fell off an edge are out of window.
    private mutating func shiftWindow(to window: String, shift: Int) {
        let count = window.utf16.count
        document.window = window
        document.version = nextVersion()
        let landed = Landed(
            version: document.version, change: .edges(shift: shift, count: count), transaction: nil, owner: nil,
            byUser: false)
        history.append(landed)
        func clip(_ span: Span) -> Span? {
            let start = span.location + shift, end = span.end + shift
            if span.isEmpty { return (0...count).contains(start) ? .at(start) : nil }
            let low = max(start, 0), high = min(end, count)
            return high > low ? Span(location: low, length: high - low) : nil
        }
        document.owned = document.owned.compactMap { owned in clip(owned.span).map { OwnedSpan(owner: owned.owner, span: $0) } }
        document.tainted = document.tainted.compactMap(clip)
        pending = pending.compactMap { rebase($0, through: landed) }
        feed.append(.rebased(window: window, shift: shift, version: document.version))
    }

    /// Undoes `unverified[index...]` by inverting their steps in reverse order: the document returns to what it
    /// was before the first of them, their changes leave the history (their versions are dead) and pending edits
    /// are mapped back through the inverted steps.
    private mutating func rollBack(from index: Int, requeueFirst: Bool, requeueRest: Bool, reason: Conflict.Reason) {
        let undone = Array(unverified[index...])
        guard let first = undone.first else { return }
        unverified.removeSubrange(index...)
        func requeues(_ offset: Int) -> Bool { offset == 0 ? requeueFirst : requeueRest }
        for (offset, item) in undone.enumerated() where !requeues(offset) {
            conflict(item.write.id, Conflict(reason))
        }
        for (offset, item) in undone.enumerated().reversed() {
            for step in item.write.steps.reversed() {
                let inverse = EditStep(
                    span: Span(location: step.span.location, length: step.text.utf16.count), text: step.expect,
                    expect: step.text)
                pending = pending.compactMap { waiting in
                    if let moved = mapped(waiting, through: .step(inverse)) { return moved }
                    conflict(waiting.transaction.id, Conflict(reason))
                    return nil
                }
            }
            if requeues(offset) { pending.insert(item.item, at: 0) }
        }
        document = first.before
        history.removeAll { $0.version > first.before.version }
    }

    /// `item` moved through `change`, or nil when a step's range is gone.
    private func mapped(_ item: Pending, through change: Change) -> Pending? {
        var item = item
        let bias = item.transaction.origin.insertBias
        for index in item.transaction.steps.indices {
            guard let span = change.map(item.transaction.steps[index].span, bias: bias) else { return nil }
            item.transaction.steps[index].span = span
        }
        if case .position(let p) = item.caret { item.caret = .position(change.map(position: p, bias: bias)) }
        return item
    }

    /// `item` moved through `landed`, or nil after handing it back: superseded by the same owner's own automatic
    /// edit, out of window past a window edge, otherwise an overlap conflict (with a note when the user caused it).
    private mutating func rebase(_ item: Pending, through landed: Landed) -> Pending? {
        if let moved = mapped(item, through: landed.change) { return moved }
        let id = item.transaction.id
        switch landed.change {
        case .edges:
            conflict(id, Conflict(.outOfWindow))
        case .step(let step):
            if !landed.byUser, let owner = landed.owner, owner == item.transaction.owner, let by = landed.transaction {
                supersede(id, by: by)
            } else {
                conflict(id, Conflict(.overlap, intervening: step, byUser: landed.byUser))
            }
        }
        return nil
    }

    private mutating func conflict(_ id: UUID, _ conflict: Conflict) {
        events.append(.conflict(id, conflict))
        feed.append(.conflict(id, conflict))
    }

    private mutating func supersede(_ id: UUID, by newer: UUID) {
        events.append(.superseded(id, by: newer))
        feed.append(.superseded(id, by: newer))
    }

    // MARK: Transaction carets

    /// `caret` (in the field after `steps`, sorted by location) as an anchor that survives mapping.
    private static func anchor(_ caret: Int, in steps: [EditStep]) -> CaretAnchor {
        var shift = 0
        for (index, step) in steps.enumerated() {
            let start = step.span.location + shift
            if caret < start { break }
            if caret <= start + step.text.utf16.count { return .inStep(index, offset: caret - start) }
            shift += StepMap(step).delta
        }
        return .position(caret - shift)
    }

    /// The caret in the field after `steps` (sorted by location).
    private static func resolve(_ anchor: CaretAnchor, steps: [EditStep]) -> Int {
        switch anchor {
        case .inStep(let index, let offset):
            steps[..<index].reduce(steps[index].span.location + offset) { $0 + StepMap($1).delta }
        case .position(let p):
            steps.reversed().reduce(p) { StepMap($1).map(position: $0, bias: .before) }
        }
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
