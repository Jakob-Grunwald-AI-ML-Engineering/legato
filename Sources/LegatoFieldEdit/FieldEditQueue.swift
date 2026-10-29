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
        /// Which step of `transaction` this is (index into its steps sorted by location).
        var step: StepKey? = nil
    }

    /// One step of a transaction: its index in the transaction's steps, sorted by location.
    private struct StepKey: Sendable, Hashable {
        var transaction: UUID
        var index: Int
    }

    /// An insertion point of a pending edit: one of its zero-length steps, or its caret.
    private enum Target: Sendable, Hashable {
        case step(Int)
        case caret
    }

    /// A pending insertion point that sat at an edge of a requeued step's text when that step was rolled back.
    /// The rollback collapses both edges onto one position; this keeps the point on its `side` of the step's text
    /// when the step replays (or the step on the other side when the point lands first), and moves the point with
    /// the step through anything landing there in between. Dropped once either lands or leaves the queue.
    private struct Affinity: Sendable {
        var anchor: StepKey
        var follower: UUID
        var target: Target
        var side: Bias
        var anchorBias: Bias
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
    private var affinities: [Affinity] = []

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
        for (offset, step) in ordered.enumerated() {
            caret = StepMap(step).map(position: caret, bias: caretBias)
            land(
                step, transaction: transaction.id, owner: transaction.owner, byUser: transaction.origin.isUser,
                key: StepKey(transaction: transaction.id, index: ordered.count - 1 - offset))
        }
        dropAffinities(of: transaction.id)
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
    /// Writes the read does not show: a read that is exactly a subset of them (one in the middle missing) fails
    /// only the missing ones (see `settleBySubset`). Otherwise, with `final` (the Mac's synchronous readback, or the last read before a
    /// timeout) they fail with `verifyFailed` and are rolled back by inverting their steps; without it, a read
    /// that only lags (shows the oldest writes or none, with no foreign change) returns `notYet` and they wait.
    /// A read consistent with no prediction fails them all and is then observed against the confirmed field.
    ///
    /// Ambiguous reads (iOS): the queue never guesses where its offsets went. An edge shift only counts as an
    /// alternative with text before the caret in both the prediction and the read.
    /// - A read byte-identical to an older prediction that is also a newer one with a moved edge (a lagging read,
    ///   or a landed write plus an edge shift) confirms the writes up to the older one and returns `notYet`; with
    ///   `final` the rest fail (`verifyFailed`) and the queue resets (`unaligned`; pending edits `outOfWindow`).
    /// - A read byte-identical to the newest prediction confirms every write, whatever older predictions fit.
    /// - Otherwise, a read that two explanations fit (typing and an edge shift, or edge shifts at two predictions)
    ///   confirms the writes that landed under both and resets: a wrong edge shift would move owned and pending
    ///   spans onto the user's text untainted, wrong typing would leave them on other text.
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

        // Every way the read follows from a prediction; the first is the preferred one.
        var explanations: [(k: Int, alignment: Alignment?)] = []
        let indices = Array(predictions.indices.reversed())
        if !windowBaseMoved(snapshot) {
            if let k = indices.first(where: { byteEqual(predictions[$0].window, snapshot.window) }) {
                explanations = [(k, nil)]
                for newer in indices where newer > k && plausibleEdge(predictions[newer], snapshot) {
                    if let edges = alignments(predictions[newer], snapshot).edges { explanations.append((newer, edges)) }
                }
            } else if !snapshot.window.isEmpty {
                let candidates = indices.map { (k: $0, alignments: alignments(predictions[$0], snapshot)) }
                let edges = candidates.compactMap { candidate in
                    candidate.alignments.edges.map { (k: candidate.k, alignment: Optional($0)) }
                }
                let typed = candidates.compactMap { candidate -> (k: Int, alignment: Alignment?)? in
                    guard let typing = candidate.alignments.typing, let step = typing.step,
                        !written[candidate.k].contains(where: { touches(step.span, $0) })
                    else { return nil }
                    return (candidate.k, typing)
                }
                // The newest typing explanation stands for typing: an older one means the user typed our text.
                explanations = edges.filter { plausibleEdge(predictions[$0.k], snapshot) } + typed.prefix(1)
                if explanations.isEmpty, let edge = edges.first { explanations = [edge] }
            }
        }

        let full = explanations.first.map { $0.k == predictions.count - 1 && $0.alignment == nil } ?? false
        if !full, !windowBaseMoved(snapshot), let outcome = settleBySubset(snapshot, prefixes: explanations, final: final) {
            return outcome
        }
        guard let choice = explanations.first else {
            rollBack(from: 0, requeueFirst: false, requeueRest: false, reason: .verifyFailed)
            observe(snapshot)
            return .diverged
        }
        if explanations.count > 1 {
            // Ambiguous: confirm only what landed under every explanation; wait while every one only lags or
            // moves an edge, otherwise start over from the read.
            confirm(explanations.map(\.k).min() ?? 0)
            if !final, !unverified.isEmpty, explanations.allSatisfy({ $0.alignment?.step == nil }) { return .notYet }
            let all = unverified.isEmpty
            reset(snapshot, reason: .unaligned)
            return all ? .confirmed : .diverged
        }
        confirm(choice.k)
        if !unverified.isEmpty {
            if !final, choice.alignment?.step == nil { return .notYet }
            rollBack(from: 0, requeueFirst: false, requeueRest: false, reason: .verifyFailed)
        }
        apply(choice.alignment, snapshot)
        return choice.k == predictions.count - 1 ? .confirmed : .diverged
    }

    /// Per-write attribution: one write that did not land never fails the writes after it. The read is matched
    /// byte for byte against every non-prefix subset of the issued writes (the others rolled back by inversion,
    /// the later ones replayed through that). The largest subset that matches wins if it is larger than every
    /// prefix explanation without a foreign change: its writes are confirmed (replayed with new versions), only
    /// the others fail (`verifyFailed`). A tie waits (`notYet`), or resets when `final`. Nil: no subset beats the
    /// prefix explanations. Pending edits inside a rolled-back write's text are handed back on the way.
    private mutating func settleBySubset(
        _ snapshot: FieldSnapshot, prefixes: [(k: Int, alignment: Alignment?)], final: Bool
    ) -> SettleOutcome? {
        let count = unverified.count
        guard count > 1, count <= 8 else { return nil }
        var best: [(landed: [Bool], queue: FieldEditQueue)] = []
        var bestSize = 0
        for bits in 1..<(1 << count) {
            let landed = (0..<count).map { bits & (1 << $0) != 0 }
            guard let gap = landed.firstIndex(of: false), landed[gap...].contains(true) else { continue }  // a prefix
            let size = landed.filter { $0 }.count
            guard size >= bestSize, let replayed = simulate(landed),
                byteEqual(replayed.document.window, snapshot.window)
            else { continue }
            if size > bestSize { (best, bestSize) = ([], size) }
            best.append((landed, replayed))
        }
        guard let winner = best.first else { return nil }
        let prefix = prefixes.filter { $0.alignment?.step == nil }.map(\.k).max() ?? -1
        if prefix > bestSize { return nil }
        if best.count > 1 || prefix == bestSize {
            if !final { return .notYet }
            reset(snapshot, reason: .unaligned)
            return .diverged
        }
        let issued = unverified
        self = winner.queue
        for (index, item) in issued.enumerated() {
            guard winner.landed[index], let write = unverified.first(where: { $0.write.id == item.write.id })?.write else {
                conflict(item.write.id, Conflict(.verifyFailed))
                continue
            }
            events.append(.applied(write.id, version: write.version))
            feed.append(.applied(write.id, origin: write.origin, steps: write.steps, version: write.version))
        }
        unverified = []
        document.caret = snapshot.caret
        return .diverged
    }

    /// This queue as if only the issued writes marked in `landed` reached the field; nil when a replayed write
    /// no longer fits (its range is gone or a guard fails).
    private func simulate(_ landed: [Bool]) -> FieldEditQueue? {
        var copy = self
        guard let first = landed.firstIndex(of: false) else { return copy }
        let ids = copy.unverified[first...].map(\.write.id)
        copy.rollBack(from: first, requeueFirst: true, requeueRest: true, reason: .verifyFailed)
        for (offset, id) in ids.enumerated() {
            guard let index = copy.pending.firstIndex(where: { $0.transaction.id == id }) else { return nil }
            let item = copy.pending.remove(at: index)
            if landed[first + offset] {
                guard copy.check(item.transaction) == nil else { return nil }
                _ = copy.issue(item)
            } else {
                copy.dropAffinities(of: id)
            }
        }
        return copy
    }

    /// Confirms the oldest `count` issued writes (`applied`).
    private mutating func confirm(_ count: Int) {
        for item in unverified[..<count] {
            events.append(.applied(item.write.id, version: item.write.version))
            feed.append(.applied(item.write.id, origin: item.write.origin, steps: item.write.steps, version: item.write.version))
        }
        unverified.removeFirst(count)
    }

    /// A host update the queue did not write. The same window is a caret-only move (offsets re-based exactly, no
    /// text search). Otherwise the read is aligned at the caret: on the Mac (absolute window) any change becomes
    /// one foreign `byUser` step, its common prefix capped at the lower caret; on iOS a change at the caret
    /// (typing, deleting, pasting: the text before the caret changed at its end, the text after it only at its far
    /// edge) is a foreign step, and a read that only moved the window's edges is a re-base that taints nothing.
    /// Anything else is not alignable and resets; so does an emptied field. A change that is both (e.g. "aa" → "a":
    /// a delete at the caret or the left edge moving by one, with text before the caret on both sides) resets
    /// too: either guess puts pending edits before the caret one place off when wrong. While writes await
    /// verification this settles them first (`final`).
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
        if candidates.typing != nil, candidates.edges != nil, plausibleEdge(document, snapshot) {
            return reset(snapshot, reason: .unaligned)
        }
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
        affinities = []
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

    /// Whether a moved left edge is a real alternative to typing: only with text before the caret on both sides
    /// (an empty before-context is the field's start, which no edge hides).
    private func plausibleEdge(_ document: ShadowDocument, _ read: FieldSnapshot) -> Bool {
        document.windowBase == nil && document.caret > 0 && read.caret > 0
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
    private mutating func land(
        _ step: EditStep, transaction: UUID?, owner: String?, byUser: Bool, key: StepKey? = nil
    ) {
        let map = StepMap(step)
        document.window = document.window.replacing(step.span, with: step.text)
        document.version = nextVersion()
        let landed = Landed(
            version: document.version, change: .step(step), transaction: transaction, owner: owner, byUser: byUser,
            step: key)
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
    ///
    /// Inverting a step collapses both edges of its text onto one position. For a step that is requeued, a
    /// pending insertion point at the start of its text stays before it and one at the end stays after it when
    /// it replays (``Affinity``): text typed after a requeued write is never written in front of it.
    private mutating func rollBack(from index: Int, requeueFirst: Bool, requeueRest: Bool, reason: Conflict.Reason) {
        let undone = Array(unverified[index...])
        guard let first = undone.first else { return }
        unverified.removeSubrange(index...)
        func requeues(_ offset: Int) -> Bool { offset == 0 ? requeueFirst : requeueRest }
        for (offset, item) in undone.enumerated() where !requeues(offset) {
            conflict(item.write.id, Conflict(reason))
        }
        for (offset, item) in undone.enumerated().reversed() {
            let requeued = requeues(offset)
            let anchorBias = item.item.transaction.origin.insertBias
            for (stepIndex, step) in item.write.steps.reversed().enumerated() {
                let start = step.span.location, end = start + step.text.utf16.count
                let inverse = EditStep(
                    span: Span(location: start, length: end - start), text: step.expect, expect: step.text)
                let anchor = StepKey(transaction: item.write.id, index: stepIndex)
                pending = pending.compactMap { waiting in
                    var sides: [Target: Bias] = [:]
                    if requeued, end > start {
                        for target in Self.insertionPoints(of: waiting) {
                            if target.position == start { sides[target.target] = .before }
                            if target.position == end { sides[target.target] = .after }
                        }
                        for (target, side) in sides {
                            affinities.removeAll { $0.anchor == anchor && $0.follower == waiting.transaction.id && $0.target == target }
                            affinities.append(
                                Affinity(anchor: anchor, follower: waiting.transaction.id, target: target, side: side,
                                    anchorBias: anchorBias))
                        }
                    }
                    if let moved = mapped(waiting, through: .step(inverse), bias: { sides[$0] }) { return moved }
                    conflict(waiting.transaction.id, Conflict(reason))
                    return nil
                }
            }
            if requeued { pending.insert(item.item, at: 0) }
        }
        document = first.before
        history.removeAll { $0.version > first.before.version }
    }

    /// `item` moved through `change`, or nil when a step's range is gone. An insertion point takes the side
    /// `bias` names for it, else its origin's.
    private func mapped(_ item: Pending, through change: Change, bias: (Target) -> Bias? = { _ in nil }) -> Pending? {
        var item = item
        let origin = item.transaction.origin.insertBias
        for index in item.transaction.steps.indices {
            let side = bias(.step(index)) ?? origin
            guard let span = change.map(item.transaction.steps[index].span, bias: side) else { return nil }
            item.transaction.steps[index].span = span
        }
        if case .position(let p) = item.caret {
            item.caret = .position(change.map(position: p, bias: bias(.caret) ?? origin))
        }
        return item
    }

    /// The zero-length steps and the position caret of `item`, where they are.
    private static func insertionPoints(of item: Pending) -> [(target: Target, position: Int)] {
        var points = item.transaction.steps.indices.compactMap { index -> (target: Target, position: Int)? in
            let span = item.transaction.steps[index].span
            return span.isEmpty ? (.step(index), span.location) : nil
        }
        if case .position(let p) = item.caret { points.append((.caret, p)) }
        return points
    }

    /// The side an insertion point of `item` takes at `landed` from the affinities (nil: its origin's): its
    /// recorded side of the anchor step landing; for an anchor step, the other side of a follower landing first;
    /// through anything else, the anchor's own bias, so the two stay together.
    private func affinityBias(_ item: Pending, _ target: Target, at landed: Landed) -> Bias? {
        let id = item.transaction.id
        if let key = landed.step {
            if let a = affinities.first(where: { $0.anchor == key && $0.follower == id && $0.target == target }) {
                return a.side
            }
            if case .step(let index) = target,
                let a = affinities.first(where: {
                    $0.anchor == StepKey(transaction: id, index: index) && $0.follower == key.transaction
                        && $0.target == .step(key.index)
                })
            {
                return a.side == .after ? .before : .after
            }
        }
        return affinities.first(where: { $0.follower == id && $0.target == target })?.anchorBias
    }

    private mutating func dropAffinities(of id: UUID) {
        affinities.removeAll { $0.anchor.transaction == id || $0.follower == id }
    }

    /// `item` moved through `landed`, or nil after handing it back: superseded by the same owner's own automatic
    /// edit, out of window past a window edge, otherwise an overlap conflict (with a note when the user caused it).
    private mutating func rebase(_ item: Pending, through landed: Landed) -> Pending? {
        if let moved = mapped(item, through: landed.change, bias: { affinityBias(item, $0, at: landed) }) {
            return moved
        }
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
        dropAffinities(of: id)
        events.append(.conflict(id, conflict))
        feed.append(.conflict(id, conflict))
    }

    private mutating func supersede(_ id: UUID, by newer: UUID) {
        dropAffinities(of: id)
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
