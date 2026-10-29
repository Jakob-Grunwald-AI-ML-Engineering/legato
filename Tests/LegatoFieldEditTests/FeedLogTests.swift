import Foundation
import Testing
import LegatoFieldEdit

@Suite struct FeedLogTests {
    let v0 = FieldVersion(0)

    @Test func eventsAreSeqNumberedFromOneInLandingOrder() {
        var field = "teh end"
        var queue = macQueue(field)
        queue.appendASR(" more")
        let fix = EditTransaction(origin: .agent, owner: "run", base: v0, steps: [replace(0, "teh", with: "the")])
        let stale = EditTransaction(origin: .agent, owner: "run", base: v0, steps: [replace(4, "xyz", with: "end")])
        queue.submit(fix)
        queue.submit(stale)
        queue.drain(&field)
        queue.hostEdit(&field, to: "the end!")
        queue.reset(FieldSnapshot(window: "", caret: 0, windowBase: 0), reason: .focusChanged)

        #expect(queue.feed.entries.map(\.seq) == [1, 2, 3, 4, 5])
        #expect(queue.feed.entries.map(\.event) == [
            .asrDelta(" more"),
            .applied(fix.id, origin: .agent, steps: [replace(0, "teh", with: "the")], version: FieldVersion(1)),
            .conflict(stale.id, Conflict(.expectMismatch)),
            .foreign(.insert("!", at: 7), byUser: true, version: FieldVersion(2)),
            .reset(.focusChanged, window: "", version: FieldVersion(3)),
        ])
    }

    @Test func sinceReturnsOnlyLaterEntriesAndTheVersionToBaseOn() {
        var field = "a"
        var queue = macQueue(field)
        queue.hostEdit(&field, to: "ab")
        let seen = queue.feed.lastSeq
        queue.hostEdit(&field, to: "abc")
        let batch = queue.feed.since(seen)
        #expect(batch.entries.map(\.seq) == [2])
        #expect(batch.lastSeq == 2)
        #expect(batch.version == FieldVersion(2))
        #expect(queue.feed.since(batch.lastSeq!).entries.isEmpty)
    }

    @Test func writesReachTheFeedOnlyOnceAReadConfirmsThem() {
        var queue = macQueue("x")
        queue.submit(EditTransaction(origin: .agent, base: v0, steps: [.insert("y", at: 1)]))
        _ = queue.next()
        #expect(queue.feed.entries.isEmpty)
        #expect(queue.feed.version == v0)
        queue.settle(queue.predicted)
        #expect(queue.feed.entries.count == 1)
        #expect(queue.feed.version == FieldVersion(1))
    }

    @Test func failedWritesAndTheirUndoStayOffTheFeed() {
        var queue = macQueue("x")
        let write = EditTransaction(origin: .agent, base: v0, steps: [.insert("y", at: 1)])
        queue.submit(write)
        _ = queue.next()
        queue.settle(FieldSnapshot(window: "x", caret: 1, windowBase: 0))
        #expect(queue.feed.entries.map(\.event) == [.conflict(write.id, Conflict(.verifyFailed))])
        #expect(queue.feed.version == v0)
    }

    @Test func batchesSurviveACodableRoundTrip() throws {
        var field = "a"
        var queue = macQueue(field)
        queue.hostEdit(&field, to: "ab")
        queue.reset(FieldSnapshot(before: "", after: ""), reason: .cleared)
        let batch = queue.feed.since(0)
        let decoded = try JSONDecoder().decode(FeedBatch.self, from: JSONEncoder().encode(batch))
        #expect(decoded == batch)
    }
}
