import Foundation
import Testing
import LegatoFieldEdit

/// Executor-side scheduling: inspecting the next write, holding lanes, issuing one transaction, withdrawing.
@Suite struct FieldEditQueueSchedulingTests {
    let v0 = FieldVersion(0)

    private func queueWithAgentAndASR() -> (FieldEditQueue, agent: EditTransaction, asr: EditTransaction) {
        var queue = macQueue("a b c")
        let agent = EditTransaction(origin: .agent, owner: "agent", base: v0, steps: [replace(4, "c", with: "C")])
        let asr = EditTransaction(origin: .asr, owner: "run", base: v0, steps: [.insert(" d", at: 5)])
        queue.submit(agent)
        queue.submit(asr)
        return (queue, agent, asr)
    }

    // MARK: peek

    @Test func peekShowsTheNextWriteWithoutIssuingIt() {
        var (queue, _, asr) = queueWithAgentAndASR()
        let before = queue.document
        let peeked = queue.peek()
        #expect(peeked?.id == asr.id)
        #expect(queue.document == before)
        #expect(queue.hasPending)
        #expect(queue.takeEvents().isEmpty)
        #expect(queue.next() == peeked)
    }

    @Test func peekOnlyLooksAtTheGivenLanes() {
        var (queue, agent, asr) = queueWithAgentAndASR()
        #expect(queue.peek(lanes: [.cleanup])?.id == agent.id)
        #expect(queue.peek(lanes: [.user])?.id == nil)
        #expect(queue.peek(lanes: [.user, .asr])?.id == asr.id)
        _ = queue.next(lanes: [.asr])
        #expect(queue.peek() == nil)  // automatic writes wait while one is unverified
    }

    // MARK: next(lanes:)

    @Test func holdingTheCleanupLaneNeitherIssuesNorConflictsIt() throws {
        var field = "a b c"
        var (queue, agent, asr) = queueWithAgentAndASR()
        let issued = queue.next(lanes: [.user, .asr])
        let write = try #require(issued)
        #expect(write.id == asr.id)
        field = execute(write, on: field)
        queue.settle(FieldSnapshot(window: field, caret: write.caret, windowBase: 0))
        let held = queue.document.version
        #expect(queue.next(lanes: [.user, .asr]) == nil)
        #expect(queue.document.version == held)
        #expect(queue.takeEvents() == [.applied(asr.id, version: held)])
        #expect(queue.next()?.id == agent.id)
    }

    // MARK: next(for:)

    @Test func issuingOneTransactionLeavesTheOthersQueuedInOrder() throws {
        var field = "one two three"
        var queue = macQueue(field)
        let held = EditTransaction(origin: .agent, owner: "agent", base: v0, steps: [replace(8, "three", with: "Three")])
        let asr = EditTransaction(origin: .asr, owner: "run", base: v0, steps: [.insert(" four", at: 13)])
        let own = EditTransaction(origin: .liveCleanup, owner: "run", base: v0, steps: [replace(0, "one", with: "ONE!")])
        queue.submit(held)
        queue.submit(asr)
        queue.submit(own)
        let issued = queue.next(for: own.id)
        let write = try #require(issued)
        #expect(write.id == own.id)
        #expect(write.lane == .cleanup)
        #expect(queue.takeEvents().isEmpty)
        field = execute(write, on: field)
        queue.settle(FieldSnapshot(window: field, caret: write.caret, windowBase: 0))
        let rest = queue.drain(&field)
        #expect(rest.map(\.id) == [asr.id, held.id])
        #expect(rest.first?.steps == [.insert(" four", at: 14)])
        #expect(field == "ONE! two Three four")
    }

    @Test func issuingAnUnknownOrIssuedTransactionReturnsNil() {
        var (queue, _, asr) = queueWithAgentAndASR()
        #expect(queue.next(for: UUID()) == nil)
        #expect(queue.next(for: asr.id)?.id == asr.id)
        #expect(queue.next(for: asr.id) == nil)
        #expect(queue.takeEvents().isEmpty)
    }

    /// The caller runs the named write now: it is issued even while a keystroke awaits its host read, and one
    /// read settles both.
    @Test func issuingOneTransactionRunsWhileAWriteIsUnverified() {
        var queue = FieldEditQueue(FieldSnapshot(before: "teh cat", after: ""))
        let key = EditTransaction(origin: .keystroke, base: v0, steps: [.insert("s", at: 7)])
        let own = EditTransaction(origin: .liveCleanup, owner: "run", base: v0, steps: [replace(0, "teh", with: "the")])
        queue.submit(own)
        queue.submit(key)
        #expect(queue.next()?.id == key.id)
        #expect(queue.next() == nil)
        #expect(queue.next(for: own.id)?.steps == [replace(0, "teh", with: "the")])
        #expect(queue.settle(queue.predicted) == .confirmed)
        #expect(queue.document.window == "the cats")
    }

    @Test func issuingOneTransactionThatFailsAGuardHandsItBack() {
        var queue = macQueue("abc")
        let stale = EditTransaction(origin: .liveCleanup, owner: "run", base: v0, steps: [replace(0, "xyz", with: "XYZ")])
        queue.submit(stale)
        #expect(queue.next(for: stale.id) == nil)
        #expect(queue.takeEvents() == [.conflict(stale.id, Conflict(.expectMismatch))])
        #expect(!queue.hasPending)
    }

    // MARK: withdraw

    @Test func aWithdrawnEditIsNeverWrittenAndItsSourceIsTold() {
        var field = "a b c"
        var (queue, agent, asr) = queueWithAgentAndASR()
        let withdrawn = queue.withdraw(agent.id)
        #expect(withdrawn)
        #expect(queue.takeEvents() == [.withdrawn(agent.id)])
        #expect(queue.feed.entries.last?.event == .withdrawn(agent.id))
        #expect(queue.drain(&field).map(\.id) == [asr.id])
        #expect(field == "a b c d")
        let again = queue.withdraw(agent.id)
        #expect(!again)
    }

    @Test func anIssuedWriteCannotBeWithdrawn() {
        var (queue, _, asr) = queueWithAgentAndASR()
        _ = queue.next()
        let withdrawn = queue.withdraw(asr.id)
        #expect(!withdrawn)
        #expect(queue.takeEvents().isEmpty)
        #expect(queue.settle(queue.predicted) == .confirmed)
    }

    @Test func theWithdrawnFeedEventSurvivesACodableRoundTrip() throws {
        let event = FeedEvent.withdrawn(UUID())
        #expect(try JSONDecoder().decode(FeedEvent.self, from: JSONEncoder().encode(event)) == event)
        #expect(event.version == nil)
    }
}
