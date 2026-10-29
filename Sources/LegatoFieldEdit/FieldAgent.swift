import Foundation

/// A source that reads the change feed and proposes edits (the cleanup agent, later tools and the voice agent).
public protocol FieldAgent: Sendable {
    /// Takes in a feed batch and returns the edits it wants made, based on `batch.version`.
    func consume(_ batch: FeedBatch) async -> [EditTransaction]
    /// One of its edits was handed back.
    func conflicted(_ conflict: Conflict, for transaction: UUID) async
    /// One of its edits was overtaken by its own edit `landed`; re-plan from the feed.
    func superseded(_ transaction: UUID, by landed: UUID) async
}

extension FieldAgent {
    public func superseded(_ transaction: UUID, by landed: UUID) async {}
}
