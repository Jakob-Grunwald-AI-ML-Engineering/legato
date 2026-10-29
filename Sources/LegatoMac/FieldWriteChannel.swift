import Foundation
import LegatoFieldEdit

/// Where ``FieldWriter`` sends its replace operations. Reads stay on the `TextTarget`.
@MainActor
public protocol FieldWriteChannel: AnyObject {
    /// Replaces `range` with `text`, leaving the caret after the inserted text; throws when it did not run.
    func replace(_ range: UTF16Range, with text: String) throws
}

/// Today's path: straight to the target.
@MainActor
public final class DirectFieldWriteChannel: FieldWriteChannel {
    private let target: any TextTarget

    public init(target: any TextTarget) { self.target = target }

    public func replace(_ range: UTF16Range, with text: String) throws {
        try target.replace(range, with: text)
    }
}

/// Sends each replace through the field edit queue as an ASR-lane edit and drains it at once (guard ignored: the
/// writer is synchronous and cannot wait), so the executor's checks and readback apply and the queue sees every
/// landed change. Throws when the queue handed the edit back.
@MainActor
public final class QueuedFieldWriteChannel: FieldWriteChannel {
    public struct Rejected: Error, Equatable {
        public var reason: Conflict.Reason
    }

    private let executor: AXFieldExecutor
    private let owner: String
    private let origin: EditOrigin

    public init(executor: AXFieldExecutor, owner: String, origin: EditOrigin = .asr) {
        self.executor = executor
        self.owner = owner
        self.origin = origin
    }

    public func replace(_ range: UTF16Range, with text: String) throws {
        let expect = range.length == 0 ? "" : try executor.target.text(in: range)
        let step = EditStep(span: Span(location: range.location, length: range.length), text: text, expect: expect)
        let transaction = EditTransaction(
            origin: origin, owner: owner, base: executor.queue.document.version, steps: [step],
            caret: range.location + text.utf16.count)
        executor.submit(transaction)
        executor.drain(ignoringGuard: true)
        for event in executor.takeEvents() {
            switch event {
            case .applied(let id, _) where id == transaction.id: return
            case .conflict(let id, let conflict) where id == transaction.id: throw Rejected(reason: conflict.reason)
            default: continue
            }
        }
        throw Rejected(reason: .unreadable)
    }
}
