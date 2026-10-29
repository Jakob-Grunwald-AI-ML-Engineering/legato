import Foundation
import Testing
import LegatoFieldEdit

/// An iOS-style queue: the caret-relative window, absolute offset unknown.
private func keyboardQueue(_ before: String, _ after: String) -> FieldEditQueue {
    FieldEditQueue(FieldSnapshot(before: before, after: after))
}

private func keystroke(_ text: String, at caret: Int, base: FieldVersion) -> EditTransaction {
    EditTransaction(origin: .keystroke, base: base, steps: [.insert(text, at: caret)])
}

@Suite struct FieldEditQueueLaneTests {
    let v0 = FieldVersion(0)

    @Test func userLaneRunsFirstThenASRThenCleanup() {
        var field = "a b c"
        var queue = macQueue(field)
        let agent = EditTransaction(origin: .agent, owner: "run", base: v0, steps: [replace(4, "c", with: "C")])
        let asr = EditTransaction(origin: .asr, owner: "run", base: v0, steps: [replace(2, "b", with: "B")])
        let word = EditTransaction(origin: .wordRow, base: v0, steps: [replace(0, "a", with: "A")])
        queue.submit(agent)
        queue.submit(asr)
        queue.submit(word)
        #expect(queue.drain(&field).map(\.id) == [word.id, asr.id, agent.id])
        #expect(field == "A B C")
    }

    @Test func automaticWritesWaitWhileAWriteIsUnverifiedButTheUserLaneDoesNot() {
        var queue = keyboardQueue("one two", "")
        let first = EditTransaction(origin: .agent, owner: "run", base: v0, steps: [replace(0, "one", with: "One")])
        let second = EditTransaction(origin: .asr, owner: "run", base: v0, steps: [.insert(" three", at: 7)])
        queue.submit(first)
        queue.submit(second)
        #expect(queue.next()?.id == second.id)
        #expect(queue.next() == nil)

        let key = keystroke("!", at: queue.document.caret, base: queue.document.version)
        queue.submit(key)
        #expect(queue.next()?.id == key.id)
        #expect(queue.next() == nil)
        queue.settle(queue.predicted)
        #expect(queue.next()?.id == first.id)
    }

    @Test func pendingTicksWithTheSameKeyCoalesceLatestWins() {
        var field = ""
        var queue = macQueue(field)
        let tick1 = EditTransaction(origin: .asr, owner: "run", base: v0, steps: [.insert("Hel", at: 0)], coalesce: "reveal")
        let tick2 = EditTransaction(origin: .asr, owner: "run", base: v0, steps: [.insert("Hello", at: 0)], coalesce: "reveal")
        let other = EditTransaction(origin: .asr, owner: "other", base: v0, steps: [.insert("x", at: 0)], coalesce: "other")
        queue.submit(tick1)
        queue.submit(other)
        queue.submit(tick2)
        let writes = queue.drain(&field)
        #expect(writes.map(\.id) == [other.id, tick2.id])
        #expect(queue.takeEvents().first == .superseded(tick1.id, by: tick2.id))
    }

    @Test func keystrokeMidWordLandsAtItsCaretAndShiftsAPendingEditElsewhere() throws {
        var queue = keyboardQueue("hello w", "rld, teh end")
        let fix = EditTransaction(origin: .agent, owner: "run", base: v0, steps: [replace(12, "teh", with: "the")])
        queue.submit(fix)
        queue.submit(keystroke("o", at: 7, base: v0))

        let keyWrite = queue.next()
        let key = try #require(keyWrite)
        #expect(key.steps == [.insert("o", at: 7)])
        #expect(key.caret == 8)
        queue.settle(queue.predicted)
        let shiftedWrite = queue.next()
        let shifted = try #require(shiftedWrite)
        #expect(shifted.steps == [replace(13, "teh", with: "the")])
        #expect(shifted.caret == 8)
        queue.settle(queue.predicted)
        #expect(queue.document.window == "hello world, the end")
    }

    @Test func keystrokeInTheWordAPendingEditRewritesConflictsWithAUserNote() {
        var queue = keyboardQueue("hello w", "rld, teh end")
        let fix = EditTransaction(origin: .agent, owner: "run", base: v0, steps: [replace(6, "wrld", with: "world")])
        queue.submit(fix)
        let key = keystroke("o", at: 7, base: v0)
        queue.submit(key)

        let keyWrite = queue.next()
        #expect(keyWrite?.id == key.id)
        queue.settle(queue.predicted)
        #expect(queue.next() == nil)
        let events = queue.takeEvents()
        #expect(events.first == .conflict(fix.id, Conflict(.overlap, intervening: .insert("o", at: 7), byUser: true)))
        #expect(events.dropFirst().first.map { if case .applied(key.id, _) = $0 { true } else { false } } == true)
        #expect(queue.document.window == "hello world, teh end")
    }
}
