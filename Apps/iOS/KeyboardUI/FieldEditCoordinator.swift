import Foundation
import LegatoFieldEdit
import LegatoKeyboardCore

/// The keyboard's field edit queue (the experimental setting), for one keyboard appearance: every edit the
/// keyboard makes goes through one `FieldEditQueue` over the caret-relative window
/// (`documentContextBefore/AfterInput`) and is carried out by this type on the `TextDocument`.
///
/// - Sources submit transactions; a write runs as soon as the queue gives it out (`next`), its whole op
///   sequence (move, delete, insert, move back; `ProxyOpCompiler`) in this main-thread turn, so a keystroke
///   never lands between our caret move and our move back. User-lane edits (keys, the word row, undo and redo,
///   versions) run in the call that submits them; the ASR and cleanup lanes wait while a write awaits its read.
/// - Verification: right after a write the field is read again and the read settled against the prediction
///   (`settle(final: false)`); a host update does the same (`sync`), and `settleTimeout` after the newest
///   write a last read decides (`final: true`). Host updates with nothing unverified are observed (caret moves,
///   the user's own changes, window shifts).
/// - Outcomes go back to each source's handler: `.executed` once its ops ran, then `.applied`, `.conflict` or
///   `.superseded`.
@MainActor
final class FieldEditCoordinator {
    enum Outcome: Equatable {
        /// The write's proxy calls ran; the read that confirms it may still be due.
        case executed
        case applied
        case conflict(Conflict)
        case superseded
    }

    /// What a submission did by the time the call returns.
    enum Result: Equatable {
        /// Its ops ran (it may still await its read).
        case done
        /// It waits in its lane (a write before it awaits its read).
        case waiting
        /// Handed back at once: nothing was written.
        case refused(Conflict)
        /// Nothing to write.
        case unchanged
    }

    /// How long after the newest write the last read decides what landed.
    static var settleTimeout: Duration {
        #if DEBUG
        let ms = UserDefaults.standard.integer(forKey: "LegatoFieldEditSettleMs")
        if ms > 0 { return .milliseconds(ms) }
        #endif
        return .milliseconds(250)
    }

    /// Diagnostics (the DEBUG harness logs it); counts only, no user text.
    var trace: ((String) -> Void)?

    private let document: any TextDocument
    private var queue: FieldEditQueue
    private var documentID: String?
    private var handlers: [UUID: (Outcome) -> Void] = [:]
    private var origins: [UUID: EditOrigin] = [:]
    /// Written, not yet confirmed or failed.
    private var issued: Set<UUID> = []
    private var executing = false
    private var driveAgain = false
    private var settleTimer: Task<Void, Never>?
    private var closed = false

    init(document: any TextDocument) {
        self.document = document
        documentID = document.documentID
        queue = FieldEditQueue(FieldSnapshot(before: document.contextBefore, after: document.contextAfter))
    }

    // MARK: State

    /// The field as predicted after every write that ran.
    var predicted: ShadowDocument { queue.document }
    var predictedBefore: String { split.before }
    var predictedAfter: String { split.after }
    private var split: FieldSnapshot { FieldSnapshot(window: queue.document.window, caret: queue.document.caret) }

    /// An edit waits in its lane.
    var hasPending: Bool { queue.hasPending }
    /// A write ran and its read has not confirmed it yet.
    var awaitsVerification: Bool { !issued.isEmpty }

    private func read() -> FieldSnapshot { FieldSnapshot(before: document.contextBefore, after: document.contextAfter) }

    // MARK: Host updates

    /// The field changed or was looked at again (`textDidChange`, `selectionDidChange`, before an edit): issued
    /// writes are settled against a fresh read, otherwise the read is observed; another field starts over.
    func sync() {
        guard !executing, !closed else { return }
        if document.documentID != documentID {
            documentID = document.documentID
            queue.reset(read(), reason: .focusChanged)
        } else if issued.isEmpty {
            queue.observe(read())
        } else {
            queue.settle(read(), final: false)
        }
        dispatch()
        drive()
    }

    /// The keyboard goes away: the last read decides what landed, and edits still waiting are handed back.
    func close() {
        guard !closed else { return }
        settleTimer?.cancel()
        settleTimer = nil
        if !issued.isEmpty {
            queue.settle(read(), final: true)
            dispatch()
        }
        closed = true
        queue.reset(read(), reason: .focusChanged)
        dispatch()
        handlers = [:]
    }

    // MARK: Submitting

    /// Queues `transaction` (in `lane`, default its origin's) and runs what can run now.
    @discardableResult
    func submit(_ transaction: EditTransaction, lane: Lane? = nil, onOutcome: ((Outcome) -> Void)? = nil) -> Result {
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
        case .superseded: return .refused(Conflict(.overlap))
        case .executed, .applied: return .done
        case nil:
            trace?("fe.queued origin=\(transaction.origin.rawValue)")
            return .waiting
        }
    }

    /// A keystroke: `text` at the caret, in the user lane.
    func type(_ text: String) -> Result {
        sync()
        let step = EditStep.insert(text, at: queue.document.caret)
        return submit(EditTransaction(origin: .keystroke, base: queue.document.version, steps: [step]), lane: .user)
    }

    /// The delete key: the Character before the caret. `.unchanged` when the window shows none.
    func deleteBackward() -> Result {
        sync()
        guard let last = predictedBefore.last else { return .unchanged }
        let caret = queue.document.caret, length = String(last).utf16.count
        let step = EditStep(span: Span(location: caret - length, length: length), text: "", expect: String(last))
        return submit(EditTransaction(origin: .keystroke, base: queue.document.version, steps: [step]), lane: .user)
    }

    /// A word-row edit or an undo/redo step at the caret (`WordEdit`, in Characters), as its smallest patch; the
    /// caret ends after the inserted text, as the edit's own moves would leave it.
    func apply(_ edit: WordEdit, origin: EditOrigin) -> Result {
        sync()
        let before = predictedBefore, after = predictedAfter, caret = queue.document.caret
        let crossed = String(after.prefix(max(edit.forward, 0)))
        let removed = String((before + crossed).suffix(edit.deleteCount))
        let end = caret + crossed.utf16.count
        let start = end - removed.utf16.count
        let steps = ContiguousPatch.between(removed, edit.insert, at: start).map { [$0] } ?? []
        let transaction = EditTransaction(
            origin: origin, base: queue.document.version, steps: steps, caret: start + edit.insert.utf16.count)
        return submit(transaction, lane: .user)
    }

    /// The planner's ops at the caret on the predicted field, as one patch (`CaretOpsStep`).
    func caretEdit(for ops: [ProxyOp]) -> CaretOpsStep.Edit? {
        CaretOpsStep.edit(for: ops, before: predictedBefore)
    }

    /// Submits a planner edit. `keepsCaret`: the user's caret stays where it is (moved with the text; host text),
    /// otherwise it ends where the ops leave it (a version swap).
    @discardableResult
    func write(
        _ edit: CaretOpsStep.Edit, id: UUID = UUID(), origin: EditOrigin, owner: String? = nil, lane: Lane? = nil,
        keepsCaret: Bool, onOutcome: ((Outcome) -> Void)? = nil
    ) -> Result {
        let transaction = EditTransaction(
            id: id, origin: origin, owner: owner, base: queue.document.version, steps: [edit.step],
            caret: keepsCaret ? nil : edit.caret)
        return submit(transaction, lane: lane, onOutcome: onOutcome)
    }

    // MARK: Executing

    /// Runs every write the queue gives out, verifies them against a read, and goes on while that frees a lane.
    private func drive() {
        guard !executing else {
            driveAgain = true
            return
        }
        var rounds = 0
        repeat {
            driveAgain = false
            while executeNext() {}
            if !issued.isEmpty { queue.settle(read(), final: false) }
            dispatch()
            rounds += 1
        } while (driveAgain || (issued.isEmpty && queue.hasPending)) && rounds < 32
        if issued.isEmpty {
            settleTimer?.cancel()
            settleTimer = nil
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
        executing = true
        document.execute(calls)
        executing = false
        issued.insert(write.id)
        trace?("fe.write origin=\(write.origin.rawValue) lane=\(write.lane) " + Self.summary(calls, caret: write.caret, window: queue.document.window))
        handlers[write.id]?(.executed)
        restartSettleTimer()
        return true
    }

    private func restartSettleTimer() {
        settleTimer?.cancel()
        settleTimer = Task { [weak self] in
            try? await Task.sleep(for: Self.settleTimeout)
            guard !Task.isCancelled, let self else { return }
            self.settleTimer = nil
            self.settleFinal()
        }
    }

    private func settleFinal() {
        guard !issued.isEmpty, !closed, !executing else { return }
        let outcome = queue.settle(read(), final: true)
        trace?("fe.settle final=1 outcome=\(outcome)")
        dispatch()
        drive()
    }

    /// Hands the queue's events to their sources.
    private func dispatch() {
        for event in queue.takeEvents() {
            switch event {
            case .applied(let id, _): finish(id, .applied)
            case .superseded(let id, _): finish(id, .superseded)
            case .conflict(let id, let conflict):
                trace?("fe.outcome origin=\(origins[id]?.rawValue ?? "-") result=conflict reason=\(conflict.reason.rawValue) byUser=\(conflict.byUser ? 1 : 0)")
                finish(id, .conflict(conflict))
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
