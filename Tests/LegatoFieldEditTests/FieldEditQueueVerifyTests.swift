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

    /// Two different subsets of the writes explain the read: it waits, and a final read resets.
    @Test func aReadTwoSubsetsExplainWaitsThenResets() {
        var queue = FieldEditQueue(FieldSnapshot(before: "x", after: ""))
        let a = EditTransaction(origin: .keystroke, base: FieldVersion(0), steps: [.insert("a", at: 1)])
        queue.submit(a)
        _ = queue.next()
        let b = EditTransaction(origin: .keystroke, base: queue.document.version, steps: [.insert("b", at: 2)])
        queue.submit(b)
        _ = queue.next()
        let c = EditTransaction(origin: .keystroke, base: queue.document.version, steps: [.insert("b", at: 3)])
        queue.submit(c)
        _ = queue.next()
        // "xab": A and B, or A and C (B missing, C mapped onto its place).
        let read = FieldSnapshot(before: "xab", after: "")
        #expect(queue.settle(read, final: false) == .notYet)
        #expect(queue.takeEvents().isEmpty)
        #expect(queue.settle(read) == .diverged)
        #expect(queue.feed.entries.last?.event == .reset(.unaligned, window: "xab", version: queue.document.version))
    }
}
