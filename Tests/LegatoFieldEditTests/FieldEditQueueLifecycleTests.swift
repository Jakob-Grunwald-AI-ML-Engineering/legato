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

    // Text typed after a requeued write's text stays after it when the write replays.

    @Test func aKeystrokeTypedAfterARequeuedKeystrokeStaysAfterIt() {
        var field = "ab"
        var queue = macQueue(field)
        let x = EditTransaction(origin: .keystroke, base: v0, steps: [.insert("x", at: 2)])
        queue.submit(x)
        _ = queue.next()
        queue.submit(EditTransaction(origin: .keystroke, base: queue.document.version, steps: [.insert("y", at: 3)]))
        queue.abort(x.id, requeue: true, reason: .writeFailed)
        queue.drain(&field)
        #expect(field == "abxy")
    }

    @Test func anAgentEditAfterARequeuedAgentWriteStaysAfterIt() {
        var field = "hello"
        var queue = macQueue(field)
        let world = EditTransaction(origin: .agent, owner: "agent", base: v0, steps: [.insert(" world", at: 5)])
        queue.submit(world)
        _ = queue.next()
        queue.submit(EditTransaction(origin: .agent, owner: "other", base: queue.document.version, steps: [.insert("!", at: 11)]))
        queue.abort(world.id, requeue: true, reason: .unreadable)
        queue.drain(&field)
        #expect(field == "hello world!")
    }

    @Test func abortingTheMiddleOfThreeWritesKeepsTheirOrder() {
        var field = "ab ab"
        var queue = macQueue(field)
        queue.submit(EditTransaction(origin: .liveCleanup, owner: "c", base: v0, steps: [.insert("!", at: 2)]))
        let k1 = EditTransaction(origin: .keystroke, base: v0, steps: [.insert("x", at: 5)])
        queue.submit(k1)
        _ = queue.next()
        let k2 = EditTransaction(origin: .keystroke, base: queue.document.version, steps: [.insert("y", at: 6)])
        queue.submit(k2)
        _ = queue.next()
        queue.submit(EditTransaction(origin: .keystroke, base: queue.document.version, steps: [.insert("z", at: 7)]))
        _ = queue.next()
        field = "ab abx"
        queue.abort(k2.id, requeue: true, reason: .writeFailed)
        queue.settle(FieldSnapshot(window: field, caret: 6, windowBase: 0))
        queue.drain(&field)
        #expect(field == "ab! abxyz")
    }

    /// ASR binds after foreign text at its insertion point, but text in front of a requeued write stays in front.
    @Test func anASRInsertBeforeARequeuedReplacementStaysBeforeIt() {
        var field = "ab cd"
        var queue = macQueue(field)
        let fix = EditTransaction(origin: .agent, owner: "agent", base: v0, steps: [replace(3, "cd", with: "CD!")])
        queue.submit(fix)
        _ = queue.next()
        queue.submit(EditTransaction(origin: .asr, owner: "run", base: queue.document.version, steps: [.insert("<", at: 3)]))
        queue.submit(EditTransaction(origin: .asr, owner: "run2", base: queue.document.version, steps: [.insert(">", at: 6)]))
        queue.abort(fix.id, requeue: true, reason: .writeFailed)
        queue.drain(&field)
        #expect(field == "ab <CD!>")
    }

    /// A keystroke preempts the requeued ASR write it was typed after; it still ends up after the ASR text.
    @Test func aKeystrokeRunningBeforeTheRequeuedWriteItFollowsStaysAfterIt() {
        var field = "hello"
        var queue = macQueue(field)
        let asr = EditTransaction(origin: .asr, owner: "run", base: v0, steps: [.insert(" world", at: 5)])
        queue.submit(asr)
        _ = queue.next()
        let key = EditTransaction(origin: .keystroke, base: queue.document.version, steps: [.insert("!", at: 11)])
        queue.submit(key)
        queue.abort(asr.id, requeue: true, reason: .writeFailed)
        let writes = queue.drain(&field)
        #expect(writes.map(\.id) == [key.id, asr.id])
        #expect(field == "hello world!")
    }

    /// A conflict of one queued edit never blocks or drops the others.
    @Test func aPendingEditWhoseNeighbourConflictsIsStillIssued() {
        var field = "one two three"
        var queue = macQueue(field)
        let stale = EditTransaction(origin: .agent, owner: "a", base: v0, steps: [replace(4, "tw0", with: "TWO")])
        let first = EditTransaction(origin: .agent, owner: "b", base: v0, steps: [replace(0, "one", with: "One")])
        let last = EditTransaction(origin: .agent, owner: "c", base: v0, steps: [replace(8, "three", with: "Three")])
        queue.submit(first)
        queue.submit(stale)
        queue.submit(last)
        queue.submit(EditTransaction(origin: .keystroke, base: v0, steps: [replace(0, "one", with: "uno")]))
        queue.drain(&field)
        #expect(field == "uno two Three")
        let events = queue.takeEvents()
        #expect(events.contains(.conflict(first.id, Conflict(.overlap, intervening: replace(0, "one", with: "uno"), byUser: true))))
        #expect(events.contains(.conflict(stale.id, Conflict(.expectMismatch))))
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
