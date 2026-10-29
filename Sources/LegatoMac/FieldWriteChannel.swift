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
}

/// Today's path: straight to the target.
@MainActor
public final class DirectFieldWriteChannel: FieldWriteChannel {
    private let target: any TextTarget

    public init(target: any TextTarget) { self.target = target }

    public func replace(_ range: UTF16Range, with text: String, expect: String?, origin: EditOrigin) throws {
        try target.replace(range, with: text)
    }
}

/// Sends each replace through the field edit queue and runs it at once with ``AXFieldExecutor/drain(only:)``
/// (the writer is synchronous and cannot wait for the typing guard), so the executor's checks and readback
/// apply and the queue sees every landed change. Only this write runs: held agent and cleanup edits stay
/// queued and their events stay with the executor for their sources.
///
/// - The edit is planned on the field as the writer just checked it: a fresh read is observed first, the
///   edit's `base` is the version it leaves, and `expect` is the writer's belief, so a change the user makes
///   after that read maps the edit (or conflicts it) instead of being written over.
/// - Automatic writes run in the ASR lane whatever their origin (the run's writer must not queue behind held
///   cleanup-lane edits); the origin keeps its insert bias and the run's ownership. User picks run in the
///   user lane, unowned.
/// - Throws ``Rejected`` when the write did not run. A write that ran but whose readback disagrees or could
///   not be read returns normally: the writer's own readback decides what landed, as on the direct path.
@MainActor
public final class QueuedFieldWriteChannel: FieldWriteChannel {
    public struct Rejected: Error, Equatable {
        public var reason: Conflict.Reason
    }

    private let executor: AXFieldExecutor
    private let owner: String

    public init(executor: AXFieldExecutor, owner: String) {
        self.executor = executor
        self.owner = owner
    }

    public func replace(_ range: UTF16Range, with text: String, expect: String?, origin: EditOrigin) throws {
        guard executor.refresh() else { throw Rejected(reason: .unreadable) }
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
            origin: origin, owner: origin.isUser ? nil : owner, base: executor.queue.document.version, steps: [step],
            caret: range.location + text.utf16.count)
        executor.submit(transaction, lane: origin.isUser ? nil : .asr)
        executor.drain(only: transaction.id)
        for event in executor.takeEvents(for: transaction.id) {
            switch event {
            case .applied: return
            case .conflict(_, let conflict) where conflict.reason == .verifyFailed: return
            case .conflict(_, let conflict): throw Rejected(reason: conflict.reason)
            case .superseded: throw Rejected(reason: .overlap)
            }
        }
        if executor.isAwaitingReadback(transaction.id) { return }
        // It did not run (the field faulted, or another automatic edit was ahead of it): it must never land later.
        executor.withdraw(transaction.id)
        throw Rejected(reason: .unreadable)
    }
}
