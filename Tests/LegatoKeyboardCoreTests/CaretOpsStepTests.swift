import Foundation
import LegatoFieldEdit
import Testing
@testable import LegatoKeyboardCore

@Suite struct CaretOpsStepTests {
    @Test func aStreamAppendIsAnInsertAtTheCaret() throws {
        let edit = try #require(CaretOpsStep.edit(for: [.insert(" world")], before: "Hello"))
        #expect(edit.step == .insert(" world", at: 5))
        #expect(edit.caret == 11)
    }

    @Test func aWholeSpanRevisionShrinksToTheChangedCharacters() throws {
        // P01: the planner rewrites everything after the shared "t"; the patch is the two swapped letters.
        let ops = ProxyEditPlanner.replaceOps(from: "teh cat sat", to: "the cat sat")
        #expect(ops == [.deleteBackward(10), .insert("he cat sat")])
        let edit = try #require(CaretOpsStep.edit(for: ops, before: "teh cat sat"))
        #expect(edit.step == EditStep(span: Span(location: 1, length: 2), text: "he", expect: "eh"))
        #expect(edit.caret == 11)
    }

    @Test func aDeletedEmojiIsItsWholeCharacterInUTF16() throws {
        let edit = try #require(CaretOpsStep.edit(for: [.deleteBackward(1), .insert("🎉")], before: "ok 👍🏽"))
        #expect(edit.step == EditStep(span: Span(location: 3, length: 4), text: "🎉", expect: "👍🏽"))
        #expect(edit.caret == 5)
    }

    @Test func aZWJFamilyBeforeTheCaretStaysWholeWhenTextIsAppended() throws {
        let family = "👨‍👩‍👧"
        let edit = try #require(CaretOpsStep.edit(for: [.insert("!")], before: "hi " + family))
        #expect(edit.step == .insert("!", at: 11))
        #expect(edit.caret == 12)
    }

    @Test func aDecomposedAccentIsReplacedAsTwoUnits() throws {
        let edit = try #require(CaretOpsStep.edit(for: [.deleteBackward(1), .insert("\u{E9}")], before: "cafe\u{301}"))
        #expect(edit.step == EditStep(span: Span(location: 3, length: 2), text: "\u{E9}", expect: "e\u{301}"))
        #expect(edit.caret == 4)
    }

    @Test func opsThatChangeNothingAreNoStep() {
        #expect(CaretOpsStep.edit(for: [.deleteBackward(1), .insert("c")], before: "abc") == nil)
        #expect(CaretOpsStep.edit(for: [], before: "abc") == nil)
    }

    @Test func aDeletePastTheStartStopsAtTheStart() throws {
        let edit = try #require(CaretOpsStep.edit(for: [.deleteBackward(5)], before: "ab"))
        #expect(edit.step == EditStep(span: Span(location: 0, length: 2), text: "", expect: "ab"))
        #expect(edit.caret == 0)
    }

    @Test func aVersionSwapIsPatchSized() throws {
        let versions = DictationVersions(runID: "r", documentID: "d", texts: ["teh cat sat", "the cat sat"], current: 1, trailing: " ")
        let ops = try #require(versions.swapOps(to: 0, contextBefore: "So the cat sat "))
        let edit = try #require(CaretOpsStep.edit(for: ops, before: "So the cat sat "))
        #expect(edit.step == EditStep(span: Span(location: 4, length: 2), text: "eh", expect: "he"))
        #expect(edit.caret == 15)
    }

    @Test func throughTheQueueTheFieldEndsAsTheOpsLeaveItWithTheTextAfterTheCaretUntouched() throws {
        let before = "Say 👋🏾 teh cat sat", after = " — later text"
        let ops = ProxyEditPlanner.replaceOps(from: "teh cat sat", to: "the cat sat")
        let edit = try #require(CaretOpsStep.edit(for: ops, before: before))
        var queue = FieldEditQueue(FieldSnapshot(before: before, after: after))
        queue.submit(EditTransaction(origin: .liveCleanup, owner: "run", base: queue.document.version, steps: [edit.step]))
        let window = queue.document.window, caret = queue.document.caret
        let issued = queue.next()
        let write = try #require(issued)
        let calls = try #require(ProxyOpCompiler.compile(write, window: window, caret: caret))
        var proxy = CaretProxy(before + after, caret: before.utf16.count)
        proxy.run(calls)
        #expect(proxy.text == "Say 👋🏾 the cat sat — later text")
        #expect(proxy.caret == edit.caret)
        #expect(calls.filter { if case .deleteBackward = $0 { true } else { false } } == [.deleteBackward(2)])
        #expect(queue.settle(FieldSnapshot(before: proxy.before, after: proxy.after), final: false) == .confirmed)
    }
}
