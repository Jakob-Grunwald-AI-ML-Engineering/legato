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

/// The keyboard's field edit queue (the experimental setting), for one keyboard appearance: every edit the
/// keyboard makes goes through one `FieldEditQueue` over the caret-relative window
/// (`documentContextBefore/AfterInput`) and is carried out by this type on the document.
///
/// - Sources submit transactions; a write runs as soon as the queue gives it out (`next`), its whole op
///   sequence (move, delete, insert, move back; `ProxyOpCompiler`) in this main-thread turn, so a keystroke
///   never lands between our caret move and our move back. User-lane edits (keys, the word row, undo and redo,
///   versions) run in the call that submits them; the ASR and cleanup lanes wait while a write awaits its read.
/// - Verification: every read before the timeout is settled with `final: false` (right after a write, and on
///   every host update: `sync`). Such a read never fails a write and never records our own text as the user's:
///   a read nothing explains (an intermediate or partial proxy state) waits (`notYet`). `settleTimeout` after the
///   newest write the read is settled with `final: true, tolerateStale: true`; a read still showing the field from
///   before a write (`stale`: the host has not caught up) waits once more, and only that second final read may
///   fail what it does not show. A failed write is handed back once.
/// - Echoes: the coordinator knows every state its own calls take the field through (the field before them,
///   then after each move, each deleted Character, each insert). A read that is one of those states, other
///   than the last, is the host catching up with our calls, not news: it is not handed to the queue (matched in
///   order, earliest first, so a field that returns to an earlier text on the way, A → B → A, is not taken for
///   the end), and a timeout that finds one waits once more, as for a stale read. The last state, and any read
///   that is none of them, goes to the queue. So the caret the queue plans from is where our calls left it, and
///   our own intermediate text is never recorded as the user's.
/// - Outcomes go back to each source's handler: `.executed` once its ops ran, then `.applied`, `.conflict`,
///   `.superseded`, `.withdrawn`, or `.unconfirmed` when the keyboard went away before a read decided.
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

    public init(
        document: any FieldEditDocument, settleTimeout: Duration = .milliseconds(250),
        schedule: @escaping Schedule = FieldEditCoordinator.taskSchedule
    ) {
        self.document = document
        self.settleTimeout = settleTimeout
        self.schedule = schedule
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
        guard queue.withdraw(id) else { return false }
        dispatch()
        return true
    }

    /// A keystroke: `text` at the caret, in the user lane. Always typed in this call, never held: while the
    /// prediction is contradicted (a read nothing explains, e.g. the host sent and cleared the field before
    /// reporting our Return) the key goes straight to the field (`insertText` types at the real caret,
    /// whatever the prediction says), and the next read records it as the user's typing.
    public func type(_ text: String) -> Result {
        sync()
        if queue.needsFinalSettle { return typeDirectly([.insert(text)]) }
        let step = EditStep.insert(text, at: queue.document.caret)
        return keystroke([step], or: [.insert(text)])
    }

    /// The delete key: the Character before the caret. `.unchanged` when the window shows none. Never held,
    /// as ``type(_:)``.
    public func deleteBackward() -> Result {
        sync()
        if queue.needsFinalSettle { return typeDirectly([.deleteBackward(1)]) }
        guard let last = predictedBefore.last else { return .unchanged }
        let caret = queue.document.caret, length = String(last).utf16.count
        let step = EditStep(span: Span(location: caret - length, length: length), text: "", expect: String(last))
        return keystroke([step], or: [.deleteBackward(1)])
    }

    /// Submits a keystroke; one the queue would hold is withdrawn and typed straight away instead.
    private func keystroke(_ steps: [EditStep], or calls: [ProxyCall]) -> Result {
        let transaction = EditTransaction(origin: .keystroke, base: queue.document.version, steps: steps)
        let result = submit(transaction, lane: .user)
        guard result == .waiting, withdraw(transaction.id) else { return result }
        return typeDirectly(calls)
    }

    /// A key the queue cannot issue now, run on the field as the user pressed it (caret-relative calls only).
    private func typeDirectly(_ calls: [ProxyCall]) -> Result {
        executing = true
        document.execute(calls)
        executing = false
        trace?("fe.key direct=1")
        return .done
    }

    /// A word-row edit or an undo/redo step at the caret (`WordEdit`, in Characters), as its smallest patch; the
    /// caret ends after the inserted text, as the edit's own moves would leave it. Refused (`outOfWindow`) when
    /// the window does not show all the text the edit crosses or deletes (a shorter delete would leave residue),
    /// or while the predicted field may not be the field (a contradicting read, or a read that is our own state
    /// with the caret elsewhere: the user may have put it there): the edit is never planned on the wrong text.
    public func apply(_ edit: WordEdit, origin: EditOrigin) -> Result {
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
    }

    /// Issues and runs one write; false when none can run now.
    private func executeNext() -> Bool {
        let window = queue.document.window, caret = queue.document.caret
        guard let write = queue.next() else { return false }
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

    /// The timeout passed: a final read decides; a stale one or an echo (the host has not caught up) waits once
    /// more.
    private func settleFinal() {
        guard !issued.isEmpty, !closed, !executing else { return }
        let snapshot = read()
        if isEcho(snapshot), !extended {
            trace?("fe.settle final=1 outcome=lagging extended=0")
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
            // Nothing waits on older versions: keep the history and the feed short (no reader yet on iOS).
            queue.pruneHistory(before: queue.document.version)
            if let last = queue.feed.entries.last?.seq { queue.trimFeed(through: last) }
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
