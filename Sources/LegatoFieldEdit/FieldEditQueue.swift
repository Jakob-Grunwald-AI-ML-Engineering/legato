import Foundation

/// What a host read did to the issued writes (``FieldEditQueue/settle(_:final:tolerateStale:)``).
public enum SettleOutcome: Sendable, Hashable {
    /// Every issued write shows in the field.
    case confirmed
    /// At least one write (or one step of a multi-step write) did not land: only what is missing failed
    /// (`verifyFailed`) and was rolled back; what landed is confirmed.
    case diverged
    /// Only with `final: false`: the read shows only the oldest writes, a write still in progress (an
    /// intermediate state of its op sequence) or nothing any prediction explains. Writes it fully shows are
    /// confirmed; nothing else changed, the rest wait for the next read.
    case notYet
    /// Only with `final` and `tolerateStale`: the read is identical to the field before some issued writes (the
    /// host may not have caught up). Writes it shows are confirmed; the rest neither failed nor rolled back.
    case stale
}

/// The serial, position-mapped edit queue over one field (pure value type; the owner drives it on one thread).
///
/// Sources ``submit(_:lane:)`` transactions (and may ``withdraw(_:)`` them while pending); the executor takes one
/// ``FieldWrite`` at a time from ``next()`` (``next(lanes:)`` to hold lanes, ``next(for:)`` for one transaction,
/// ``peek(lanes:)`` to look first), runs it and hands the next host read to ``settle(_:final:tolerateStale:)``
/// (or ``abort(_:requeue:reason:)`` when it did not run it); host updates the queue did not cause go to
/// ``observe(_:)``. Every landed step moves the pending edits
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
    private enum CaretAnchor: Sendable, Hashable {
        case inStep(Int, offset: Int)
        case position(Int)
    }

    private struct Pending: Sendable, Hashable {
        var transaction: EditTransaction  // steps mapped to `document.version`, sorted by location
        var lane: Lane
        var caret: CaretAnchor?
    }

    /// A change positions are mapped through.
    private enum Change: Sendable, Equatable {
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
    private var unverified: [Unverified] = [] {
        didSet { if unverified.isEmpty { contradicted = false } }  // nothing left to contradict
    }
    /// Every change landed since `floor`, own or foreign, for mapping stale submissions.
    private var history: [Landed] = []
    /// The oldest version edits may be based on (the last reset or pruning point).
    private var floor: FieldVersion
    /// The newest version number handed out.
    private var lastVersion: Int
    private var events: [QueueEvent] = []
    /// Taints set since the last ``takeTaints()``.
    private var taints: [TaintNote] = []
    private var affinities: [Affinity] = []
    /// The last settle left the prediction contradicted (``needsFinalSettle``).
    private var contradicted = false

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

    /// Whether the last host read contradicted the prediction without deciding (a non-final read nothing
    /// explains, or one two outcomes fit): only the user lane is issued (keystrokes are never held), on the
    /// prediction, as more unverified writes the next read is settled against; the other lanes wait until a
    /// settle resolves it. The executor settles again: the next host read, or a `final` one at its timeout.
    public var needsFinalSettle: Bool { contradicted && !unverified.isEmpty }

    /// Records recognized text streamed into the run (Mac), in order with the field's own events.
    public mutating func appendASR(_ delta: String) { feed.append(.asrDelta(delta)) }

    /// The taints since the last call, oldest first, with why each was set (diagnostics).
    public mutating func takeTaints() -> [TaintNote] {
        defer { taints = [] }
        return taints
    }

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
    /// handed back on the way. While issued writes await a host read (also while ``needsFinalSettle``) only the
    /// user lane runs; the rest wait.
    public mutating func next() -> FieldWrite? { next(lanes: Set(Lane.allCases)) }

    /// ``next()`` among `lanes` only: edits in the other lanes are held (neither issued nor checked, so no version
    /// is used and nothing conflicts), e.g. the cleanup lane while the user is typing.
    public mutating func next(lanes: Set<Lane>) -> FieldWrite? {
        while let index = nextIndex(lanes: lanes) {
            let item = pending.remove(at: index)
            if let reason = check(item.transaction) {
                conflict(item.transaction.id, Conflict(reason, byUser: reason == .ownerTainted))
                continue
            }
            return issue(item)
        }
        return nil
    }

    /// What ``next(lanes:)`` would issue now, without issuing it: the queue is unchanged. Edits that would fail a
    /// guard on the way are skipped here and handed back by the next ``next(lanes:)``.
    public func peek(lanes: Set<Lane> = Set(Lane.allCases)) -> FieldWrite? {
        var copy = self
        return copy.next(lanes: lanes)
    }

    /// Issues the pending transaction `id` now, whatever its lane, ahead of every other edit and even while other
    /// writes await a host read (one read settles them all); the other edits stay queued untouched. Nil when `id`
    /// is not pending, while ``needsFinalSettle`` unless it is in the user lane, or when it fails a guard (then
    /// it is handed back).
    public mutating func next(for id: UUID) -> FieldWrite? {
        guard let index = pending.firstIndex(where: { $0.transaction.id == id }),
            !needsFinalSettle || pending[index].lane == .user
        else { return nil }
        let item = pending.remove(at: index)
        if let reason = check(item.transaction) {
            conflict(id, Conflict(reason, byUser: reason == .ownerTainted))
            return nil
        }
        return issue(item)
    }

    /// Cancels the pending transaction `id`: it is never written, and its source gets `withdrawn` (event and
    /// feed). False when `id` is not pending (unknown, already handed back, or issued: an issued write is the
    /// executor's to ``abort(_:requeue:reason:)``).
    @discardableResult
    public mutating func withdraw(_ id: UUID) -> Bool {
        guard let index = pending.firstIndex(where: { $0.transaction.id == id }) else { return false }
        pending.remove(at: index)
        dropAffinities(of: id)
        events.append(.withdrawn(id))
        feed.append(.withdrawn(id))
        return true
    }

    private func nextIndex(lanes: Set<Lane>) -> Int? {
        // Unverified writes (always there while `needsFinalSettle`) hold every lane but the user's.
        let eligible = pending.indices.filter {
            lanes.contains(pending[$0].lane) && (unverified.isEmpty || pending[$0].lane == .user)
        }
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
            if !transaction.origin.isUser, document.tainted.contains(where: { Self.blocks(step, of: transaction.origin, $0) }) {
                return .ownerTainted
            }
        }
        return nil
    }

    /// Whether tainted text refuses an automatic step. The run's own stream (ASR, Hold) only when the step rewrites
    /// text the user wrote or changed: an insertion, or a change next to where the user deleted (a zero-length
    /// taint), takes nothing of theirs, and refusing it would refuse every later chunk at the caret. Other origins
    /// (cleanup, the agent) stay off everything the user touched, its edges included.
    private static func blocks(_ step: EditStep, of origin: EditOrigin, _ taint: Span) -> Bool {
        guard origin == .asr || origin == .hold else { return touches(step.span, taint) }
        guard !step.span.isEmpty else { return false }
        if taint.isEmpty { return step.span.location < taint.location && taint.location < step.span.end }
        return step.span.location < taint.end && taint.location < step.span.end
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
    /// Writes the read does not show: a read that is exactly a subset of them (one in the middle missing, or
    /// some steps of a multi-step write) confirms what landed and fails only what is missing (see
    /// `settleBySubset`; a write landed in part is split: `applied` with its landed steps, then `verifyFailed`
    /// for the rest). Otherwise, with `final` (the Mac's synchronous readback, or the last read before a
    /// timeout) they fail with `verifyFailed` and are rolled back by inverting their steps; without it, a read
    /// that only lags (shows the oldest writes or none, with no foreign change) returns `notYet` and they wait.
    /// A final read consistent with no prediction fails them all and is then observed against the confirmed field.
    ///
    /// Reads before the final one (`final: false`; the iOS proxy updates its context asynchronously and may show
    /// any state between the ops of a write): a read byte-identical to an intermediate state of an issued write's
    /// op sequence (see `inProgress`) confirms the writes before it and returns `notYet`, never a foreign change;
    /// one that matches an intermediate state only with the window's edges moved confirms nothing and returns
    /// `notYet`. A read a prediction plus a foreign change explains is settled as a final one would be (writes
    /// shown confirmed, the foreign change recorded). A read nothing explains returns `notYet`, changes nothing
    /// and holds issuing outside the user lane (``needsFinalSettle``) until a settle resolves it.
    ///
    /// Liveness: a non-final read never fails a write it does not explain. Executors MUST settle with `final`
    /// at their timeout; until then unexplained writes stay unverified and, after an unexplained read, only the
    /// user lane is issued.
    ///
    /// Stale reads (`tolerateStale`, with `final`): a read identical to the field before some issued writes
    /// confirms the writes it shows and returns `stale`; the rest neither fail nor roll back. Recommended
    /// executor policy: on the first `stale`, extend the wait once (one more host update, or the timeout once
    /// more) and settle that read with `tolerateStale: false`; a read that is still stale then fails as usual.
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
    public mutating func settle(_ snapshot: FieldSnapshot, final: Bool = true, tolerateStale: Bool = false) -> SettleOutcome {
        let stale = final && tolerateStale && !windowBaseMoved(snapshot) && !byteEqual(document.window, snapshot.window)
            && unverified.contains { byteEqual($0.before.window, snapshot.window) }
        let outcome = settleRead(snapshot, final: final && !stale)
        return stale && outcome == .notYet ? .stale : outcome
    }

    private mutating func settleRead(_ snapshot: FieldSnapshot, final: Bool) -> SettleOutcome {
        contradicted = false
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

        // A write in progress: a byte-identical intermediate state shows the writes before it and confirms them.
        // An edge-shifted one (only where nothing else explains the read) hides part of the field: it waits,
        // confirming nothing.
        if !final, !explanations.contains(where: { $0.alignment == nil }) {
            if let j = inProgress(snapshot, edges: false) {
                confirm(min(j, explanations.map(\.k).min() ?? j))  // only what every explanation shows
                return .notYet
            }
            if explanations.isEmpty, inProgress(snapshot, edges: true) != nil { return .notYet }
        }

        let full = explanations.first.map { $0.k == predictions.count - 1 && $0.alignment == nil } ?? false
        var notes = SubsetNotes()
        if !full, !windowBaseMoved(snapshot),
            let outcome = settleBySubset(snapshot, prefixes: explanations, final: final, notes: &notes)
        {
            if outcome == .notYet { contradicted = true }
            return outcome
        }
        guard let choice = explanations.first else {
            if !final {
                contradicted = true
                return .notYet
            }
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
        if notes.typingLooksWritten, let step = choice.alignment?.step {
            // The user's text could also be a write's: it is theirs, and no automatic edit touches it.
            let span = Span(location: step.span.location, length: step.text.utf16.count)
            document.tainted.append(span)
            taints.append(TaintNote(source: .typingLooksWritten, span: span))
        }
        if notes.guessedHistory { forgetHistory() }
        return choice.k == predictions.count - 1 ? .confirmed : .diverged
    }

    /// What ``settleBySubset(_:prefixes:final:notes:)`` found when it left the decision to the prefix explanations.
    private struct SubsetNotes {
        /// A subset of the writes' steps also explains the read, as the same text a typing explanation adds.
        var typingLooksWritten = false
        /// Tied explanations leave the same field through different steps: the history is a guess.
        var guessedHistory = false
    }

    /// Drops the history up to the confirmed field: edits based before it are out of window, never mapped
    /// through steps the queue only guessed.
    private mutating func forgetHistory() {
        guard unverified.isEmpty else { return }
        history = []
        floor = document.version
    }

    /// Per-write attribution: one write that did not land never fails the writes after it. The read is matched
    /// byte for byte against every non-prefix subset of the issued writes' steps (one bit per step while there are
    /// at most 8, else per write: the others rolled back by inversion, the later ones replayed through that). The
    /// largest subset (in steps) that matches wins if it is larger than every prefix explanation without a
    /// foreign change: its writes are confirmed (replayed with new versions), only the others fail
    /// (`verifyFailed`); a write landed in part is confirmed with its landed steps and then fails for the rest.
    /// Tied subsets (or a tied prefix) that leave the same field and the same pending edits are one outcome, and
    /// the earliest writes (and lowest steps) are confirmed (a doubled letter: either copy failed); a real tie
    /// waits (`notYet`), or resets when `final`. Before the final read, the writes after the last one the read
    /// shows are not failed: they are reissued against the confirmed field and wait. Tied outcomes reached through different steps leave a guessed
    /// history: it is dropped (``SubsetNotes/guessedHistory``), so edits based before the read come back
    /// `outOfWindow` instead of being mapped through a step that may not have landed. A subset in which an owned
    /// automatic write wrote the text a typing explanation adds at the read's caret never wins: the typing
    /// explanation stands and its text is tainted (``SubsetNotes/typingLooksWritten``). A lagging read before
    /// the final one (a prefix explains it) waits without searching. Nil: no subset beats the prefix
    /// explanations. Pending edits inside a rolled-back write's text are handed back on the way.
    private mutating func settleBySubset(
        _ snapshot: FieldSnapshot, prefixes: [(k: Int, alignment: Alignment?)], final: Bool, notes: inout SubsetNotes
    ) -> SettleOutcome? {
        let sizes = unverified.map(\.write.steps.count)
        let units = sizes.reduce(0, +)
        // Each bit lands these steps (indices into a write's steps sorted by location).
        let groups: [(write: Int, steps: [Int])]
        if units > 1, units <= 8 {
            groups = sizes.indices.flatMap { w in (0..<sizes[w]).map { (write: w, steps: [$0]) } }
        } else if sizes.count > 1, sizes.count <= 8 {
            groups = sizes.indices.map { (write: $0, steps: Array(0..<sizes[$0])) }
        } else {
            return nil
        }
        let prefix = prefixes.filter { $0.alignment?.step == nil }.map(\.k).max() ?? -1
        if !final, prefix >= 0 { return nil }
        let prefixSize = prefix < 0 ? -1 : sizes[..<prefix].reduce(0, +)
        var best: [(landed: [[Bool]], queue: FieldEditQueue)] = []
        var bestSize = 0
        for bits in 1..<(1 << groups.count) {
            var landed = sizes.map { [Bool](repeating: false, count: $0) }
            for (bit, group) in groups.enumerated() where bits & (1 << bit) != 0 {
                for step in group.steps { landed[group.write][step] = true }
            }
            guard !Self.isPrefix(landed) else { continue }
            let size = landed.joined().filter { $0 }.count
            // Before the final read, the writes after the last one shown may not have run yet: they wait.
            let hold = final ? nil : (landed.lastIndex { $0.contains(true) } ?? -1) + 1
            guard size >= bestSize, let replayed = simulate(landed, holdFrom: hold),
                byteEqual(replayed.document.window, snapshot.window)
            else { continue }
            if size > bestSize { (best, bestSize) = ([], size) }
            best.append((landed, replayed))
        }
        guard !best.isEmpty, prefixSize <= bestSize else { return nil }
        if best.contains(where: { claimsTyping($0.queue, prefixes, snapshot) }) {
            notes.typingLooksWritten = true
            return nil
        }
        // Earliest writes and steps first: [true, false, true] before [false, true, true].
        best.sort { a, b in
            zip(a.landed.joined(), b.landed.joined()).first(where: { $0 != $1 }).map { $0.0 } ?? false
        }
        if prefixSize == bestSize {
            let landed = sizes.indices.map { [Bool](repeating: $0 < prefix, count: sizes[$0]) }
            guard let replayed = simulate(landed, holdFrom: nil) else { return nil }
            best.insert((landed, replayed), at: 0)
        }
        let winner = best[0]
        guard best.dropFirst().allSatisfy({ Self.sameOutcome($0.queue, winner.queue) }) else {
            if !final { return .notYet }
            reset(snapshot, reason: .unaligned)
            return .diverged
        }
        notes.guessedHistory = best.dropFirst().contains { $0.queue.history.map(\.change) != winner.queue.history.map(\.change) }
        if prefixSize == bestSize { return nil }  // the prefix explanation stands
        let issued = unverified
        let held = final ? issued.count : (winner.landed.lastIndex { $0.contains(true) } ?? -1) + 1
        self = winner.queue
        for (index, item) in issued.enumerated() where index < held {
            let mask = winner.landed[index]
            guard mask.contains(true), let write = unverified.first(where: { $0.write.id == item.write.id })?.write else {
                conflict(item.write.id, Conflict(.verifyFailed))
                continue
            }
            events.append(.applied(write.id, version: write.version))
            feed.append(.applied(write.id, origin: write.origin, steps: write.steps, version: write.version))
            if mask.contains(false) { conflict(write.id, Conflict(.verifyFailed)) }
        }
        unverified = []
        document.caret = snapshot.caret
        if notes.guessedHistory { forgetHistory() }
        for item in issued[held...] {
            guard let index = pending.firstIndex(where: { $0.transaction.id == item.write.id }) else { continue }
            let waiting = pending.remove(at: index)
            if let reason = check(waiting.transaction) {
                conflict(waiting.transaction.id, Conflict(reason, byUser: reason == .ownerTainted))
                continue
            }
            _ = issue(waiting)
        }
        return .diverged
    }

    /// Whether `replayed` (a subset replay) has an automatic, owned write claim text a typing explanation in
    /// `prefixes` adds: the typed text ends at the read's caret (where typing leaves it) and lies inside what
    /// a write at or after that explanation's prediction wrote. Then the text may be the user's.
    private func claimsTyping(
        _ replayed: FieldEditQueue, _ prefixes: [(k: Int, alignment: Alignment?)], _ snapshot: FieldSnapshot
    ) -> Bool {
        let written = replayed.writtenSpans().filter { $0.write.owner != nil && !$0.write.origin.isUser }
        return prefixes.contains { k, alignment in
            guard let step = alignment?.step else { return false }
            let typed = Span(location: step.span.location, length: step.text.utf16.count)
            guard typed.end == snapshot.caret else { return false }
            let later = Set(unverified[k...].map(\.write.id))
            return written.contains { entry in
                later.contains(entry.write.id) && entry.span.location <= typed.location && typed.end <= entry.span.end
            }
        }
    }

    /// The text each issued write wrote, in the document's offsets.
    private func writtenSpans() -> [(write: FieldWrite, span: Span)] {
        var spans: [(write: FieldWrite, span: Span)] = []
        for item in unverified {
            for step in item.write.steps {
                let map = StepMap(step)
                spans = spans.compactMap { entry in map.adjust(entry.span).map { (entry.write, $0) } }
                spans.append((item.write, Span(location: step.span.location, length: map.insertedLength)))
            }
        }
        return spans
    }

    /// Whether `landed` (per issued write, per step) is the oldest writes landed whole and the rest not at all.
    private static func isPrefix(_ landed: [[Bool]]) -> Bool {
        guard let gap = landed.firstIndex(where: { $0.contains(false) }) else { return true }
        return landed[gap...].allSatisfy { !$0.contains(true) }
    }

    /// Whether two replays leave the same field, spans and pending edits (versions aside).
    private static func sameOutcome(_ a: FieldEditQueue, _ b: FieldEditQueue) -> Bool {
        byteEqual(a.document.window, b.document.window) && a.document.caret == b.document.caret
            && a.document.owned == b.document.owned && a.document.tainted == b.document.tainted
            && a.pending == b.pending
    }

    /// This queue as if only the issued steps marked in `landed` (per write, per step sorted by location) reached
    /// the field; a write landed in part replays as its landed steps. Nil when a replayed write no longer fits
    /// (its range is gone or a guard fails).
    /// With `holdFrom`, the writes from that index on that landed nothing stay queued (front of their lane) instead
    /// of failing.
    private func simulate(_ landed: [[Bool]], holdFrom: Int?) -> FieldEditQueue? {
        var copy = self
        guard let first = landed.firstIndex(where: { $0.contains(false) }) else { return copy }
        let ids = copy.unverified[first...].map(\.write.id)
        copy.rollBack(from: first, requeueFirst: true, requeueRest: true, reason: .verifyFailed)
        for (offset, id) in ids.enumerated() {
            let mask = landed[first + offset]
            if let holdFrom, first + offset >= holdFrom { continue }
            guard let index = copy.pending.firstIndex(where: { $0.transaction.id == id }) else { return nil }
            var item = copy.pending.remove(at: index)
            guard mask.contains(true) else {
                copy.dropAffinities(of: id)
                continue
            }
            if mask.contains(false) {
                item.transaction.steps = zip(item.transaction.steps, mask).filter(\.1).map(\.0)
                item.caret = nil
            }
            guard copy.check(item.transaction) == nil else { return nil }
            _ = copy.issue(item)
        }
        return copy
    }

    /// The oldest issued write the read shows in progress: an intermediate state of its op sequence as the iOS
    /// proxy runs it, step by step in application order (the caret moved to the step's end, its text deleted
    /// Character by Character, the new text inserted), excluding the host reads before and after the write. The
    /// writes before it are fully shown. Matched byte for byte or, with `edges`, with the caret-relative
    /// window's edges moved.
    private func inProgress(_ snapshot: FieldSnapshot, edges: Bool) -> Int? {
        for (j, item) in unverified.enumerated() {
            let start = item.before
            let end = j + 1 < unverified.count ? unverified[j + 1].before : document
            var window = start.window
            var states: [(window: String, caret: Int)] = []
            for step in item.write.steps {
                states.append((window, step.span.end))
                var kept = step.expect
                while !kept.isEmpty {
                    kept.removeLast()
                    states.append((window.replacing(step.span, with: kept), step.span.location + kept.utf16.count))
                }
                window = window.replacing(step.span, with: step.text)
                states.append((window, step.span.location + step.text.utf16.count))
            }
            for state in states {
                let isBoundary = [start, end].contains { byteEqual($0.window, state.window) && $0.caret == state.caret }
                guard !isBoundary else { continue }
                if edges {
                    let shadow = ShadowDocument(window: state.window, windowBase: start.windowBase, caret: state.caret)
                    if plausibleEdge(shadow, snapshot), alignments(shadow, snapshot).edges != nil { return j }
                } else if byteEqual(state.window, snapshot.window) {
                    return j
                }
            }
        }
        return nil
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
            taints.append(TaintNote(source: .userEdit, span: written))
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

/// Why owned text was tainted (``FieldEditQueue/takeTaints()``).
public struct TaintNote: Sendable, Hashable {
    public enum Source: String, Sendable, Hashable {
        /// A user (`byUser`) step changed owned text.
        case userEdit
        /// A read that a write of ours or the user's typing explains: taken as the user's typing.
        case typingLooksWritten
    }
    public var source: Source
    public var span: Span
    public init(source: Source, span: Span) {
        self.source = source
        self.span = span
    }
}
