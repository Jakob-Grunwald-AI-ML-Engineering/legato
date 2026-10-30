import Foundation
import LegatoFieldEdit

/// The field the coordinator writes to: the text proxy's caret-relative window and its calls. The keyboard
/// extension backs it with `textDocumentProxy`, whose reads may lag the calls (they update asynchronously and
/// may show any state between the calls of one write); the DEBUG harness with a `UITextView`.
@MainActor
public protocol FieldEditDocument: AnyObject {
    /// Stable for one field (`documentIdentifier`).
    var documentID: String? { get }
    /// `documentContextBeforeInput`; empty when there is none.
    var contextBefore: String { get }
    /// `documentContextAfterInput`; empty when there is none.
    var contextAfter: String { get }
    /// Runs the queue's proxy calls (``ProxyOpCompiler``) in order, in this main-thread turn.
    func execute(_ calls: [ProxyCall])
}

/// The keyboard's field edit queue, for one keyboard appearance: every edit the
/// keyboard makes goes through one `FieldEditQueue` over the caret-relative window
/// (`documentContextBefore/AfterInput`) and is carried out by this type on the document.
///
/// - Sources submit transactions; a write runs as soon as the queue gives it out (`next`), its whole op
///   sequence (move, delete, insert, move back; `ProxyOpCompiler`) in this main-thread turn, so a keystroke
///   never lands between our caret move and our move back. User-lane edits (keys, the word row, undo and redo,
///   versions) run in the call that submits them; the ASR and cleanup lanes wait while a write awaits its read.
///   Keys run so even while a read contradicts the prediction (the queue issues the user lane then too); other
///   user edits are refused then, as they would be planned on a field that may not be the field.
/// - Verification: every read before the timeout is settled with `final: false` (right after a write, and on
///   every host update: `sync`). Such a read never fails a write and never records our own text as the user's:
///   a read nothing explains (an intermediate or partial proxy state) waits (`notYet`). `settleTimeout` after the
///   newest write the read is settled with `final: true, tolerateStale: true`; a read still showing the field from
///   before a write (`stale`: the host has not caught up), or one that still contradicts the prediction (nothing
///   explains it, e.g. a transient empty context), waits once more, and only that second final read may fail
///   what it does not show. A failed write is handed back once.
/// - Echoes: the coordinator knows every state its own calls take the field through (the field before them,
///   then after each move, each deleted Character, each insert). A read that is one of those states, other
///   than the last, is the host catching up with our calls, not news: it is not handed to the queue (matched in
///   order, earliest first, so a field that returns to an earlier text on the way, A → B → A, is not taken for
///   the end), and a timeout that finds one waits once more, as for a stale read. The last state, and any read
///   that is none of them, goes to the queue. So the caret the queue plans from is where our calls left it, and
///   our own intermediate text is never recorded as the user's.
/// - Outcomes go back to each source's handler: `.executed` once its ops ran, then `.applied`, `.conflict`,
///   `.superseded`, `.withdrawn`, or `.unconfirmed` when the keyboard went away before a read decided.
/// - A contradicted prediction is decided in bounded time: while a read contradicts it, the deadline its first
///   write set stands (keys arriving meanwhile do not push the final read back), so the unverified writes and the
///   settle stay bounded and the ASR and cleanup lanes are held for two timeouts at most.
/// - The feed (``publishFeed(to:minInterval:)``, the app's cleanup agent on iOS): at the end of a host update (or a
///   call from a source) the feed entries since the last batch go out as one `FeedBatch` with the confirmed
///   window, at most once per `minInterval` (outcomes of the app's edits and resets at once); the first is a
///   resync. While it publishes, the history the queue maps old bases through is kept for the batches of the last
///   ``linkedAge`` (and at least the newest ``linkedVersions``), so an edit based on the batch a long agent pass
///   began from still lands.
@MainActor
public final class FieldEditCoordinator {
    public enum Outcome: Equatable, Sendable {
        /// The write's proxy calls ran; the read that confirms it may still be due.
        case executed
        case applied
        case conflict(Conflict)
        case superseded
        /// Withdrawn while it waited: never written.
        case withdrawn
        /// It ran, but the keyboard went away before a read showed whether it landed: it may still land, so its
        /// source keeps it as done (nothing is retyped).
        case unconfirmed
    }

    /// What a submission did by the time the call returns.
    public enum Result: Equatable, Sendable {
        /// Its ops ran (it may still await its read).
        case done
        /// It waits in its lane (a write before it awaits its read).
        case waiting
        /// Handed back at once: nothing was written.
        case refused(Conflict)
        /// Nothing to write.
        case unchanged
    }

    /// Runs `action` once after `delay`; the returned closure cancels it.
    public typealias Schedule = @MainActor (Duration, @escaping @MainActor () -> Void) -> @MainActor () -> Void

    /// Sleeps on a main-actor task.
    public static let taskSchedule: Schedule = { delay, action in
        let task = Task { @MainActor in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            action()
        }
        return { task.cancel() }
    }

    /// Diagnostics (the DEBUG harness logs it); counts only, no user text.
    public var trace: ((String) -> Void)?

    /// How long after the newest write a final read decides (waited twice for a stale read).
    public let settleTimeout: Duration
    private let schedule: Schedule
    private let document: any FieldEditDocument
    private var queue: FieldEditQueue
    private var documentID: String?
    private var handlers: [UUID: (Outcome) -> Void] = [:]
    private var origins: [UUID: EditOrigin] = [:]
    /// Written, not yet confirmed or failed.
    private var issued: Set<UUID> = []
    private var executing = false
    /// The host reported a clear while our calls ran: taken once they returned.
    private var clearPending = false
    private var dispatching = false
    private var driveAgain = false
    private var cancelTimer: (() -> Void)?
    /// The timeout already waited once more for a stale read.
    private var extended = false
    private var closed = false
    /// The states our calls take the field through that no read has shown yet, oldest first (see the notes).
    private var echoes: [FieldSnapshot] = []
    /// The echo the newest read showed (the host may report it again before the next).
    private var lastEcho: FieldSnapshot?

    /// An owned automatic write's calls and the field they ran on (see ``Ghost``).
    private struct Ghost {
        var window: String
        var caret: Int
        var calls: [ProxyCall]
        /// The field after them.
        var end: FieldSnapshot
    }
    /// The owned automatic writes that ran and await their read.
    private var ran: [UUID: Ghost] = [:]
    /// Writes that ran, then failed for want of a read that may still come (the host lags past both waits),
    /// oldest first. The next write that would run the same calls on the same field is that write again (its
    /// source typing it once more): it is issued without running them, and its read settles both. A read showing
    /// one while nothing is issued is that write landing late: it is held back from the queue for the retype.
    private var ghosts: [Ghost] = []
    /// Retypes issued without their calls, by the ghost they stand for. When their own waits pass and the field
    /// still shows the field before them, the ghost was lost after all: the retype runs its calls then.
    private var adopted: [UUID: Ghost] = [:]
    /// A ghost whose retype ran its calls (or failed back to its source): if the ghost lands after all, the text
    /// is there twice. Only logged (`fe.duplicate`): the copies cannot be told apart from the user's text.
    private var spent: Ghost?
    /// The settle deadline stands while the prediction is contradicted (see the notes).
    private var contradictionDeadline = false

    /// Where the feed goes (``publishFeed(to:)``); nil: nobody reads it, it is kept short.
    private var feedSink: ((FeedBatch, String) -> Void)?
    /// The last feed entry published (nil: the next batch is a resync).
    private var publishedThrough: Int?
    /// The versions of the newest published batches, oldest first, with when each went out: the bases the app's
    /// edits may name.
    private var publishedVersions: [(version: FieldVersion, at: Duration)] = []
    /// The published batches' versions stay mappable for at least this long (an agent pass bases its edits on the
    /// batch it read when it began; a pass is bounded by its timeout, far below this)...
    public static let linkedAge: Duration = .seconds(30)
    /// ... and the newest this many of them, however old.
    public static let linkedVersions = 64
    /// The least time between two batches (``publishFeed(to:minInterval:)``); zero: one per host update.
    private var feedInterval: Duration = .zero
    /// The throttle's window since the last batch (its timer's cancel); nil: the next batch goes out at once.
    private var feedCooldown: (@MainActor () -> Void)?
    /// Entries wait for the window's end.
    private var feedWaiting = false
    private let now: @MainActor () -> Duration
    private static let epoch = ContinuousClock.now
    /// Time since the process started using the coordinator type (monotonic).
    public static let uptime: @MainActor () -> Duration = { epoch.duration(to: .now) }
    /// Nested entry points: the feed goes out when the outermost returns.
    private var depth = 0

    public init(
        document: any FieldEditDocument, settleTimeout: Duration = .milliseconds(250),
        schedule: @escaping Schedule = FieldEditCoordinator.taskSchedule,
        now: @escaping @MainActor () -> Duration = FieldEditCoordinator.uptime
    ) {
        self.document = document
        self.settleTimeout = settleTimeout
        self.schedule = schedule
        self.now = now
        documentID = document.documentID
        queue = FieldEditQueue(FieldSnapshot(before: document.contextBefore, after: document.contextAfter))
    }

    // MARK: State

    /// The field as predicted after every write that ran.
    public var predicted: ShadowDocument { queue.document }
    public var predictedBefore: String { split.before }
    public var predictedAfter: String { split.after }
    private var split: FieldSnapshot { FieldSnapshot(window: queue.document.window, caret: queue.document.caret) }

    /// An edit waits in its lane.
    public var hasPending: Bool { queue.hasPending }
    /// A write ran and its read has not confirmed it yet.
    public var awaitsVerification: Bool { !issued.isEmpty }

    private func read() -> FieldSnapshot { FieldSnapshot(before: document.contextBefore, after: document.contextAfter) }

    /// Whether `snapshot` is an echo of our own calls with more to come (it is then consumed, not news).
    private func isEcho(_ snapshot: FieldSnapshot) -> Bool {
        if let lastEcho, Self.same(lastEcho, snapshot) { return true }
        guard let index = echoes.firstIndex(where: { Self.same($0, snapshot) }) else {
            if let next = echoes.first {
                trace?("fe.read unmatched before=\(snapshot.before.utf16.count) after=\(snapshot.after.utf16.count) echoes=\(echoes.count) next=\(next.before.utf16.count)/\(next.after.utf16.count)")
            }
            return false
        }
        if index == echoes.count - 1 {
            forgetEchoes()  // the host shows everything we did
            return false
        }
        lastEcho = echoes[index]
        echoes.removeFirst(index + 1)
        return true
    }

    private func forgetEchoes() {
        echoes = []
        lastEcho = nil
    }

    private func forgetGhosts() {
        ghosts = []
        adopted = [:]
        spent = nil
    }

    /// The newest read is one of our own states with the text as predicted but the caret elsewhere: the host has
    /// not shown our closing caret move yet, or the user put the caret there; no read tells which. A patch planned
    /// on the predicted caret may then be planned on the wrong text.
    private var caretUncertain: Bool {
        guard let lastEcho, !echoes.isEmpty else { return false }
        let predicted = split
        return lastEcho.window.utf16.elementsEqual(predicted.window.utf16) && lastEcho.caret != predicted.caret
    }

    /// Whether the predicted field may not be the field: user patches planned on it are refused.
    private var predictionUncertain: Bool { queue.needsFinalSettle || caretUncertain }

    private static func same(_ a: FieldSnapshot, _ b: FieldSnapshot) -> Bool {
        a.before.utf16.elementsEqual(b.before.utf16) && a.after.utf16.elementsEqual(b.after.utf16)
    }

    /// The states `calls` take the field through from `window` with the caret at `caret`, one per call and one
    /// per deleted Character.
    private static func states(of calls: [ProxyCall], window: String, caret: Int) -> [FieldSnapshot] {
        var field = FieldSnapshot(window: window, caret: caret)
        var states: [FieldSnapshot] = []
        for call in calls {
            switch call {
            case .moveCaret(let units):
                field = FieldSnapshot(window: field.window, caret: min(max(field.caret + units, 0), field.window.utf16.count))
                states.append(field)
            case .deleteBackward(let count):
                for _ in 0..<count {
                    var head = field.before
                    if !head.isEmpty { head.removeLast() }
                    field = FieldSnapshot(before: head, after: field.after)
                    states.append(field)
                }
            case .insert(let text):
                field = FieldSnapshot(before: field.before + text, after: field.after)
                states.append(field)
            }
        }
        return states
    }

    // MARK: Host updates

    /// The field changed or was looked at again (`textDidChange`, `selectionDidChange`, before an edit): issued
    /// writes are settled against a fresh read (never final here), otherwise the read is observed; another
    /// field starts over.
    public func sync() {
        guard !executing, !closed else { return }
        enter()
        defer { leave() }
        let snapshot = read()
        if let spent, Self.same(Self.states(of: spent.calls, window: split.window, caret: queue.document.caret).last ?? split, snapshot) {
            trace?("fe.duplicate calls=\(spent.calls.count)")  // a write whose retype was typed landed late
            self.spent = nil
        }
        if document.documentID != documentID {
            documentID = document.documentID
            forgetEchoes()
            forgetGhosts()
            queue.reset(snapshot, reason: .focusChanged)
        } else if isEcho(snapshot) {
            trace?("fe.echo")  // the host is catching up with our own calls
            return
        } else if issued.isEmpty, lateGhost(snapshot) {
            trace?("fe.echo late=1")  // a failed write landing after all: its retype is not typed again
            return
        } else if issued.isEmpty {
            queue.observe(snapshot)
        } else {
            let outcome = queue.settle(snapshot, final: false)
            if outcome != .confirmed { trace?("fe.settle final=0 outcome=\(outcome)") }
        }
        dispatch()
        drive()
    }

    /// The keyboard goes away: a last read confirms what it shows; writes it does not show yet that may still
    /// land (the read is stale) are `unconfirmed`, and edits still waiting are handed back.
    public func close() {
        guard !closed else { return }
        enter()
        defer {
            leave()
            endCooldown()
            feedSink = nil
        }
        cancelTimer?()
        cancelTimer = nil
        let snapshot = read()
        if !issued.isEmpty, !isEcho(snapshot) {
            let outcome = queue.settle(snapshot, final: true, tolerateStale: true)
            trace?("fe.settle final=1 outcome=\(outcome) closing=1")
            dispatch()
        }
        if !issued.isEmpty {
            for id in issued {
                trace?("fe.outcome origin=\(origins[id]?.rawValue ?? "-") result=unconfirmed")
                finish(id, .unconfirmed)
            }
        }
        closed = true
        forgetEchoes()
        forgetGhosts()
        queue.reset(snapshot, reason: .focusChanged)
        dispatch()
        handlers = [:]
    }

    // MARK: Submitting

    /// Queues `transaction` (in `lane`, default its origin's) and runs what can run now.
    @discardableResult
    public func submit(_ transaction: EditTransaction, lane: Lane? = nil, onOutcome: ((Outcome) -> Void)? = nil) -> Result {
        guard !closed else { return .refused(Conflict(.focusLost)) }
        enter()
        defer { leave() }
        var first: Outcome?
        handlers[transaction.id] = { outcome in
            if first == nil { first = outcome }
            onOutcome?(outcome)
        }
        origins[transaction.id] = transaction.origin
        queue.submit(transaction, lane: lane)
        dispatch()
        drive()
        switch first {
        case .conflict(let conflict): return .refused(conflict)
        case .superseded, .withdrawn: return .refused(Conflict(.overlap))
        case .executed, .applied, .unconfirmed: return .done
        case nil:
            trace?("fe.queued origin=\(transaction.origin.rawValue)")
            return .waiting
        }
    }

    /// Cancels the waiting edit `id` (its handler gets `.withdrawn`); false when it is not waiting.
    @discardableResult
    public func withdraw(_ id: UUID) -> Bool {
        enter()
        defer { leave() }
        guard queue.withdraw(id) else { return false }
        dispatch()
        return true
    }

    /// A keystroke: `text` at the caret, in the user lane, typed in this call. Never held: also while the
    /// prediction is contradicted (a read nothing explains, e.g. the host sent and cleared the field before
    /// reporting our Return) the queue issues it on the prediction, as one more unverified write, so the reads
    /// after it are settled against it (an old read does not make the queue forget it, a later one does not take
    /// it for the user's typing). Its call (`insertText`) types at the real caret, whatever the prediction says.
    public func type(_ text: String) -> Result {
        enter()
        defer { leave() }
        sync()
        return keystroke([.insert(text, at: queue.document.caret)])
    }

    /// The delete key: the Character before the caret, as ``type(_:)``. `.unchanged` when the prediction shows
    /// none (its source then deletes on the field itself, as without the queue).
    public func deleteBackward() -> Result {
        enter()
        defer { leave() }
        sync()
        guard let last = predictedBefore.last else { return .unchanged }
        let caret = queue.document.caret, length = String(last).utf16.count
        return keystroke([EditStep(span: Span(location: caret - length, length: length), text: "", expect: String(last))])
    }

    private func keystroke(_ steps: [EditStep]) -> Result {
        if queue.needsFinalSettle { trace?("fe.key contradicted=1") }
        return submit(EditTransaction(origin: .keystroke, base: queue.document.version, steps: steps), lane: .user)
    }

    /// A word-row edit or an undo/redo step at the caret (`WordEdit`, in Characters), as its smallest patch; the
    /// caret ends after the inserted text, as the edit's own moves would leave it. Refused (`outOfWindow`) when
    /// the window does not show all the text the edit crosses or deletes (a shorter delete would leave residue),
    /// or while the predicted field may not be the field (a contradicting read, or a read that is our own state
    /// with the caret elsewhere: the user may have put it there): the edit is never planned on the wrong text.
    public func apply(_ edit: WordEdit, origin: EditOrigin) -> Result {
        enter()
        defer { leave() }
        sync()
        if predictionUncertain { return refuseUncertain(origin) }
        let before = predictedBefore, after = predictedAfter, caret = queue.document.caret
        let crossed = String(after.prefix(max(edit.forward, 0)))
        let removed = String((before + crossed).suffix(edit.deleteCount))
        guard crossed.count == max(edit.forward, 0), removed.count == edit.deleteCount else {
            trace?("fe.refused origin=\(origin.rawValue) reason=outOfWindow")
            return .refused(Conflict(.outOfWindow))
        }
        let end = caret + crossed.utf16.count
        let start = end - removed.utf16.count
        let steps = ContiguousPatch.between(removed, edit.insert, at: start).map { [$0] } ?? []
        let transaction = EditTransaction(
            origin: origin, base: queue.document.version, steps: steps, caret: start + edit.insert.utf16.count)
        return submit(transaction, lane: .user)
    }

    /// The planner's ops at the caret on the predicted field, as one patch (`CaretOpsStep`).
    public func caretEdit(for ops: [ProxyOp]) -> CaretOpsStep.Edit? {
        CaretOpsStep.edit(for: ops, before: predictedBefore)
    }

    /// Submits a planner edit. `keepsCaret`: the user's caret stays where it is (moved with the text; host text),
    /// otherwise it ends where the ops leave it (a version swap). A user-lane edit is refused (`outOfWindow`) while
    /// the predicted field may not be the field, as in ``apply(_:origin:)``.
    @discardableResult
    public func write(
        _ edit: CaretOpsStep.Edit, id: UUID = UUID(), origin: EditOrigin, owner: String? = nil, lane: Lane? = nil,
        keepsCaret: Bool, onOutcome: ((Outcome) -> Void)? = nil
    ) -> Result {
        if (lane ?? origin.lane) == .user, predictionUncertain { return refuseUncertain(origin) }
        let transaction = EditTransaction(
            id: id, origin: origin, owner: owner, base: queue.document.version, steps: [edit.step],
            caret: keepsCaret ? nil : edit.caret)
        return submit(transaction, lane: lane, onOutcome: onOutcome)
    }

    private func refuseUncertain(_ origin: EditOrigin) -> Result {
        trace?("fe.refused origin=\(origin.rawValue) reason=uncertain caret=\(caretUncertain ? 1 : 0)")
        return .refused(Conflict(.outOfWindow))
    }

    // MARK: Feed

    /// Publishes the change feed to `sink` (the app's cleanup agent, through `link.feed`): a resync batch with the
    /// window now, then the entries since the last batch, at the end of a host update or source call, each with
    /// the confirmed window after it. `minInterval`: at most one batch per interval (the stream ticks every 33 ms);
    /// what arrives within it goes out together when it ends. Outcomes of the app's edits, and resets, go out at
    /// once (the app's stop waits for them); ``flushFeed()`` sends what waits.
    public func publishFeed(to sink: @escaping (FeedBatch, String) -> Void, minInterval: Duration = .zero) {
        guard !closed else { return }
        endCooldown()
        feedSink = sink
        feedInterval = minInterval
        publishedThrough = nil
        publishedVersions = []
        publishPending(force: true)
    }

    /// Stops publishing (what waits is dropped); the feed is kept short again.
    public func stopPublishing() {
        endCooldown()
        feedSink = nil
        publishedThrough = nil
        publishedVersions = []
    }

    /// Publishes what waits for the throttle's window now (a run's final state).
    public func flushFeed() {
        guard !closed else { return }
        publishPending(force: true)
    }

    /// Whether the feed is being published.
    public var publishesFeed: Bool { feedSink != nil }

    /// The host emptied the field (a send, `ClearWatch`): a run boundary. The queue starts over from the field as
    /// it reads now (`reset(cleared)`, which closes the agent's context before it); writes that await a read are
    /// handed back with the field empty (their sources take that as the boundary, not a failed write) and
    /// edits based before it are out of window. Nothing when the prediction is empty already.
    public func fieldCleared() {
        guard !closed else { return }
        guard !executing, depth == 0 else {
            clearPending = true  // A clear reported from inside a write is a boundary all the same.
            return
        }
        clearPending = false
        guard !queue.document.window.isEmpty else { return }
        enter()
        defer { leave() }
        cancelTimer?()
        cancelTimer = nil
        contradictionDeadline = false
        forgetEchoes()
        forgetGhosts()
        queue.reset(read(), reason: .cleared)
        trace?("fe.reset reason=cleared")
        dispatch()
        drive()
    }

    private func enter() { depth += 1 }

    private func leave() {
        depth -= 1
        guard depth == 0 else { return }
        defer { if clearPending { fieldCleared() } }
        // Why owned text became the user's (a later automatic edit there is refused as `ownerTainted`).
        for taint in queue.takeTaints() {
            trace?("fe.taint source=\(taint.source.rawValue) at=\(taint.span.location) len=\(taint.span.length)")
        }
        publishPending()
    }

    private func publishPending(force: Bool = false) {
        guard let feedSink else { return }
        let batch = queue.feed.since(publishedThrough)
        guard batch.resync || !batch.entries.isEmpty else { return }
        if !force, feedCooldown != nil, !batch.entries.contains(where: { Self.isUrgent($0.event) }) {
            feedWaiting = true
            return
        }
        feedWaiting = false
        publishedThrough = batch.lastSeq
        let time = now()
        publishedVersions.append((batch.version, time))
        // Bounded by age and count: an entry goes once it is older than the age and beyond the newest count.
        while publishedVersions.count > Self.linkedVersions, let first = publishedVersions.first,
            time - first.at > Self.linkedAge
        {
            publishedVersions.removeFirst()
        }
        feedSink(batch, queue.feed.window)
        guard feedInterval > .zero else { return }
        feedCooldown?()
        feedCooldown = schedule(feedInterval) { [weak self] in
            guard let self else { return }
            feedCooldown = nil
            if feedWaiting { publishPending() }
        }
    }

    private func endCooldown() {
        feedCooldown?()
        feedCooldown = nil
        feedWaiting = false
    }

    /// Events the app waits for: its own edits' outcomes (and any hand-back), and a reset of the field.
    private static func isUrgent(_ event: FeedEvent) -> Bool {
        switch event {
        case .applied(_, let origin, _, _): origin == .agent || origin == .finalSwap || origin == .tool
        case .conflict, .superseded, .withdrawn, .reset: true
        case .asrDelta, .foreign, .rebased: false
        }
    }

    // MARK: Executing

    /// Runs every write the queue gives out, verifies them against a read, and goes on while that frees a lane.
    private func drive() {
        guard !executing, !closed else {
            driveAgain = true
            return
        }
        var rounds = 0
        repeat {
            driveAgain = false
            while executeNext() {}
            if !issued.isEmpty, case let snapshot = read(), !isEcho(snapshot) { queue.settle(snapshot, final: false) }
            dispatch()
            rounds += 1
        } while (driveAgain || (issued.isEmpty && queue.hasPending)) && rounds < 32
        if issued.isEmpty {
            cancelTimer?()
            cancelTimer = nil
            // Echoes no read showed yet are expected until the timeout only.
            if !echoes.isEmpty || lastEcho != nil {
                cancelTimer = schedule(settleTimeout) { [weak self] in self?.expireEchoes() }
            }
        }
        if clearPending, depth == 0 { fieldCleared() }  // A clear reported while a timer's write ran.
    }

    /// The lane of the write issued last.
    private var lastLane: Lane?

    /// Issues and runs one write; false when none can run now. After an ASR write the cleanup lane gets the next
    /// turn (the user lane still first): continuous dictation keeps an ASR write queued behind every one awaiting
    /// its read, and the queue's lane order alone would hold the cleanup lane until the speaker pauses.
    private func executeNext() -> Bool {
        let window = queue.document.window, caret = queue.document.caret
        let turn = lastLane == .asr ? queue.next(lanes: [.user, .cleanup]) : nil
        guard let write = turn ?? queue.next() else { return false }
        lastLane = write.lane
        guard let calls = ProxyOpCompiler.compile(write, window: window, caret: caret) else {
            queue.abort(write.id, requeue: false, reason: .expectMismatch)
            return true
        }
        let states = Self.states(of: calls, window: window, caret: caret)
        let start = FieldSnapshot(window: window, caret: caret)
        let ghost = ghosts.first { Self.same(FieldSnapshot(window: $0.window, caret: $0.caret), start) && $0.calls == calls }
        ghosts = []  // the field moves on: no other ghost fits it any more
        if let ghost {
            // The same write again: the failed one's calls already ran on this field and its read is late.
            adopted[write.id] = ghost
            if !Self.endsWith(echoes, states) {
                if echoes.isEmpty { echoes = [start] }
                echoes += states
            }
        } else {
            if echoes.isEmpty { echoes = [start] }
            echoes += states
            executing = true
            document.execute(calls)
            executing = false
            if write.owner != nil, !write.origin.isUser, let end = states.last {
                ran[write.id] = Ghost(window: window, caret: caret, calls: calls, end: end)
            }
        }
        issued.insert(write.id)
        trace?("fe.write origin=\(write.origin.rawValue) lane=\(write.lane) " + Self.summary(calls, caret: write.caret, window: queue.document.window) + (ghost != nil ? " adopted=1" : ""))
        handlers[write.id]?(.executed)
        restartSettleTimer()
        return true
    }

    private func restartSettleTimer() {
        if queue.needsFinalSettle {
            // The deadline the contradiction's first write set stands: later keys do not push the final read back.
            if contradictionDeadline, cancelTimer != nil { return }
            contradictionDeadline = true
        } else {
            contradictionDeadline = false
        }
        cancelTimer?()
        extended = false
        armSettleTimer()
    }

    private func armSettleTimer() {
        cancelTimer = schedule(settleTimeout) { [weak self] in
            guard let self else { return }
            self.cancelTimer = nil
            self.settleFinal()
        }
    }

    /// The timeout passed: a final read decides; a stale one, an echo (the host has not caught up) or a read
    /// that still contradicts the prediction (e.g. a transient empty context) waits once more.
    private func settleFinal() {
        guard !issued.isEmpty, !closed, !executing else { return }
        enter()
        defer { leave() }
        let snapshot = read()
        let echo = isEcho(snapshot)
        if !extended, echo || queue.needsFinalSettle {
            trace?("fe.settle final=1 outcome=\(echo ? "lagging" : "contradicted") extended=0")
            extended = true
            armSettleTimer()
            return
        }
        if extended, let id = issued.first, issued.count == 1, let ghost = adopted[id],
            Self.same(FieldSnapshot(window: ghost.window, caret: ghost.caret), snapshot)
        {
            // Both waits passed and the field still shows nothing of it: the failed write was lost after all, and
            // its retype runs its calls now (once; should the lost one land even later, `fe.duplicate` says so).
            adopted[id] = nil
            spent = ghost
            ran[id] = ghost
            executing = true
            document.execute(ghost.calls)
            executing = false
            trace?("fe.write adopted=0 calls=\(ghost.calls.count)")
            restartSettleTimer()
            return
        }
        let outcome = queue.settle(snapshot, final: true, tolerateStale: !extended)
        trace?("fe.settle final=1 outcome=\(outcome) extended=\(extended ? 1 : 0)")
        contradictionDeadline = false
        dispatch()
        if outcome == .stale, !issued.isEmpty {
            extended = true
            armSettleTimer()
            return
        }
        drive()
    }

    private func expireEchoes() {
        cancelTimer = nil
        guard issued.isEmpty else { return }
        enter()
        defer { leave() }
        forgetEchoes()
        // A late write no retype claimed: the field shows it, and the queue reads it as it is.
        if !ghosts.isEmpty {
            ghosts = []
            sync()
        }
    }

    /// Whether `snapshot` is a failed write landing late (``ghosts``) on the field the queue still predicts.
    private func lateGhost(_ snapshot: FieldSnapshot) -> Bool {
        let predicted = split
        guard ghosts.contains(where: {
            Self.same($0.end, snapshot) && Self.same(FieldSnapshot(window: $0.window, caret: $0.caret), predicted)
        }) else { return false }
        cancelTimer?()
        cancelTimer = schedule(settleTimeout) { [weak self] in self?.expireEchoes() }
        return true
    }

    private static func endsWith(_ states: [FieldSnapshot], _ suffix: [FieldSnapshot]) -> Bool {
        states.count >= suffix.count && zip(states.suffix(suffix.count), suffix).allSatisfy { same($0, $1) }
    }

    /// Hands the queue's events to their sources (a handler may withdraw or submit: their events go out too).
    private func dispatch() {
        guard !dispatching else { return }
        dispatching = true
        defer { dispatching = false }
        while case let events = queue.takeEvents(), !events.isEmpty {
            for event in events {
                switch event {
                case .applied(let id, _): finish(id, .applied)
                case .superseded(let id, _): finish(id, .superseded)
                case .withdrawn(let id): finish(id, .withdrawn)
                case .conflict(let id, let conflict):
                    trace?("fe.outcome origin=\(origins[id]?.rawValue ?? "-") result=conflict reason=\(conflict.reason.rawValue) byUser=\(conflict.byUser ? 1 : 0)")
                    finish(id, .conflict(conflict))
                }
            }
        }
        if issued.isEmpty, !queue.hasPending {
            if feedSink != nil {
                // The app's edits name the version of a batch it read: keep those mappable, and the unpublished feed.
                queue.pruneHistory(before: publishedVersions.first?.version ?? queue.feed.version)
                if let published = publishedThrough { queue.trimFeed(through: published) }
            } else {
                // Nothing waits on older versions: keep the history and the feed short.
                queue.pruneHistory(before: queue.document.version)
                if let last = queue.feed.entries.last?.seq { queue.trimFeed(through: last) }
            }
        }
    }

    private func finish(_ id: UUID, _ outcome: Outcome) {
        issued.remove(id)
        origins[id] = nil
        let ranGhost = ran.removeValue(forKey: id), adoptedGhost = adopted.removeValue(forKey: id)
        if case .conflict(let conflict) = outcome, conflict.reason == .verifyFailed {
            // Before the handler runs: its source may type the write again right away.
            if let ranGhost { ghosts.append(ranGhost) }
            if let adoptedGhost {
                spent = adoptedGhost
                trace?("fe.adopted failed=1")
            }
        }
        handlers.removeValue(forKey: id)?(outcome)
    }

    /// `del=<Characters> ins=<Characters> moves=<n> caret=<at> end=<window length>`.
    private static func summary(_ calls: [ProxyCall], caret: Int, window: String) -> String {
        var deleted = 0, inserted = 0, moves = 0
        for call in calls {
            switch call {
            case .moveCaret: moves += 1
            case .deleteBackward(let count): deleted += count
            case .insert(let text): inserted += text.count
            }
        }
        return "del=\(deleted) ins=\(inserted) moves=\(moves) caret=\(caret) end=\(window.utf16.count)"
    }
}
