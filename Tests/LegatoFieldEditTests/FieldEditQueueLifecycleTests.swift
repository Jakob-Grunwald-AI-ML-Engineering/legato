import Foundation
import Testing
import LegatoFieldEdit

/// Review findings B2–B6: the feed's wire format, bounded growth, aborted writes and queue identity.
@Suite struct FieldEditQueueLifecycleTests {
    let v0 = FieldVersion(0)

    // MARK: B2 superseded on the feed

    @Test func coalescedTicksAreSupersededOnTheFeed() {
        var field = ""
        var queue = macQueue(field)
        let tick1 = EditTransaction(origin: .asr, owner: "run", base: v0, steps: [.insert("Hel", at: 0)], coalesce: "reveal")
        let tick2 = EditTransaction(origin: .asr, owner: "run", base: v0, steps: [.insert("Hello", at: 0)], coalesce: "reveal")
        queue.submit(tick1)
        queue.submit(tick2)
        queue.drain(&field)
        #expect(queue.feed.entries.first?.event == .superseded(tick1.id, by: tick2.id))
    }

    @Test func sameOwnerOverlapIsSupersededOnTheFeed() {
        var field = "hello wor"
        var queue = macQueue(field)
        let cleanup = EditTransaction(origin: .agent, owner: "run", base: v0, steps: [replace(6, "wor", with: "war")])
        let revision = EditTransaction(origin: .asr, owner: "run", base: v0, steps: [replace(6, "wor", with: "world")])
        queue.submit(cleanup)
        queue.submit(revision)
        queue.drain(&field)
        #expect(queue.feed.entries.contains { $0.event == .superseded(cleanup.id, by: revision.id) })
    }

    @Test func everyFeedEventSurvivesACodableRoundTrip() throws {
        let id = UUID(), other = UUID()
        let events: [FeedEvent] = [
            .asrDelta("hi"),
            .applied(id, origin: .agent, steps: [.insert("x", at: 0)], version: FieldVersion(1)),
            .foreign(.insert("y", at: 1), byUser: true, version: FieldVersion(2)),
            .conflict(id, Conflict(.overlap, byUser: true)),
            .superseded(id, by: other),
            .rebased(window: "abc", shift: -2, version: FieldVersion(3)),
            .reset(.cleared, window: "", version: FieldVersion(4)),
        ]
        let decoded = try JSONDecoder().decode([FeedEvent].self, from: JSONEncoder().encode(events))
        #expect(decoded == events)
        #expect(events.map(\.version) == [nil, FieldVersion(1), FieldVersion(2), nil, nil, FieldVersion(3), FieldVersion(4)])
    }

    // MARK: B3 bounded growth, B4 rebuilding mid-stream

    @Test func aTrimmedFeedResyncsReadersOlderThanItKeeps() {
        var field = "a"
        var queue = macQueue(field)
        queue.hostEdit(&field, to: "ab")
        queue.hostEdit(&field, to: "abc")
        queue.hostEdit(&field, to: "abcd")
        queue.trimFeed(through: 2)
        #expect(queue.feed.firstSeq == 3)
        #expect(queue.feed.entries.map(\.seq) == [3])
        #expect(queue.feed.lastSeq == 3)

        let current = queue.feed.since(2)
        #expect(!current.resync)
        #expect(current.entries.map(\.seq) == [3])

        let old = queue.feed.since(1)
        #expect(old.resync)
        #expect(old.window == "abcd")
        #expect(old.entries.isEmpty)
        #expect(old.version == FieldVersion(3))
        #expect(old.lastSeq == 3)
    }

    @Test func aReaderWithNothingRebuildsFromTheCurrentWindow() {
        var field = "hello"
        var queue = macQueue(field)
        let fresh = queue.feed.since(nil)
        #expect(fresh.resync)
        #expect(fresh.window == "hello")
        #expect(fresh.version == v0)
        #expect(fresh.lastSeq == 0)
        queue.hostEdit(&field, to: "hello!")
        #expect(queue.feed.since(nil).window == "hello!")
        #expect(queue.feed.since(nil).lastSeq == 1)
    }

    @Test func prunedHistoryRejectsOlderBasesAndStillMapsNewerOnes() {
        var field = "a"
        var queue = macQueue(field)
        queue.hostEdit(&field, to: "ab")
        queue.hostEdit(&field, to: "abc")
        queue.pruneHistory(before: FieldVersion(1))
        let stale = EditTransaction(origin: .agent, base: v0, steps: [.insert("x", at: 0)])
        let recent = EditTransaction(origin: .agent, base: FieldVersion(1), steps: [.insert("!", at: 1)])
        queue.submit(stale)
        queue.submit(recent)
        queue.drain(&field)
        #expect(field == "a!bc")
        #expect(queue.takeEvents().first == .conflict(stale.id, Conflict(.outOfWindow)))
    }

    // MARK: B5 aborted writes

    @Test func anAbortedWriteIsRequeuedAndMappedThroughWhatHappensNext() throws {
        var field = "hello"
        var queue = macQueue(field)
        let agent = EditTransaction(origin: .agent, owner: "agent", base: v0, steps: [.insert(" world", at: 5)])
        queue.submit(agent)
        let issued = queue.next()
        let write = try #require(issued)
        #expect(write.owner == "agent")
        queue.abort(write.id, requeue: true, reason: .writeFailed)
        #expect(queue.document.window == "hello")
        #expect(queue.document.version == queue.feed.version)
        queue.hostEdit(&field, to: "Oh hello", caret: 3)
        let writes = queue.drain(&field)
        #expect(writes.map(\.id) == [agent.id])
        #expect(writes.first?.steps == [.insert(" world", at: 8)])
        #expect(field == "Oh hello world")
        #expect(queue.takeEvents() == [.applied(agent.id, version: try #require(writes.first).version)])
    }

    @Test func anAbortedWriteThatIsNotRequeuedConflicts() throws {
        var queue = macQueue("hello")
        let agent = EditTransaction(origin: .agent, owner: "agent", base: v0, steps: [.insert(" world", at: 5)])
        queue.submit(agent)
        let issued = queue.next()
        let write = try #require(issued)
        queue.abort(write.id, requeue: false, reason: .focusLost)
        #expect(queue.takeEvents() == [.conflict(agent.id, Conflict(.focusLost))])
        #expect(queue.document.window == "hello")
        #expect(queue.document.version == queue.feed.version)
        #expect(queue.next() == nil)
        let late = EditTransaction(origin: .agent, base: write.version, steps: [.insert("!", at: 0)])
        queue.submit(late)
        #expect(queue.takeEvents() == [.conflict(late.id, Conflict(.outOfWindow))])
    }

    // MARK: B6 queue identity

    @Test func editsFromAnotherQueueOrAnUnknownVersionAreOutOfWindow() throws {
        var field = "abc"
        var queue = macQueue(field)
        let other = macQueue(field)
        #expect(queue.session != other.session)
        #expect(queue.feed.since(0).session == queue.session)
        let elsewhere = EditTransaction(origin: .agent, base: v0, steps: [.insert("x", at: 0)], session: other.session)
        let future = EditTransaction(origin: .agent, base: FieldVersion(7), steps: [.insert("y", at: 0)])
        let own = EditTransaction(origin: .agent, base: v0, steps: [.insert("z", at: 0)], session: queue.session)
        queue.submit(elsewhere)
        queue.submit(future)
        queue.submit(own)
        let writes = queue.drain(&field)
        #expect(field == "zabc")
        #expect(queue.takeEvents() == [
            .conflict(elsewhere.id, Conflict(.outOfWindow)),
            .conflict(future.id, Conflict(.outOfWindow)),
            .applied(own.id, version: try #require(writes.first).version),
        ])
    }
}
