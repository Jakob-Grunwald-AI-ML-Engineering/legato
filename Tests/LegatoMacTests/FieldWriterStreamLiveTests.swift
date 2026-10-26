import LegatoCore
import Testing
@testable import LegatoMac

@MainActor
@Suite struct FieldWriterStreamLiveTests {
    private func makeWriter(_ field: FakeTextTarget) -> FieldWriter {
        FieldWriter(target: field, mode: .streamLive)
    }

    @Test func tentativeTextIsShownReplacedAndFinalized() {
        let field = FakeTextTarget()
        let writer = makeWriter(field)
        var assembler = TranscriptAssembler()
        func feed(_ text: String, final: Bool) {
            for edit in assembler.apply(.init(text: text, isFinal: final)) { writer.apply(edit) }
        }
        feed("hel", final: false)
        #expect(field.string == "hel")
        feed("hello wor", final: false)
        #expect(field.string == "hello wor")
        feed("hello world", final: true)
        #expect(field.string == "hello world")
        feed(" and", final: false)
        #expect(field.string == "hello world and")
        feed(" and more", final: true)
        #expect(field.string == "hello world and more")
        #expect(writer.finish(finalText: "hello world and more") == .done)
        #expect(writer.degradeReason == nil)
    }

    @Test func firstTentativeTextReplacesTheSelection() {
        let field = FakeTextTarget("abcdefghi", selection: UTF16Range(location: 3, length: 3))
        let writer = makeWriter(field)
        writer.apply(.replaceVolatile("X"))
        #expect(field.string == "abcXghi")
        writer.apply(.replaceVolatile("XY"))
        #expect(field.string == "abcXYghi")
        writer.apply(.commit(delta: "XYZ"))
        #expect(field.string == "abcXYZghi")
    }

    @Test func aCommitReplacesTheTentativeTextStillShown() {
        let field = FakeTextTarget()
        let writer = makeWriter(field)
        writer.apply(.replaceVolatile("he"))
        writer.apply(.commit(delta: "hello"))
        #expect(field.string == "hello")
    }

    @Test func unchangedOrEmptyTentativeTextDoesNotWrite() {
        let field = FakeTextTarget("abc", selection: UTF16Range(location: 0, length: 3))
        let writer = makeWriter(field)
        writer.apply(.replaceVolatile(""))
        #expect(field.writes.isEmpty) // the selection must survive an empty first update
        writer.apply(.replaceVolatile("a"))
        writer.apply(.replaceVolatile("a"))
        #expect(field.writes.count == 1)
    }

    @Test func tentativeTextIsClearedWhenItEmpties() {
        let field = FakeTextTarget()
        let writer = makeWriter(field)
        writer.apply(.replaceVolatile("hel"))
        writer.apply(.replaceVolatile(""))
        #expect(field.string == "")
        writer.apply(.commit(delta: "Hi"))
        #expect(field.string == "Hi")
    }

    @Test func leftoverTentativeTextIsRemovedAtFinish() {
        let field = FakeTextTarget()
        let writer = makeWriter(field)
        writer.apply(.commit(delta: "Hello"))
        writer.apply(.replaceVolatile(" wor"))
        #expect(field.string == "Hello wor")
        #expect(writer.finish(finalText: "Hello") == .done)
        #expect(field.string == "Hello")
    }

    @Test func leadingWhitespaceOfTheFirstTextIsNotShown() {
        let field = FakeTextTarget()
        let writer = makeWriter(field)
        writer.apply(.replaceVolatile(" hel"))
        #expect(field.string == "hel")
        writer.apply(.commit(delta: " hello"))
        #expect(field.string == "hello")
    }

    @Test func editingTheTentativeTextBehindOurBackIsDrift() {
        let field = FakeTextTarget()
        let writer = makeWriter(field)
        writer.apply(.replaceVolatile("hel"))
        field.externalEdit(UTF16Range(location: 0, length: 1), with: "J")
        writer.apply(.replaceVolatile("hello"))
        #expect(writer.degradeReason == .drift)
        #expect(field.string == "Jel")
        #expect(writer.finish(finalText: "hello") == .paste("hello"))
    }

    @Test func focusLostWhileLiveCopiesWhatIsNotCommittedToTheField() {
        let field = FakeTextTarget()
        let writer = makeWriter(field)
        writer.apply(.commit(delta: "Hello"))
        writer.apply(.replaceVolatile(" wo"))
        field.focused = false
        writer.apply(.replaceVolatile(" wor"))
        writer.apply(.commit(delta: " world"))
        #expect(writer.degradeReason == .focusLost)
        #expect(writer.finish(finalText: "Hello world") == .copy("world"))
    }
}
