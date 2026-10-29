import Foundation
import LegatoFieldEdit

/// Where ``FieldWriter`` sends its replace operations. Reads stay on the `TextTarget`.
@MainActor
public protocol FieldWriteChannel: AnyObject {
    /// Replaces `range` with `text`, leaving the caret after the inserted text; throws when it did not run.
    ///
    /// `range` is in the field as the writer just checked it; `expect` is what the writer believes `range`
    /// holds (nil: it does not know, the first write over the user's selection when that could not be read).
    /// `origin` is what the write is: the run's text (`.asr`, `.hold`), a live cleanup revision
    /// (`.liveCleanup`), the cleaned text swapped in at the end (`.finalSwap`), a version the user picked
    /// (`.versions`).
    func replace(_ range: UTF16Range, with text: String, expect: String?, origin: EditOrigin) throws

    /// ``replace(_:with:expect:origin:)`` where the writer also knows the text it just checked right before
    /// `range.location` (`preceding`, nil when it checked none). A channel that learns of the field later than the
    /// writer checked it can tell whether `range` still follows that text.
    func replace(_ range: UTF16Range, with text: String, expect: String?, preceding: String?, origin: EditOrigin) throws
}

extension FieldWriteChannel {
    public func replace(_ range: UTF16Range, with text: String, expect: String?, origin: EditOrigin) throws {
        try replace(range, with: text, expect: expect, preceding: nil, origin: origin)
    }
}

/// Today's path: straight to the target.
@MainActor
public final class DirectFieldWriteChannel: FieldWriteChannel {
    private let target: any TextTarget

    public init(target: any TextTarget) { self.target = target }

    public func replace(
        _ range: UTF16Range, with text: String, expect: String?, preceding: String?, origin: EditOrigin
    ) throws {
        try target.replace(range, with: text)
    }
}

/// Sends each replace through the field edit queue and runs it at once with ``AXFieldExecutor/drain(only:)``
/// (the writer is synchronous and cannot wait for the typing guard), so the executor's checks and readback
/// apply and the queue sees every landed change. Only this write runs: held agent and cleanup edits stay
/// queued and their events stay with the executor for their sources.
///
/// - Every write has its real origin and that origin's lane (`.asr`/`.hold` in the ASR lane, `.liveCleanup` and
///   `.finalSwap` in the cleanup lane, a user pick in the user lane, unowned), so the typing guard can tell them
///   apart: a cleanup write while the user types is not issued at all (``Held``, nothing queued, no version
///   spent) and the writer tries again with its next revision. The run's own text is never held.
/// - The channel runs its own edit with `next(for:)` and withdraws it if the writer gives up.
/// - The edit is planned on the field as the writer checked it, not as it is when the channel first looks: a fresh
///   read is observed first; when the writer says what it saw before the range (`preceding`) and the queue's
///   earlier view shows that there, the edit is planned on that earlier version, so the queue maps it through
///   whatever the user typed since (a write is never landed off by the typed length). Only when that view does not
///   match is the fresh one used, and when neither matches the edit is rejected as an `expectMismatch`.
/// - Throws ``Rejected`` when the write did not run. A write that ran but whose readback disagrees or could
///   not be read returns normally: the writer's own readback decides what landed, as on the direct path.
@MainActor
public final class QueuedFieldWriteChannel: FieldWriteChannel {
    public struct Rejected: Error, Equatable {
        public var reason: Conflict.Reason
    }

    /// The write was not issued because the user is typing and the write is cleanup; nothing is queued.
    public struct Held: Error, Equatable {
        public var retryAfter: TimeInterval
    }

    private let executor: AXFieldExecutor
    private let owner: String

    public init(executor: AXFieldExecutor, owner: String) {
        self.executor = executor
        self.owner = owner
    }

    public func replace(
        _ range: UTF16Range, with text: String, expect: String?, preceding: String?, origin: EditOrigin
    ) throws {
        let wait = executor.typingDelay(for: origin)
        if wait > 0 { throw Held(retryAfter: wait) }
        let known = executor.queue.document
        guard executor.refresh() else { throw Rejected(reason: .unreadable) }
        let fresh = executor.queue.document
        var base = fresh.version
        if let preceding {
            // The queue's earlier view wins when it matches: the writer may have checked before the typing that the
            // fresh read shows, and a fresh view that matches only by coincidence would misplace the edit. The
            // queue then maps it through whatever changed since.
            if Self.follows(preceding, at: range.location, in: known.window) {
                base = known.version
            } else if !Self.follows(preceding, at: range.location, in: fresh.window) {
                throw Rejected(reason: .expectMismatch)
            }
        }
        let believed: String
        if let expect {
            believed = expect
        } else if range.length == 0 {
            believed = ""
        } else {
            guard let read = try? executor.target.text(in: range) else { throw Rejected(reason: .unreadable) }
            believed = read
        }
        let step = EditStep(span: Span(location: range.location, length: range.length), text: text, expect: believed)
        let transaction = EditTransaction(
            origin: origin, owner: origin.isUser ? nil : owner, base: base, steps: [step],
            caret: range.location + text.utf16.count)
        executor.submit(transaction)
        executor.drain(only: transaction.id)
        for event in executor.takeEvents(for: transaction.id) {
            switch event {
            case .applied: return
            case .conflict(_, let conflict) where conflict.reason == .verifyFailed: return
            case .conflict(_, let conflict): throw Rejected(reason: conflict.reason)
            case .superseded: throw Rejected(reason: .overlap)
            case .withdrawn: throw Rejected(reason: .writeFailed)
            }
        }
        if executor.isAwaitingReadback(transaction.id) { return }
        // It did not run (the field faulted): it must never land later.
        executor.withdraw(transaction.id)
        throw Rejected(reason: .unreadable)
    }

    /// Whether `window` has `preceding` right before UTF-16 offset `location`.
    private static func follows(_ preceding: String, at location: Int, in window: String) -> Bool {
        let before = Array(preceding.utf16), units = Array(window.utf16)
        guard location >= before.count, location <= units.count else { return false }
        return units[(location - before.count)..<location].elementsEqual(before)
    }
}
