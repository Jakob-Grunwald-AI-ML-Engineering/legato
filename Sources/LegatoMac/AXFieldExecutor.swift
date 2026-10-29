import Foundation
import LegatoFieldEdit

/// Drains a ``FieldEditQueue`` into a Mac text field, one write at a time, synchronously. The Mac window is the
/// whole field (absolute UTF-16 positions); every write is read, written and read back:
///
/// read → `observe` (what changed since the last look maps the pending edits, or conflicts them) → `next` →
/// typing-guard check → per step select, verify the step's expected text, replace → select the caret back →
/// read back → `settle`.
///
/// - A write that did not run (the field changed under it, a select or replace threw, the field cannot be read)
///   is `abort`ed: requeued when the field only changed (it is mapped through the change and tried again, at most
///   ``maxAttempts`` times), handed back with ``Conflict/Reason/writeFailed`` / ``Conflict/Reason/unreadable``
///   otherwise. One edit's failure never stops the next edit.
/// - A write whose readback disagrees (ignored, truncated, altered) is the queue's `verifyFailed`.
/// - Non-user writes wait while the ``TypingGuard`` reports typing: the edit stays queued and ``drain(ignoringGuard:)``
///   says when to call again. User-origin edits are never held.
/// - A lost focus hands every pending edit back as `focusLost`.
@MainActor
public final class AXFieldExecutor {
    public enum DrainResult: Equatable, Sendable {
        /// Nothing is left that can run now.
        case idle
        /// A non-user edit waits for the user to stop typing; call ``drain(ignoringGuard:)`` again after the delay.
        case held(retryAfter: TimeInterval)
        /// Draining stopped on a field fault; the pending edits were handed back with this reason.
        case blocked(Conflict.Reason)
    }

    /// Tries per edit before a field that keeps changing under it is a conflict.
    public static let maxAttempts = 3
    /// The longest field read, in UTF-16 units; a longer field is unreadable.
    static let maxFieldLength = 1 << 20

    public private(set) var queue: FieldEditQueue
    public let target: any TextTarget
    private let typingGuard: TypingGuard?
    private var attempts: [UUID: Int] = [:]

    /// Reads the field to start the queue; nil when it cannot be read.
    public init?(target: any TextTarget, typingGuard: TypingGuard? = nil) {
        guard let read = Self.read(target) else { return nil }
        self.target = target
        self.typingGuard = typingGuard
        queue = FieldEditQueue(read.snapshot)
        typingGuard?.isEcho = { [weak self] in self?.fieldMatchesQueue() ?? false }
    }

    public func submit(_ transaction: EditTransaction, lane: Lane? = nil) {
        queue.submit(transaction, lane: lane)
    }

    public func takeEvents() -> [QueueEvent] { queue.takeEvents() }

    // MARK: Draining

    /// Runs every edit that can run now. `ignoringGuard` writes non-user edits even while the user types (for a
    /// caller that cannot wait).
    @discardableResult
    public func drain(ignoringGuard: Bool = false) -> DrainResult {
        guard target.isFocused() else { return loseFocus() }
        while true {
            guard let before = Self.read(target) else {
                failPending(.unreadable)
                return .blocked(.unreadable)
            }
            queue.observe(before.snapshot)
            guard let write = queue.next() else { return .idle }
            if !ignoringGuard, let wait = typingGuard?.delay(for: write.origin), wait > 0 {
                queue.abort(write.id, requeue: true, reason: .expectMismatch)
                return .held(retryAfter: wait)
            }
            if !target.isFocused() {
                queue.abort(write.id, requeue: false, reason: .focusLost)
                return loseFocus()
            }
            run(write, selectionBefore: before.selection)
        }
    }

    // MARK: Running one write

    /// How a step went wrong, and so what the queue is told.
    private enum Fault {
        case failed(Conflict.Reason)  // the call threw / could not read: hand the edit back
        case changed  // the field is not what the step expects: map it again
    }

    private func run(_ write: FieldWrite, selectionBefore: UTF16Range) {
        var landed = 0
        for step in write.steps {  // application order: highest location first
            if let fault = runStep(step) {
                finish(write, landed: landed, fault: fault, selectionBefore: selectionBefore)
                return
            }
            landed += 1
        }
        // The caret goes back where the queue put it. A field that refuses is read back as it is.
        try? target.select(UTF16Range(location: write.caret, length: 0))
        if let after = Self.read(target) {
            attempts[write.id] = nil
            queue.settle(after.snapshot)
        } else {
            queue.abort(write.id, requeue: false, reason: .unreadable)
        }
    }

    private func runStep(_ step: EditStep) -> Fault? {
        let range = UTF16Range(location: step.span.location, length: step.span.length)
        do { try target.select(range) } catch { return .failed(.writeFailed) }
        if range.length > 0 {  // an insertion point expects nothing
            guard let current = try? target.text(in: range) else { return .failed(.unreadable) }
            guard current.utf8.elementsEqual(step.expect.utf8) else { return .changed }
        }
        do { try target.replace(range, with: step.text) } catch { return .failed(.writeFailed) }
        return nil
    }

    private func finish(_ write: FieldWrite, landed: Int, fault: Fault, selectionBefore: UTF16Range) {
        if landed > 0 {
            // Part of the write is in the field: the queue settles whatever the field shows.
            if let after = Self.read(target) {
                queue.settle(after.snapshot)
            } else {
                queue.abort(write.id, requeue: false, reason: .unreadable)
            }
            return
        }
        switch fault {
        case .failed(let reason):
            if reason == .writeFailed { try? target.select(selectionBefore) }
            queue.abort(write.id, requeue: false, reason: reason)
        case .changed:
            let tries = (attempts[write.id] ?? 0) + 1
            attempts[write.id] = tries
            let again = tries < Self.maxAttempts
            if !again { attempts[write.id] = nil }
            queue.abort(write.id, requeue: again, reason: .expectMismatch)
        }
    }

    // MARK: Field faults

    private func loseFocus() -> DrainResult {
        if queue.hasPending {
            let snapshot =
                Self.read(target)?.snapshot
                ?? FieldSnapshot(window: queue.document.window, caret: queue.document.caret, windowBase: 0)
            queue.reset(snapshot, reason: .focusChanged)
        }
        return .blocked(.focusLost)
    }

    /// Hands every pending edit back with `reason` (the field cannot be read, so nothing can be checked).
    private func failPending(_ reason: Conflict.Reason) {
        while let write = queue.next() { queue.abort(write.id, requeue: false, reason: reason) }
    }

    // MARK: Reading

    private struct Read {
        var snapshot: FieldSnapshot
        var selection: UTF16Range
    }

    private static func read(_ target: any TextTarget) -> Read? {
        guard let selection = try? target.selectedRange(), let text = readAll(target) else { return nil }
        return Read(snapshot: FieldSnapshot(window: text, caret: selection.location, windowBase: 0), selection: selection)
    }

    /// The whole field. `text(in:)` may come back short only at the end of the field, so growing reads find it.
    private static func readAll(_ target: any TextTarget) -> String? {
        var length = 4096
        while length <= maxFieldLength {
            guard let text = try? target.text(in: UTF16Range(location: 0, length: length)) else { return nil }
            if text.utf16.count < length { return text }
            length *= 4
        }
        return nil
    }

    /// Whether the field reads exactly as the queue left it: a notification for it is our own write's echo.
    private func fieldMatchesQueue() -> Bool {
        guard let read = Self.read(target) else { return false }
        return read.snapshot.window.utf8.elementsEqual(queue.document.window.utf8) && read.snapshot.caret == queue.document.caret
    }
}
