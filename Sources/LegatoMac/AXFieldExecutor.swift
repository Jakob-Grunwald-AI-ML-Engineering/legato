import Foundation
import LegatoFieldEdit

/// Drains a ``FieldEditQueue`` into a Mac text field, one write at a time, synchronously. The Mac window is the
/// whole field (absolute UTF-16 positions, read by the field's length); every write is read, written and read
/// back:
///
/// read → `observe` (what changed since the last look maps the pending edits, or conflicts them) → typing-guard
/// check → `next` → per step: select, check the field is still what the write was planned on (its length, and
/// the span with a context window around it, so insertion points are guarded too), replace → restore the
/// selection → read back → `settle`.
///
/// - The user's selection comes back on every path: after a write it is mapped through the write (a ranged
///   selection keeps its range when the edit set no caret); on any path that did not write it is restored,
///   mapped through what the user changed meanwhile.
/// - A step that finds the field changed (or cannot check it) takes back the steps of the same write that already
///   landed (inverse writes, each checked the same way), then the write is `abort`ed and requeued: it is mapped
///   through the change and tried again, at most ``maxAttempts`` times. A select or replace that throws hands
///   the write back as ``Conflict/Reason/writeFailed``. A write that landed in part and cannot be taken back is
///   settled as the field shows it. One edit's failure never stops the next edit.
/// - A write whose readback disagrees (ignored, truncated, altered) is the queue's `verifyFailed`.
/// - A field that cannot be read keeps everything: ``DrainResult/unreadable(retryAfter:)`` with a growing delay,
///   and a write that ran but could not be read back waits for the next read to settle it. After
///   ``maxUnreadableReads`` failed reads in a row everything is handed back as ``Conflict/Reason/unreadable``.
/// - Non-user writes wait while the ``TypingGuard`` reports typing, without being issued: they stay queued and
///   ``DrainResult/held(retryAfter:)`` says when to call again. User-origin edits are never held.
/// - A lost focus hands every pending edit back as `focusLost`.
/// - Events are kept per transaction: ``takeEvents(for:)`` takes one source's, ``takeEvents()`` the rest.
@MainActor
public final class AXFieldExecutor {
    public enum DrainResult: Equatable, Sendable {
        /// Nothing is left that can run now.
        case idle
        /// A non-user edit waits for the user to stop typing; call ``drain()`` again after the delay.
        case held(retryAfter: TimeInterval)
        /// The field could not be read; the pending edits are kept. Call ``drain()`` again after the delay.
        case unreadable(retryAfter: TimeInterval)
        /// Draining stopped on a field fault; the pending edits were handed back with this reason.
        case blocked(Conflict.Reason)
    }

    /// Tries per edit before a field that keeps changing under it is a conflict.
    public static let maxAttempts = 3
    /// Failed reads in a row before the pending edits are handed back as unreadable.
    public static let maxUnreadableReads = 3
    /// The first retry delay after a failed read; it doubles with every further one.
    public static let unreadableRetryDelay: TimeInterval = 0.05
    /// The longest field read, in UTF-16 units; a longer field is unreadable.
    static let maxFieldLength = 1 << 20
    /// UTF-16 units on each side of a step that must still read as planned right before it is written.
    static let checkContext = 32

    public private(set) var queue: FieldEditQueue
    public let target: any TextTarget
    private let typingGuard: TypingGuard?
    private var attempts: [UUID: Int] = [:]
    /// Submitted and not handed back yet (applied, superseded or conflicted), by origin.
    private var outstanding: [UUID: EditOrigin] = [:]
    /// Transactions without a caret of their own: the user's selection, ranged or not, is kept around them.
    private var keepsSelection: Set<UUID> = []
    /// Writes that ran but could not be read back, oldest first: the next read settles them.
    private var awaitingReadback: [UUID] = []
    /// Pending edits their source took back: handed back when they come up, never written.
    private var withdrawn: Set<UUID> = []
    private var unreadableReads = 0
    private var events: [QueueEvent] = []

    /// Reads the field to start the queue; nil when it cannot be read.
    public init?(target: any TextTarget, typingGuard: TypingGuard? = nil) {
        guard let read = Self.read(target) else { return nil }
        self.target = target
        self.typingGuard = typingGuard
        queue = FieldEditQueue(read.snapshot)
        typingGuard?.isEcho = { [weak self] in self?.fieldMatchesQueue() ?? false }
    }

    public func submit(_ transaction: EditTransaction, lane: Lane? = nil) {
        outstanding[transaction.id] = transaction.origin
        if transaction.caret == nil { keepsSelection.insert(transaction.id) }
        queue.submit(transaction, lane: lane)
        collect()
    }

    /// Every event not taken by its source with ``takeEvents(for:)``, oldest first.
    public func takeEvents() -> [QueueEvent] {
        collect()
        defer { events = [] }
        return events
    }

    /// The events of transaction `id`, oldest first; the others stay for their sources.
    public func takeEvents(for id: UUID) -> [QueueEvent] {
        collect()
        let mine = events.filter { $0.transactionID == id }
        events.removeAll { $0.transactionID == id }
        return mine
    }

    /// Whether `id` was submitted and has no outcome yet.
    public func isOutstanding(_ id: UUID) -> Bool { outstanding[id] != nil }

    /// Whether `id` ran but could not be read back yet (the next read settles it).
    public func isAwaitingReadback(_ id: UUID) -> Bool { awaitingReadback.contains(id) }

    /// Takes a pending edit back: it is never written and its outcome is dropped. A write awaiting readback
    /// already ran and is not affected.
    public func withdraw(_ id: UUID) {
        guard outstanding[id] != nil, !awaitingReadback.contains(id) else { return }
        withdrawn.insert(id)
    }

    /// Reads the field and lets the queue see what changed since its last look (settling writes awaiting
    /// readback); false when it cannot be read.
    @discardableResult
    public func refresh() -> Bool {
        guard let read = Self.read(target) else { return false }
        queue.observe(read.snapshot)
        collect()
        return true
    }

    // MARK: Draining

    /// Runs every edit that can run now.
    @discardableResult
    public func drain() -> DrainResult { drain(priority: nil) }

    /// Runs transaction `id` now, ahead of the typing guard, for a writer that cannot wait; user edits queued
    /// ahead of it run too (they are never held), every other edit stays queued. Returns once `id` has an
    /// outcome or cannot run (another automatic edit is ahead of it, or the field faults).
    @discardableResult
    public func drain(only id: UUID) -> DrainResult { drain(priority: id) }

    private func drain(priority: UUID?) -> DrainResult {
        guard target.isFocused() else { return loseFocus() }
        while true {
            if let priority, !isOutstanding(priority) || isAwaitingReadback(priority) { return .idle }
            guard let before = Self.read(target) else { return unreadable() }
            unreadableReads = 0
            queue.observe(before.snapshot)
            collect()
            if let priority, !isOutstanding(priority) { return .idle }
            if priority == nil, let wait = holdBeforeIssuing() { return .held(retryAfter: wait) }
            guard let write = queue.next() else {
                collect()
                return .idle
            }
            collect()
            if withdrawn.contains(write.id) {
                queue.abort(write.id, requeue: false, reason: .writeFailed)
                collect()
                continue
            }
            if write.id != priority, !write.origin.isUser {
                // Only reached when the guard said nothing before issuing (a user edit was outstanding), or for
                // an automatic edit ahead of the writer's own: requeued at the front of its lane, no event.
                let wait = priority == nil ? typingGuard?.delay(for: write.origin) ?? 0 : 0
                if priority != nil || wait > 0 {
                    queue.abort(write.id, requeue: true, reason: .expectMismatch)
                    collect()
                    return .held(retryAfter: wait)
                }
            }
            if !target.isFocused() {
                queue.abort(write.id, requeue: false, reason: .focusLost)
                return loseFocus()
            }
            run(write, before: before)
            collect()
            if isAwaitingReadback(write.id) { return unreadable() }
        }
    }

    /// How long the next write must wait for the typing guard, decided before it is issued (no version is
    /// spent on a write that does not run); nil when it may be taken now. The guard holds every non-user
    /// origin alike, so only an outstanding user edit (or a withdrawn one, to hand back) can run while it holds.
    private func holdBeforeIssuing() -> TimeInterval? {
        guard let typingGuard else { return nil }
        let wait = typingGuard.delay(for: .agent)
        guard wait > 0 else { return nil }
        let runnable = outstanding.contains { id, origin in
            (origin.isUser || withdrawn.contains(id)) && !awaitingReadback.contains(id)
        }
        return runnable ? nil : wait
    }

    // MARK: Running one write

    /// How a step went wrong, and so what the queue is told.
    private enum Fault {
        /// The call threw: hand the edit back.
        case failed(Conflict.Reason)
        /// The field is not what the step was planned on, or could not be checked: map it again and retry.
        case retry(Conflict.Reason)
    }

    private func run(_ write: FieldWrite, before: Read) {
        var expected = Array(before.text.utf16)
        var landed: [EditStep] = []
        for step in write.steps {  // application order: highest location first
            if let fault = runStep(step, expected: &expected) {
                fail(write, fault: fault, landed: landed, expected: expected, before: before)
                return
            }
            landed.append(step)
        }
        // The selection goes back where the queue put the caret. A field that refuses is read back as it is.
        try? target.select(selection(after: write, before: before))
        guard let after = Self.read(target) else {
            awaitingReadback.append(write.id)
            return
        }
        queue.settle(after.snapshot)
    }

    private func runStep(_ step: EditStep, expected: inout [UInt16]) -> Fault? {
        let range = UTF16Range(location: step.span.location, length: step.span.length)
        do { try target.select(range) } catch { return .failed(.writeFailed) }
        switch fieldHolds(expected, around: range) {
        case nil: return .retry(.unreadable)
        case false?: return .retry(.expectMismatch)
        case true?: break
        }
        do { try target.replace(range, with: step.text) } catch { return .failed(.writeFailed) }
        expected.replaceSubrange(range.location..<range.end, with: Array(step.text.utf16))
        return nil
    }

    private func fail(_ write: FieldWrite, fault: Fault, landed: [EditStep], expected: [UInt16], before: Read) {
        if !landed.isEmpty, !takeBack(landed, expected: expected) {
            // Part of the write is in the field and could not be taken back: the queue settles what it shows.
            restoreSelection(before)
            if let after = Self.read(target) {
                queue.settle(after.snapshot)
            } else {
                awaitingReadback.append(write.id)
            }
            return
        }
        restoreSelection(before)
        switch fault {
        case .failed(let reason):
            queue.abort(write.id, requeue: false, reason: reason)
        case .retry(let reason):
            let tries = (attempts[write.id] ?? 0) + 1
            attempts[write.id] = tries
            queue.abort(write.id, requeue: tries < Self.maxAttempts, reason: reason)
        }
    }

    /// Takes back the landed steps of one write, the last landed first, each an inverse write checked like a
    /// write (and mapped through a change the user made meanwhile); then the field must read as expected.
    /// False when a step cannot be taken back.
    private func takeBack(_ landed: [EditStep], expected: [UInt16]) -> Bool {
        var expected = expected
        for step in landed.reversed() {
            var span = Span(location: step.span.location, length: step.text.utf16.count)
            guard let current = Self.readAll(target) else { return false }
            let units = Array(current.utf16)
            if units != expected {
                guard let change = ContiguousPatch.between(String(decoding: expected, as: UTF16.self), current, at: 0),
                    case .moved(let moved) = StepMap(change).map(span)
                else { return false }
                span = moved
                expected = units
            }
            let range = UTF16Range(location: span.location, length: span.length)
            guard (try? target.select(range)) != nil, fieldHolds(expected, around: range) == true,
                (try? target.replace(range, with: step.expect)) != nil
            else { return false }
            expected.replaceSubrange(range.location..<range.end, with: Array(step.expect.utf16))
        }
        guard let final = Self.readAll(target) else { return false }
        return Array(final.utf16) == expected
    }

    /// Whether the field is still the text a write was planned on, as far as `range` goes: the same length
    /// (nothing before it moved) and the same units in it and in a context window around it, so an insertion
    /// point is checked too. Nil when it cannot be read.
    private func fieldHolds(_ expected: [UInt16], around range: UTF16Range) -> Bool? {
        guard let length = try? target.length() else { return nil }
        guard length == expected.count, range.location >= 0, range.end <= expected.count else { return false }
        let lower = max(0, range.location - Self.checkContext)
        let upper = min(expected.count, range.end + Self.checkContext)
        guard let text = try? target.text(in: UTF16Range(location: lower, length: upper - lower)) else { return nil }
        return text.utf16.elementsEqual(expected[lower..<upper])
    }

    // MARK: The user's selection

    /// Where the selection goes after `write`: the queue's caret, extended over the user's ranged selection
    /// (mapped through the write) when the edit set no caret of its own.
    private func selection(after write: FieldWrite, before: Read) -> UTF16Range {
        let caret = UTF16Range(location: write.caret, length: 0)
        guard keepsSelection.contains(write.id), before.selection.length > 0 else { return caret }
        let end = write.steps.reduce(before.selection.end) { StepMap($1).map(position: $0, bias: .before) }
        return end > write.caret ? UTF16Range(location: write.caret, length: end - write.caret) : caret
    }

    /// Puts the user's selection from `before` back, mapped through what changed in the field since.
    private func restoreSelection(_ before: Read) {
        var selection = before.selection
        if let now = Self.readAll(target), !now.utf8.elementsEqual(before.text.utf8),
            let change = ContiguousPatch.between(before.text, now, at: 0)
        {
            let map = StepMap(change)
            let start = map.map(position: selection.location, bias: .after)
            let end = max(start, map.map(position: selection.end, bias: .after))
            selection = UTF16Range(location: start, length: end - start)
        }
        try? target.select(selection)
    }

    // MARK: Field faults

    private func loseFocus() -> DrainResult {
        if queue.hasPending || !awaitingReadback.isEmpty {
            let snapshot =
                Self.read(target)?.snapshot
                ?? FieldSnapshot(window: queue.document.window, caret: queue.document.caret, windowBase: 0)
            queue.reset(snapshot, reason: .focusChanged)
        }
        collect()
        awaitingReadback = []
        return .blocked(.focusLost)
    }

    /// A read failed: retry later, or after too many in a row hand back the writes awaiting readback and the
    /// pending edits (nothing can be checked).
    private func unreadable() -> DrainResult {
        unreadableReads += 1
        if unreadableReads < Self.maxUnreadableReads {
            return .unreadable(retryAfter: Self.unreadableRetryDelay * Double(1 << (unreadableReads - 1)))
        }
        unreadableReads = 0
        // Aborting the oldest unverified write rolls the later ones back into the queue.
        if let oldest = awaitingReadback.first { queue.abort(oldest, requeue: false, reason: .unreadable) }
        awaitingReadback = []
        while let write = queue.next() { queue.abort(write.id, requeue: false, reason: .unreadable) }
        collect()
        return .blocked(.unreadable)
    }

    /// Moves the queue's events into the per-transaction buffer and forgets what has an outcome.
    private func collect() {
        for event in queue.takeEvents() {
            let id = event.transactionID
            let dropped = withdrawn.remove(id) != nil
            outstanding[id] = nil
            keepsSelection.remove(id)
            attempts[id] = nil
            awaitingReadback.removeAll { $0 == id }
            if !dropped { events.append(event) }
        }
    }

    // MARK: Reading

    private struct Read {
        var text: String
        var selection: UTF16Range
        var snapshot: FieldSnapshot { FieldSnapshot(window: text, caret: selection.location, windowBase: 0) }
    }

    private static func read(_ target: any TextTarget) -> Read? {
        guard let selection = try? target.selectedRange(), let text = readAll(target) else { return nil }
        return Read(text: text, selection: selection)
    }

    /// The whole field, by its length.
    private static func readAll(_ target: any TextTarget) -> String? {
        guard let length = try? target.length(), length >= 0, length <= maxFieldLength,
            let text = try? target.text(in: UTF16Range(location: 0, length: length)), text.utf16.count == length
        else { return nil }
        return text
    }

    /// Whether the field reads exactly as the queue left it: a notification for it is our own write's echo.
    private func fieldMatchesQueue() -> Bool {
        guard let read = Self.read(target) else { return false }
        return read.snapshot.window.utf8.elementsEqual(queue.document.window.utf8) && read.snapshot.caret == queue.document.caret
    }
}

extension QueueEvent {
    fileprivate var transactionID: UUID {
        switch self {
        case .applied(let id, _), .superseded(let id, _), .conflict(let id, _), .withdrawn(let id): id
        }
    }
}
