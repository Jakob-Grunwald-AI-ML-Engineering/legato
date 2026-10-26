import LegatoCore
import Testing
@testable import LegatoMac

@MainActor
@Suite struct FieldWriterStreamCommittedTests {
    @Test func commitsAppendAtTheCaretAndFinishDone() {
        let field = FakeTextTarget()
        let writer = FieldWriter(target: field)
        writer.apply(.commit(delta: "Hello"))
        #expect(field.string == "Hello")
        writer.apply(.commit(delta: " world"))
        #expect(field.string == "Hello world")
        #expect(writer.finish(finalText: "Hello world") == .done)
        #expect(writer.degradeReason == nil)
    }

    @Test func tentativeTextIsNotWritten() {
        let field = FakeTextTarget()
        let writer = FieldWriter(target: field)
        writer.apply(.replaceVolatile("hel"))
        writer.apply(.replaceVolatile("hello wor"))
        writer.apply(.replaceVolatile(""))
        #expect(field.writes.isEmpty)
        #expect(field.string == "")
    }

    @Test func insertsAtTheCaretInTheMiddleOfText() {
        let field = FakeTextTarget("abcd", selection: UTF16Range(location: 2, length: 0))
        let writer = FieldWriter(target: field)
        writer.apply(.commit(delta: "XY"))
        writer.apply(.commit(delta: "Z"))
        #expect(field.string == "abXYZcd")
    }

    @Test func initialSelectionIsReplacedByTheFirstWrite() {
        let field = FakeTextTarget("abcdefghi", selection: UTF16Range(location: 3, length: 3))
        let writer = FieldWriter(target: field)
        writer.apply(.commit(delta: "X"))
        #expect(field.string == "abcXghi")
        // Later phrases land after our text, not at the (moved) caret and not over "ghi".
        writer.apply(.commit(delta: "Y"))
        #expect(field.string == "abcXYghi")
    }

    @Test func spansAreCountedInUTF16Units() {
        let field = FakeTextTarget("😀", selection: UTF16Range(location: 2, length: 0))
        let writer = FieldWriter(target: field)
        writer.apply(.commit(delta: "Hi 😀"))
        writer.apply(.commit(delta: " there"))
        #expect(field.string == "😀Hi 😀 there")
        #expect(writer.degradeReason == nil)
        #expect(writer.finish(finalText: "Hi 😀 there") == .done)
    }

    @Test func emptyDeltasDoNotTouchTheField() {
        let field = FakeTextTarget()
        let writer = FieldWriter(target: field)
        writer.apply(.commit(delta: ""))
        #expect(field.writes.isEmpty)
    }

    @Test func leadingWhitespaceOfTheFirstPhraseIsNotWritten() {
        let field = FakeTextTarget()
        let writer = FieldWriter(target: field)
        writer.apply(.commit(delta: "  "))
        #expect(field.writes.isEmpty)
        writer.apply(.commit(delta: " Hi"))
        #expect(field.string == "Hi")
        writer.apply(.commit(delta: " there"))
        #expect(field.string == "Hi there")
    }
}
