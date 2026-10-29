import Foundation
import Testing
import LegatoFieldEdit

/// Host reads that arrive in pieces: multi-step writes that land in part, the iOS proxy's intermediate states
/// (after the caret move, during the delete) and stale reads.
@Suite struct FieldEditQueueAsyncReadTests {
    let v0 = FieldVersion(0)

    private func appliedSteps(_ queue: FieldEditQueue, _ id: UUID) -> [[EditStep]] {
        queue.feed.entries.compactMap { entry in
            if case .applied(id, _, let steps, _) = entry.event { steps } else { nil }
        }
    }

    // MARK: Partial confirmation of a multi-step write

    /// "u and u ok": one write fixes both "u"s; the read shows only the second fix. That step is confirmed,
    /// only the missing one fails, and the pending edit is mapped through what landed.
    @Test func aWriteThatLandedInPartConfirmsTheLandedStepsAndFailsTheRest() throws {
        var queue = macQueue("u and u ok")
        let fix = EditTransaction(
            origin: .agent, owner: "agent", base: v0,
            steps: [replace(0, "u", with: "you"), replace(6, "u", with: "you")])
        let mark = EditTransaction(origin: .liveCleanup, owner: "run", base: v0, steps: [.insert("!", at: 10)])
        queue.submit(fix)
        queue.submit(mark)
        #expect(queue.next()?.id == fix.id)
        #expect(queue.settle(FieldSnapshot(window: "u and you ok", caret: 12, windowBase: 0)) == .diverged)
        #expect(queue.takeEvents() == [
            .applied(fix.id, version: queue.document.version),
            .conflict(fix.id, Conflict(.verifyFailed)),
        ])
        #expect(appliedSteps(queue, fix.id) == [[replace(6, "u", with: "you")]])
        #expect(queue.document.window == "u and you ok")
        #expect(queue.document.owned == [OwnedSpan(owner: "agent", span: Span(location: 6, length: 3))])
        #expect(queue.next()?.steps == [.insert("!", at: 12)])
    }

    /// Repeated text: inserting "a" at 1 and at 2 of "xay" gives the same field whichever insert landed, so one
    /// step is confirmed and one fails; nothing resets.
    @Test func aPartialWriteOfRepeatedTextConfirmsOneStep() {
        var queue = macQueue("xay")
        let write = EditTransaction(origin: .tool, base: v0, steps: [.insert("a", at: 1), .insert("a", at: 2)])
        queue.submit(write)
        _ = queue.next()
        #expect(queue.settle(FieldSnapshot(window: "xaay", caret: 4, windowBase: 0)) == .diverged)
        #expect(queue.takeEvents() == [
            .applied(write.id, version: queue.document.version),
            .conflict(write.id, Conflict(.verifyFailed)),
        ])
        #expect(appliedSteps(queue, write.id).map(\.count) == [1])
        #expect(queue.document.window == "xaay")
        #expect(!queue.feed.entries.contains { if case .reset = $0.event { true } else { false } })
        #expect(!queue.feed.entries.contains { if case .foreign = $0.event { true } else { false } })
    }

    /// A write and a later keystroke: the write landed in part, the keystroke fully.
    @Test func aPartialWriteBeforeALandedKeystrokeKeepsTheKeystroke() {
        var queue = macQueue("u and u")
        let fix = EditTransaction(
            origin: .agent, owner: "agent", base: v0,
            steps: [replace(0, "u", with: "you"), replace(6, "u", with: "you")])
        queue.submit(fix)
        _ = queue.next()
        let key = EditTransaction(origin: .keystroke, base: queue.document.version, steps: [.insert("!", at: 11)])
        queue.submit(key)
        _ = queue.next()
        #expect(queue.settle(FieldSnapshot(window: "you and u!", caret: 10, windowBase: 0)) == .diverged)
        let events = queue.takeEvents()
        #expect(events.count == 3)
        #expect(events.first.map { if case .applied(fix.id, _) = $0 { true } else { false } } == true)
        #expect(events.dropFirst().first == .conflict(fix.id, Conflict(.verifyFailed)))
        #expect(events.last == .applied(key.id, version: queue.document.version))
        #expect(appliedSteps(queue, fix.id) == [[replace(0, "u", with: "you")]])
        #expect(queue.document.window == "you and u!")
    }

    // MARK: Intermediate states of the iOS op sequence (non-final reads)

    /// iOS writes the higher step first: a read showing only it is the write in progress, not a failure.
    @Test func aReadShowingTheFirstAppliedStepOnlyIsInProgress() {
        var queue = FieldEditQueue(FieldSnapshot(before: "u and u ok", after: ""))
        let fix = EditTransaction(
            origin: .agent, owner: "agent", base: v0,
            steps: [replace(0, "u", with: "you"), replace(6, "u", with: "you")])
        queue.submit(fix)
        _ = queue.next()
        let predicted = queue.document
        #expect(queue.settle(FieldSnapshot(before: "u and you", after: " ok"), final: false) == .notYet)
        #expect(queue.settle(FieldSnapshot(before: "u", after: " and you ok"), final: false) == .notYet)
        #expect(queue.takeEvents().isEmpty)
        #expect(queue.document == predicted)
        #expect(queue.settle(queue.predicted, final: false) == .confirmed)
        #expect(queue.takeEvents() == [.applied(fix.id, version: predicted.version)])
    }

    /// "teh| cat" → "the cat": the proxy moves the caret, deletes "teh" Character by Character, inserts "the".
    /// Reads during the delete are the write in progress: never a user delete, a rollback or a reset.
    @Test(arguments: [
        FieldSnapshot(before: "te", after: " cat"),
        FieldSnapshot(before: "t", after: " cat"),
        FieldSnapshot(before: "", after: " cat"),
    ])
    func aReadDuringTheDeleteIsInProgress(_ read: FieldSnapshot) {
        var queue = FieldEditQueue(FieldSnapshot(before: "teh cat", after: ""))
        let fix = EditTransaction(origin: .liveCleanup, owner: "run", base: v0, steps: [replace(0, "teh", with: "the")])
        queue.submit(fix)
        _ = queue.next()
        let predicted = queue.document
        let feed = queue.feed
        #expect(queue.settle(read, final: false) == .notYet)
        #expect(queue.takeEvents().isEmpty)
        #expect(queue.document == predicted)
        #expect(queue.feed == feed)
        #expect(queue.settle(FieldSnapshot(before: "the", after: " cat"), final: false) == .confirmed)
        #expect(queue.document.window == "the cat")
    }

    /// The intermediate states of a later write wait. "| cats" is also the field before the keystroke with the
    /// text before the caret deleted on the host, so not even the earlier write is confirmed yet.
    @Test func aReadDuringTheSecondWritesDeleteWaitsWithoutConfirming() {
        var queue = FieldEditQueue(FieldSnapshot(before: "teh cat", after: ""))
        let key = EditTransaction(origin: .keystroke, base: v0, steps: [.insert("s", at: 7)])
        queue.submit(key)
        _ = queue.next()
        let fix = EditTransaction(origin: .liveCleanup, owner: "run", base: queue.document.version, steps: [replace(0, "teh", with: "the")])
        queue.submit(fix)
        _ = queue.next(for: fix.id)
        #expect(queue.settle(FieldSnapshot(before: "", after: " cats"), final: false) == .notYet)
        #expect(queue.takeEvents().isEmpty)
        #expect(queue.document.window == "the cats")
        #expect(queue.settle(queue.predicted) == .confirmed)
        #expect(queue.takeEvents().first == .applied(key.id, version: FieldVersion(1)))
    }

    /// A non-final read no prediction or intermediate state explains changes nothing: the next read decides.
    @Test func anUnexplainedNonFinalReadLeavesTheQueueUntouched() {
        var queue = FieldEditQueue(FieldSnapshot(before: "teh cat", after: ""))
        let fix = EditTransaction(origin: .liveCleanup, owner: "run", base: v0, steps: [replace(0, "teh", with: "the")])
        let later = EditTransaction(origin: .agent, owner: "agent", base: v0, steps: [.insert("!", at: 7)])
        queue.submit(fix)
        _ = queue.next()
        queue.submit(later)
        let predicted = queue.document
        let feed = queue.feed
        #expect(queue.settle(FieldSnapshot(before: "zz", after: "qq"), final: false) == .notYet)
        #expect(queue.takeEvents().isEmpty)
        #expect(queue.document == predicted)
        #expect(queue.feed == feed)
        #expect(queue.settle(queue.predicted, final: false) == .confirmed)
        #expect(queue.next()?.steps == [.insert("!", at: 7)])
    }

    // MARK: Stale final reads

    /// A final read identical to the field before the write may be the proxy not having caught up: with
    /// `tolerateStale` it is reported as `.stale` and nothing fails; the executor waits once more.
    @Test func aStaleFinalReadIsReportedWithoutRollingBack() {
        var queue = FieldEditQueue(FieldSnapshot(before: "one two", after: ""))
        let key = EditTransaction(origin: .keystroke, base: v0, steps: [.insert("!", at: 7)])
        queue.submit(key)
        _ = queue.next()
        let predicted = queue.document
        let stale = FieldSnapshot(before: "one two", after: "")
        #expect(queue.settle(stale, tolerateStale: true) == .stale)
        #expect(queue.takeEvents().isEmpty)
        #expect(queue.document == predicted)
        #expect(queue.settle(FieldSnapshot(before: "one two!", after: ""), tolerateStale: true) == .confirmed)
        #expect(queue.takeEvents() == [.applied(key.id, version: predicted.version)])
    }

    /// The second stale read (settled without `tolerateStale`) is a real failure, as before.
    @Test func aStaleReadAfterTheExtendedWaitFails() {
        var queue = FieldEditQueue(FieldSnapshot(before: "one two", after: ""))
        let key = EditTransaction(origin: .keystroke, base: v0, steps: [.insert("!", at: 7)])
        queue.submit(key)
        _ = queue.next()
        let stale = FieldSnapshot(before: "one two", after: "")
        #expect(queue.settle(stale, tolerateStale: true) == .stale)
        #expect(queue.settle(stale) == .diverged)
        #expect(queue.takeEvents() == [.conflict(key.id, Conflict(.verifyFailed))])
        #expect(queue.document.window == "one two")
    }

    /// A stale read that shows the older writes confirms those and reports the rest stale.
    @Test func aStaleReadShowingTheOlderWritesConfirmsThem() {
        var queue = FieldEditQueue(FieldSnapshot(before: "one two", after: ""))
        let key1 = EditTransaction(origin: .keystroke, base: v0, steps: [.insert("!", at: 7)])
        queue.submit(key1)
        _ = queue.next()
        let key2 = EditTransaction(origin: .keystroke, base: queue.document.version, steps: [.insert("?", at: 8)])
        queue.submit(key2)
        _ = queue.next()
        #expect(queue.settle(FieldSnapshot(before: "one two!", after: ""), tolerateStale: true) == .stale)
        #expect(queue.takeEvents() == [.applied(key1.id, version: FieldVersion(1))])
        #expect(queue.document.window == "one two!?")
    }
}
