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

    @Test func aReadMatchingNoPredictionFailsAllAndIsObservedAgainstTheConfirmedField() {
        var run = ThreeUnverified()
        run.queue.settle(FieldSnapshot(before: "one two!", after: ""))
        let events = run.queue.takeEvents()
        #expect(events.count == 3)
        #expect(events.allSatisfy { if case .conflict(_, let c) = $0 { c.reason == .verifyFailed } else { false } })
        #expect(run.queue.document.window == "one two!")
        #expect(run.queue.feed.entries.last?.event == .foreign(.insert("!", at: 7), byUser: true, version: run.queue.document.version))
    }
}
