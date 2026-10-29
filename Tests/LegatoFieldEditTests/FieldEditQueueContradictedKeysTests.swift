import Foundation
import Testing
import LegatoFieldEdit

/// Keystrokes while a read contradicts the prediction (iOS, decision 4): the user lane still runs, its writes
/// are ordered unverified steps on the prediction, and every later read is settled against them. An old read
/// never makes the queue forget a key it does not show yet, and a key is never taken for foreign typing that
/// fails an earlier write.
@Suite struct FieldEditQueueContradictedKeysTests {
    let v0 = FieldVersion(0)

    private func applied(_ events: [QueueEvent], _ id: UUID) -> Bool {
        events.contains { if case .applied(id, _) = $0 { true } else { false } }
    }

    private func failed(_ events: [QueueEvent]) -> Bool {
        events.contains { if case .conflict = $0 { true } else { false } }
    }

    private func key(_ queue: FieldEditQueue, _ text: String) -> EditTransaction {
        EditTransaction(origin: .keystroke, base: queue.document.version, steps: [.insert(text, at: queue.document.caret)])
    }

    /// Issues the next write and runs it on `field`.
    private func run(_ queue: inout FieldEditQueue, on field: inout String) throws {
        let write = queue.next()
        field = execute(try #require(write), on: field)
    }

    private func contradict(_ queue: inout FieldEditQueue) {
        #expect(queue.settle(FieldSnapshot(before: "", after: ""), final: false) == .notYet)
        #expect(queue.needsFinalSettle)
    }

    /// "hello|" + cleanup h→H; a read nothing explains; the key "!" is issued at once, on the prediction.
    @Test func aKeystrokeIsIssuedWhileTheQueueIsContradicted() {
        var queue = FieldEditQueue(FieldSnapshot(before: "hello", after: ""))
        queue.submit(EditTransaction(origin: .liveCleanup, owner: "run", base: v0, steps: [replace(0, "h", with: "H")]))
        _ = queue.next()
        contradict(&queue)
        let bang = key(queue, "!")
        queue.submit(bang)
        #expect(queue.next()?.steps == [.insert("!", at: 5)])
        #expect(queue.document.window == "Hello!")
        #expect(queue.takeEvents().isEmpty)
    }

    /// An in-order old read (the cleanup alone) confirms the cleanup but keeps the key it does not show yet:
    /// the prediction still has it, so the next edit is planned at the real caret.
    @Test func anOldReadAfterAContradictionKeepsTheKeyItDoesNotShow() {
        var queue = FieldEditQueue(FieldSnapshot(before: "hello", after: ""))
        let fix = EditTransaction(origin: .liveCleanup, owner: "run", base: v0, steps: [replace(0, "h", with: "H")])
        queue.submit(fix)
        _ = queue.next()
        contradict(&queue)
        let bang = key(queue, "!")
        queue.submit(bang)
        _ = queue.next()
        #expect(queue.settle(FieldSnapshot(before: "Hello", after: ""), final: false) == .notYet)
        let events = queue.takeEvents()
        #expect(applied(events, fix.id))
        #expect(!failed(events))
        #expect(queue.document.window == "Hello!")
        #expect(queue.document.caret == 6)
        #expect(queue.settle(FieldSnapshot(before: "Hello!", after: "")) == .confirmed)
        #expect(applied(queue.takeEvents(), bang.id))
    }

    /// "teh cat" + cleanup c→C; contradiction; key "s"; the old read "teh Cat"; the pending cleanup teh→the waits
    /// for the key's read and is then written on "teh Cats": "the Cats".
    @Test func aCleanupAfterAnOldReadIsPlannedOnTheKeysItDoesNotShow() throws {
        var field = "teh cat"
        var queue = FieldEditQueue(FieldSnapshot(before: field, after: ""))
        let first = EditTransaction(origin: .liveCleanup, owner: "run", base: v0, steps: [replace(4, "c", with: "C")])
        queue.submit(first)
        try run(&queue, on: &field)
        contradict(&queue)
        let s = key(queue, "s")
        queue.submit(s)
        try run(&queue, on: &field)
        #expect(field == "teh Cats")
        #expect(queue.settle(FieldSnapshot(before: "teh Cat", after: ""), final: false) == .notYet)
        let second = EditTransaction(
            origin: .liveCleanup, owner: "run", base: queue.document.version, steps: [replace(0, "teh", with: "the")])
        queue.submit(second)
        #expect(queue.next() == nil)  // the key awaits its read
        #expect(queue.settle(FieldSnapshot(before: field, after: ""), final: false) == .confirmed)
        let write = queue.next()
        #expect(write?.steps == [replace(0, "teh", with: "the")])
        field = execute(try #require(write), on: field)
        #expect(field == "the Cats")
        #expect(queue.settle(FieldSnapshot(before: field, after: ""), final: false) == .confirmed)
        let events = queue.takeEvents()
        #expect(!failed(events))
        #expect([first.id, s.id, second.id].allSatisfy { applied(events, $0) })
    }

    /// "hi" + ASR " there"; contradiction; key "!"; the old read "hi there"; the next ASR chunk " you" waits for
    /// the key's read and goes after it. The read "hi there! you" fails nothing.
    @Test func theNextChunkAfterAnOldReadGoesAfterTheKeyAndNothingFails() throws {
        var field = "hi"
        var queue = FieldEditQueue(FieldSnapshot(before: field, after: ""))
        let there = EditTransaction(origin: .asr, owner: "run", base: v0, steps: [.insert(" there", at: 2)])
        queue.submit(there)
        try run(&queue, on: &field)
        contradict(&queue)
        let bang = key(queue, "!")
        queue.submit(bang)
        try run(&queue, on: &field)
        #expect(queue.settle(FieldSnapshot(before: "hi there", after: ""), final: false) == .notYet)
        let you = EditTransaction(
            origin: .asr, owner: "run", base: queue.document.version, steps: [.insert(" you", at: queue.document.caret)])
        queue.submit(you)
        #expect(queue.settle(FieldSnapshot(before: field, after: ""), final: false) == .confirmed)
        let write = queue.next()
        #expect(write?.steps == [.insert(" you", at: 9)])
        field = execute(try #require(write), on: field)
        #expect(field == "hi there! you")
        #expect(queue.settle(FieldSnapshot(before: field, after: "")) == .confirmed)
        let events = queue.takeEvents()
        #expect(!failed(events))
        #expect([there.id, bang.id, you.id].allSatisfy { applied(events, $0) })
    }

    /// "hello" + ASR " world"; contradiction; the delete key: the read "hello worl" confirms both.
    @Test func aDeleteKeyIntoAnUnconfirmedChunkConfirmsTheChunk() {
        var queue = FieldEditQueue(FieldSnapshot(before: "hello", after: ""))
        let world = EditTransaction(origin: .asr, owner: "run", base: v0, steps: [.insert(" world", at: 5)])
        queue.submit(world)
        _ = queue.next()
        contradict(&queue)
        let delete = EditTransaction(
            origin: .keystroke, base: queue.document.version, steps: [replace(10, "d", with: "")])
        queue.submit(delete)
        #expect(queue.next()?.steps == [replace(10, "d", with: "")])
        #expect(queue.settle(FieldSnapshot(before: "hello worl", after: ""), final: false) == .confirmed)
        let events = queue.takeEvents()
        #expect(!failed(events))
        #expect(applied(events, world.id) && applied(events, delete.id))
    }

    /// The cleanup did not land but the key did ("hello!"): only the cleanup fails; the key is confirmed.
    @Test func aKeyThatLandedWithoutTheWriteBeforeItFailsOnlyThatWrite() {
        var queue = FieldEditQueue(FieldSnapshot(before: "hello", after: ""))
        let fix = EditTransaction(origin: .liveCleanup, owner: "run", base: v0, steps: [replace(0, "h", with: "H")])
        queue.submit(fix)
        _ = queue.next()
        contradict(&queue)
        let bang = key(queue, "!")
        queue.submit(bang)
        _ = queue.next()
        #expect(queue.settle(FieldSnapshot(before: "hello!", after: ""), final: false) == .diverged)
        let events = queue.takeEvents()
        #expect(events.contains(.conflict(fix.id, Conflict(.verifyFailed))))
        #expect(applied(events, bang.id))
        #expect(queue.document.window == "hello!")
    }

    /// While contradicted only the user lane runs: ASR and cleanup edits (and ``FieldEditQueue/next(for:)`` for
    /// them) wait for a settle that resolves it, also after a key ran.
    @Test func theOtherLanesStayHeldWhileContradictedAfterAKeyRan() {
        var queue = FieldEditQueue(FieldSnapshot(before: "teh cat", after: ""))
        queue.submit(EditTransaction(origin: .liveCleanup, owner: "run", base: v0, steps: [replace(0, "teh", with: "the")]))
        _ = queue.next()
        contradict(&queue)
        let chunk = EditTransaction(origin: .asr, owner: "run", base: queue.document.version, steps: [.insert(" sat", at: 7)])
        queue.submit(chunk)
        queue.submit(key(queue, "s"))
        #expect(queue.next()?.origin == .keystroke)
        #expect(queue.needsFinalSettle)
        #expect(queue.next() == nil)
        #expect(queue.next(for: chunk.id) == nil)
        #expect(queue.peek(lanes: [.asr, .cleanup]) == nil)
        #expect(queue.settle(queue.predicted, final: false) == .confirmed)
        #expect(queue.next()?.id == chunk.id)
    }

    /// ``FieldEditQueue/next(for:)`` issues a user-lane edit while contradicted, as ``FieldEditQueue/next()`` does.
    @Test func nextForAUserLaneEditRunsWhileContradicted() {
        var queue = FieldEditQueue(FieldSnapshot(before: "teh cat", after: ""))
        queue.submit(EditTransaction(origin: .liveCleanup, owner: "run", base: v0, steps: [replace(0, "teh", with: "the")]))
        _ = queue.next()
        contradict(&queue)
        let s = key(queue, "s")
        queue.submit(s)
        #expect(queue.next(for: s.id)?.steps == [.insert("s", at: 7)])
    }
}
