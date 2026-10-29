import Foundation
import Testing
import LegatoFieldEdit

@Suite struct WindowAlignTests {
    let v0 = FieldVersion(0)

    private func queueWithPendingFix() -> (FieldEditQueue, EditTransaction) {
        var queue = FieldEditQueue(FieldSnapshot(before: "hello wo", after: "rld, teh end"))
        let fix = EditTransaction(origin: .agent, owner: "run", base: v0, steps: [replace(13, "teh", with: "the")])
        queue.submit(fix)
        return (queue, fix)
    }

    @Test func caretOnlyMoveRebasesTheCaretExactly() {
        var (queue, fix) = queueWithPendingFix()
        queue.observe(FieldSnapshot(before: "hello", after: " world, teh end"))
        #expect(queue.document.caret == 5)
        #expect(queue.document.version == v0)
        #expect(queue.feed.entries.isEmpty)
        let write = queue.next()
        #expect(write?.id == fix.id)
        #expect(write?.steps == [replace(13, "teh", with: "the")])
        #expect(write?.caret == 5)
    }

    @Test func aChangeAtTheCaretIsAForeignStep() {
        var (queue, fix) = queueWithPendingFix()
        queue.observe(FieldSnapshot(before: "hello woXY", after: "rld, teh end"))
        #expect(queue.feed.entries.map(\.event) == [.foreign(.insert("XY", at: 8), byUser: true, version: FieldVersion(1))])
        #expect(queue.next()?.steps == [replace(15, "teh", with: "the")])
        #expect(queue.takeEvents().allSatisfy { if case .conflict(fix.id, _) = $0 { false } else { true } })
    }

    @Test(arguments: [
        ("the caret jumped elsewhere", FieldSnapshot(before: "another paragraph ", after: "entirely")),
        ("the window shifted", FieldSnapshot(before: "llo wo", after: "rld, teh end, and more")),
    ])
    func anUnalignableWindowResets(_ name: String, _ snapshot: FieldSnapshot) {
        var (queue, fix) = queueWithPendingFix()
        queue.observe(snapshot)
        #expect(queue.takeEvents() == [.conflict(fix.id, Conflict(.outOfWindow))])
        #expect(queue.feed.entries.last?.event == .reset(.unaligned, window: snapshot.window, version: FieldVersion(1)))
        #expect(queue.document == ShadowDocument(window: snapshot.window, caret: snapshot.caret, version: FieldVersion(1)))
        #expect(queue.next() == nil)
    }

    @Test func aClearedFieldResets() {
        var (queue, fix) = queueWithPendingFix()
        queue.observe(FieldSnapshot(before: "", after: ""))
        #expect(queue.takeEvents() == [.conflict(fix.id, Conflict(.outOfWindow))])
        #expect(queue.feed.entries.last?.event == .reset(.cleared, window: "", version: FieldVersion(1)))
    }

    @Test func editsBasedBeforeAResetAreOutOfWindow() {
        var (queue, _) = queueWithPendingFix()
        queue.observe(FieldSnapshot(before: "another ", after: "field"))
        _ = queue.takeEvents()
        let late = EditTransaction(origin: .agent, owner: "run", base: v0, steps: [.insert("x", at: 0)])
        queue.submit(late)
        #expect(queue.takeEvents() == [.conflict(late.id, Conflict(.outOfWindow))])
    }

    @Test func focusChangeFailsUnverifiedAndPendingEdits() {
        var (queue, fix) = queueWithPendingFix()
        let key = EditTransaction(origin: .keystroke, base: v0, steps: [.insert("r", at: 8)])
        queue.submit(key)
        #expect(queue.next()?.id == key.id)
        queue.reset(FieldSnapshot(before: "", after: "new field"), reason: .focusChanged)
        #expect(queue.takeEvents() == [
            .conflict(key.id, Conflict(.focusLost)),
            .conflict(fix.id, Conflict(.focusLost)),
        ])
        #expect(queue.document.window == "new field")
        #expect(queue.document.caret == 0)
    }

    @Test func ownedAndTaintedSpansDoNotSurviveAReset() {
        var field = ""
        var queue = macQueue(field)
        queue.submit(EditTransaction(origin: .asr, owner: "run", base: v0, steps: [.insert("abc", at: 0)]))
        queue.drain(&field)
        #expect(!queue.document.owned.isEmpty)
        queue.reset(FieldSnapshot(window: "xyz", caret: 0, windowBase: 0), reason: .focusChanged)
        #expect(queue.document.owned.isEmpty)
        #expect(queue.document.windowBase == 0)
    }
}
