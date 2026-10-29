import Foundation
import Testing
import LegatoFieldEdit

/// An agent write and two keystrokes issued before any host read: the agent's write is unverified when the user
/// lane writes, twice.
private struct ThreeUnverified {
    var queue = FieldEditQueue(FieldSnapshot(before: "one two", after: ""))
    let agent: EditTransaction
    let key1: EditTransaction
    let key2: EditTransaction
    /// The predicted windows after each write.
    var windows: [String] = []

    init() {
        agent = EditTransaction(origin: .agent, owner: "run", base: FieldVersion(0), steps: [replace(0, "one", with: "One")])
        queue.submit(agent)
        windows.append(queue.document.window)
        _ = queue.next()
        windows.append(queue.document.window)
        key1 = EditTransaction(origin: .keystroke, base: queue.document.version, steps: [.insert("!", at: 7)])
        queue.submit(key1)
        _ = queue.next()
        windows.append(queue.document.window)
        key2 = EditTransaction(origin: .keystroke, base: queue.document.version, steps: [.insert("?", at: 8)])
        queue.submit(key2)
        _ = queue.next()
        windows.append(queue.document.window)
    }
}

@Suite struct FieldEditQueueVerifyTests {
    @Test func userLaneWritesWhileTwoWritesAreUnverified() {
        let run = ThreeUnverified()
        #expect(run.windows == ["one two", "One two", "One two!", "One two!?"])
    }

    @Test func aReadMatchingThePredictionConfirmsEveryWriteInOrder() {
        var run = ThreeUnverified()
        run.queue.settle(FieldSnapshot(before: "One two!?", after: ""))
        let versions = run.queue.takeEvents().compactMap { event -> UUID? in
            if case .applied(let id, _) = event { id } else { nil }
        }
        #expect(versions == [run.agent.id, run.key1.id, run.key2.id])
        #expect(run.queue.document.window == "One two!?")
        #expect(run.queue.document.caret == 9)
    }

    @Test func theFirstDivergingWriteAndEveryWriteAfterItFail() {
        var run = ThreeUnverified()
        let asr = EditTransaction(origin: .asr, owner: "run", base: run.queue.document.version, steps: [.insert(" three", at: 9)])
        run.queue.submit(asr)
        run.queue.settle(FieldSnapshot(before: "One two", after: ""))
        #expect(run.queue.takeEvents() == [
            .applied(run.agent.id, version: FieldVersion(1)),
            .conflict(run.key1.id, Conflict(.verifyFailed)),
            .conflict(run.key2.id, Conflict(.verifyFailed)),
        ])
        #expect(run.queue.document.window == "One two")
        #expect(run.queue.document.caret == 7)
        let write = run.queue.next()
        #expect(write?.id == asr.id)
        #expect(write?.steps == [.insert(" three", at: 7)])
    }

    @Test func aReadShowingNoneOfTheWritesFailsThemAll() {
        var run = ThreeUnverified()
        run.queue.settle(FieldSnapshot(before: "one two", after: ""))
        #expect(run.queue.takeEvents() == [
            .conflict(run.agent.id, Conflict(.verifyFailed)),
            .conflict(run.key1.id, Conflict(.verifyFailed)),
            .conflict(run.key2.id, Conflict(.verifyFailed)),
        ])
        #expect(run.queue.document.window == "one two")
    }

    /// Requirement change (Jakob): one failed write does not fail the writes after it. A read that is exactly
    /// the writes that landed (the missing ones rolled back) confirms those and fails only the others.
    @Test func aReadShowingOnlyAMiddleWriteConfirmsItAndFailsTheOthers() {
        var run = ThreeUnverified()
        #expect(run.queue.settle(FieldSnapshot(before: "one two!", after: "")) == .diverged)
        #expect(run.queue.takeEvents() == [
            .conflict(run.agent.id, Conflict(.verifyFailed)),
            .applied(run.key1.id, version: run.queue.document.version),
            .conflict(run.key2.id, Conflict(.verifyFailed)),
        ])
        #expect(run.queue.document.window == "one two!")
        #expect(!run.queue.feed.entries.contains { if case .foreign = $0.event { true } else { false } })
    }

    @Test func aReadShowingTheFirstAndLastWritesConfirmsThemAndFailsOnlyTheMiddle() {
        var run = ThreeUnverified()
        let asr = EditTransaction(origin: .asr, owner: "run", base: run.queue.document.version, steps: [.insert(" three", at: 9)])
        run.queue.submit(asr)
        #expect(run.queue.settle(FieldSnapshot(before: "One two?", after: "")) == .diverged)
        #expect(run.queue.takeEvents() == [
            .applied(run.agent.id, version: FieldVersion(1)),
            .conflict(run.key1.id, Conflict(.verifyFailed)),
            .applied(run.key2.id, version: run.queue.document.version),
        ])
        #expect(run.queue.document.window == "One two?")
        #expect(run.queue.document.caret == 8)
        #expect(run.queue.next()?.steps == [.insert(" three", at: 8)])
    }

    /// A doubled letter: whichever "l" failed, the field and the pending edits end up the same, so the earliest
    /// writes are confirmed instead of a tie.
    @Test func aFailedDoubledLetterFailsOneLetterAndKeepsThePendingEdit() {
        var field = "hel"
        var queue = macQueue(field)
        var keys: [EditTransaction] = []
        for (letter, at) in [("l", 3), ("l", 4), ("o", 5)] {
            let key = EditTransaction(origin: .keystroke, base: queue.document.version, steps: [.insert(letter, at: at)])
            queue.submit(key)
            _ = queue.next()
            keys.append(key)
        }
        queue.submit(EditTransaction(origin: .agent, owner: "agent", base: queue.document.version, steps: [.insert("!", at: 6)]))
        field = "hello"
        #expect(queue.settle(FieldSnapshot(window: field, caret: 5, windowBase: 0)) == .diverged)
        let events = queue.takeEvents()
        #expect(events.count == 3)
        #expect(events.first == .applied(keys[0].id, version: FieldVersion(1)))
        #expect(events.dropFirst().first == .conflict(keys[1].id, Conflict(.verifyFailed)))
        #expect(events.last == .applied(keys[2].id, version: queue.document.version))
        #expect(queue.document.window == "hello")
        #expect(queue.hasPending)
        queue.drain(&field)
        #expect(field == "hello!")
    }

    @Test func aFailedRepeatedKeystrokeFailsOnlyOneWithoutAReset() {
        var queue = macQueue("x")
        let a1 = EditTransaction(origin: .keystroke, base: FieldVersion(0), steps: [.insert("a", at: 1)])
        queue.submit(a1)
        _ = queue.next()
        let a2 = EditTransaction(origin: .keystroke, base: queue.document.version, steps: [.insert("a", at: 2)])
        queue.submit(a2)
        _ = queue.next()
        #expect(queue.settle(FieldSnapshot(window: "xa", caret: 2, windowBase: 0)) == .diverged)
        #expect(queue.takeEvents() == [.applied(a1.id, version: FieldVersion(1)), .conflict(a2.id, Conflict(.verifyFailed))])
        #expect(queue.document.window == "xa")
        #expect(!queue.feed.entries.contains { if case .reset = $0.event { true } else { false } })
    }

    /// A lagging read (the oldest writes only, before the final read) waits without searching subsets.
    @Test func aLaggingReadOfRepeatedTextWaits() {
        let text = String(repeating: "a ", count: 50)
        var queue = FieldEditQueue(FieldSnapshot(before: text, after: ""))
        var keys: [EditTransaction] = []
        for offset in 0..<8 {
            let key = EditTransaction(origin: .keystroke, base: queue.document.version, steps: [.insert("a", at: 100 + offset)])
            queue.submit(key)
            _ = queue.next()
            keys.append(key)
        }
        #expect(queue.settle(FieldSnapshot(before: text + "aaa", after: ""), final: false) == .notYet)
        #expect(queue.takeEvents() == keys.prefix(3).enumerated().map { .applied($1.id, version: FieldVersion($0 + 1)) })
        #expect(queue.settle(FieldSnapshot(before: text + "aaaaaaaa", after: ""), final: false) == .confirmed)
    }

    /// Two subsets explain the read but place a pending edit differently ("x!a" or "xa!"): a real tie. A lagging
    /// read waits on the prefix; a final read resets instead of guessing.
    @Test func aReadTwoDifferentOutcomesExplainWaitsOrResets() {
        func issued() -> (FieldEditQueue, [EditTransaction], EditTransaction) {
            var queue = FieldEditQueue(FieldSnapshot(before: "x", after: ""))
            var keys: [EditTransaction] = []
            for (letter, at) in [("a", 1), ("b", 2), ("a", 3)] {
                let key = EditTransaction(origin: .keystroke, base: queue.document.version, steps: [.insert(letter, at: at)])
                queue.submit(key)
                _ = queue.next()
                keys.append(key)
            }
            let mark = EditTransaction(origin: .agent, owner: "agent", base: queue.document.version, steps: [.insert("!", at: 2)])
            queue.submit(mark)
            return (queue, keys, mark)
        }
        let read = FieldSnapshot(before: "xa", after: "")
        var (lagging, keys, _) = issued()
        #expect(lagging.settle(read, final: false) == .notYet)
        #expect(lagging.takeEvents() == [.applied(keys[0].id, version: FieldVersion(1))])

        var (final, finalKeys, mark) = issued()
        #expect(final.settle(read) == .diverged)
        #expect(final.takeEvents() == finalKeys.map { .conflict($0.id, Conflict(.verifyFailed)) } + [.conflict(mark.id, Conflict(.outOfWindow))])
        #expect(final.feed.entries.last?.event == .reset(.unaligned, window: "xa", version: final.document.version))
    }
}
