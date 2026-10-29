import Foundation
import Testing
import LegatoFieldEdit

/// Review findings A1–A7 on the queue core: each test is the reviewer's input with the required outcome.
@Suite struct FieldEditQueueRegressionTests {
    let v0 = FieldVersion(0)

    // A1: a failed write is undone by inverting its steps, never by diffing repeated text.
    @Test func aFailedWriteIsUndoneByInvertingItsStepsNotByDiffing() {
        var field = "ab ab"
        var queue = macQueue(field)
        queue.submit(EditTransaction(origin: .agent, owner: "agent", base: v0, steps: [.insert("ab ", at: 0)]))
        _ = queue.next()
        queue.submit(EditTransaction(origin: .asr, owner: "run", base: v0, steps: [.insert("!", at: 2)]))
        queue.settle(FieldSnapshot(window: field, caret: 5, windowBase: 0))
        queue.drain(&field)
        #expect(field == "ab! ab")
    }

    // A2: a host change is anchored at the caret, not found by a greedy diff of the whole window.
    @Test func typingInsideAWordOnIOSIsAForeignStepAtTheCaret() {
        var queue = FieldEditQueue(FieldSnapshot(before: "hel", after: "lo"))
        queue.observe(FieldSnapshot(before: "hell", after: "lo"))
        #expect(queue.feed.entries.map(\.event) == [.foreign(.insert("l", at: 3), byUser: true, version: FieldVersion(1))])
        #expect(queue.document.window == "helllo")
        #expect(queue.document.caret == 4)
    }

    @Test func backspaceInsideAWordOnIOSIsAForeignStepAtTheCaret() {
        var queue = FieldEditQueue(FieldSnapshot(before: "hel", after: "lo"))
        queue.observe(FieldSnapshot(before: "he", after: "lo"))
        #expect(queue.feed.entries.map(\.event) == [.foreign(replace(2, "l", with: ""), byUser: true, version: FieldVersion(1))])
        #expect(queue.document.caret == 2)
    }

    @Test func typingRepeatedTextOnTheMacIsAnchoredAtTheCaret() {
        var field = "ab ab"
        var queue = macQueue(field, caret: 2)
        queue.submit(EditTransaction(origin: .agent, owner: "agent", base: v0, steps: [.insert("!", at: 5)]))
        queue.hostEdit(&field, to: "ab ab ab", caret: 5)
        queue.drain(&field)
        #expect(field == "ab ab ab!")
    }

    // A3: a transaction's caret is in the field after its own steps.
    @Test func aTransactionCaretIsMappedInTheFieldAfterItsSteps() {
        var field = "abcdefg"
        var queue = macQueue(field)
        queue.submit(EditTransaction(origin: .agent, owner: "agent", base: v0, steps: [replace(0, "ab", with: "")], caret: 3))
        queue.hostEdit(&field, to: "abcdXefg", caret: 5)
        let writes = queue.drain(&field)
        #expect(field == "cdXefg")
        #expect(writes.first?.caret == 4)
    }

    // A4: a readback showing the write plus later typing confirms the write; only the rest is foreign.
    @Test func aReadbackWithExtraTypingConfirmsTheWriteAndKeepsOnlyTheRestForeign() throws {
        var queue = macQueue("hello world")
        let asr = EditTransaction(origin: .asr, owner: "run", base: v0, steps: [.insert(" again", at: 11)])
        queue.submit(asr)
        let issued = queue.next()
        let write = try #require(issued)
        queue.settle(FieldSnapshot(window: "hello world again!", caret: 18, windowBase: 0))
        #expect(queue.takeEvents() == [.applied(asr.id, version: write.version)])
        #expect(queue.feed.entries.map(\.event) == [
            .applied(asr.id, origin: .asr, steps: [.insert(" again", at: 11)], version: write.version),
            .foreign(.insert("!", at: 17), byUser: true, version: FieldVersion(2)),
        ])
        #expect(queue.document.window == "hello world again!")
    }

    // A5: failed writes and their undo leave no trace for edits based on the feed.
    @Test func aFailedWriteLeavesNoTraceForEditsBasedOnTheFeed() throws {
        var field = "xw"
        var queue = macQueue(field)
        queue.submit(EditTransaction(origin: .agent, owner: "run", base: v0, steps: [.insert("y", at: 1)]))
        _ = queue.next()
        queue.settle(FieldSnapshot(window: field, caret: 2, windowBase: 0))
        #expect(queue.document.version == queue.feed.version)
        _ = queue.takeEvents()

        let fix = EditTransaction(origin: .agent, owner: "run", base: queue.feed.version, steps: [replace(0, "xw", with: "XW")])
        let other = EditTransaction(origin: .agent, owner: "agent", base: queue.feed.version, steps: [replace(1, "w", with: "W")])
        queue.submit(fix)
        let writes = queue.drain(&field)
        #expect(field == "XW")
        #expect(queue.takeEvents() == [.applied(fix.id, version: try #require(writes.first).version)])
        queue.submit(other)
        #expect(queue.drain(&field).isEmpty)
        #expect(queue.takeEvents() == [.conflict(other.id, Conflict(.overlap, intervening: replace(0, "xw", with: "XW")))])
    }

    // A6: a user-origin overlap is a user conflict, never `superseded`, even when the owners match.
    @Test func aUserPickOverlappingTheSameOwnersPendingEditConflictsWithANote() {
        var field = "hello wor"
        var queue = macQueue(field)
        let cleanup = EditTransaction(origin: .agent, owner: "run", base: v0, steps: [replace(6, "wor", with: "war")])
        let pick = EditTransaction(origin: .wordRow, owner: "run", base: v0, steps: [replace(6, "wor", with: "world")])
        queue.submit(cleanup)
        queue.submit(pick)
        queue.drain(&field)
        #expect(field == "hello world")
        #expect(queue.takeEvents().first == .conflict(cleanup.id, Conflict(.overlap, intervening: replace(6, "wor", with: "world"), byUser: true)))
    }

    // A7: a span that splits a surrogate pair or a grapheme is never written.
    @Test(arguments: [("a😀b", 2), ("cafe\u{301}", 4), ("👩🏽‍💻 x", 2)])
    func aSpanSplittingACharacterIsNeverWritten(_ text: String, _ location: Int) {
        var field = text
        var queue = macQueue(field)
        let split = EditTransaction(origin: .agent, base: v0, steps: [.insert("x", at: location)])
        queue.submit(split)
        #expect(queue.drain(&field).isEmpty)
        #expect(queue.takeEvents() == [.conflict(split.id, Conflict(.expectMismatch))])
        #expect(field == text)
    }
}
