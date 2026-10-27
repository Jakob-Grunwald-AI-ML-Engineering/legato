import LegatoCore
import Testing
@testable import LegatoMac

/// Live cleanup on the Mac: a revision (a rolling pass over the run's whole raw text) replaces what the field
/// shows for the run, followed by the raw text committed after the pass's input, with one verified write of
/// only the part that changed. Only while the field still reads as the writer left it and the caret is right
/// after its text; otherwise the revision, and every later one, is skipped and the writer keeps streaming.
@MainActor
@Suite struct FieldWriterLiveTests {
    private let hello = TranscriptRevision(n: 1, start: 0, raw: "hello world ", text: "Hello world. ")
    private let whole = TranscriptRevision(
        n: 2, start: 0, raw: "hello world how are you ", text: "Hello world. How are you? ")
    private let cleaned = "Hello world. How are you?"

    private func streamed(_ field: FakeTextTarget, mode: FieldWriter.Mode = .streamCommitted) -> FieldWriter {
        let writer = FieldWriter(target: field, mode: mode)
        writer.apply(.commit(delta: "hello world "))
        writer.apply(.commit(delta: "how are you "))
        return writer
    }

    @Test func aRevisionReplacesTheRunsTextWithOneVerifiedWrite() {
        let field = FakeTextTarget("Dear ")
        let writer = streamed(field)
        let before = field.writes.count
        writer.apply(.revise(whole))
        #expect(field.string == "Dear Hello world. How are you? ")
        #expect(field.writes.count == before + 1)
        #expect(writer.degradeReason == nil)
    }

    @Test func theRawTextCommittedAfterThePassFollowsTheCleanedText() {
        let field = FakeTextTarget("Dear ")
        let writer = streamed(field)
        writer.apply(.revise(hello))
        #expect(field.string == "Dear Hello world. how are you ")
    }

    @Test func onlyThePartThatChangedIsWritten() {
        let field = FakeTextTarget("Dear ")
        let writer = streamed(field)
        writer.apply(.revise(hello))
        writer.apply(.revise(whole))
        #expect(field.string == "Dear Hello world. How are you? ")
        let last = field.writes.last
        #expect(last?.range == UTF16Range(location: 18, length: 12), "from the first changed character to the end")
        #expect(last?.text == "How are you? ")
    }

    @Test func aLaterPassCanChangeAnEarlierPhrase() {
        let field = FakeTextTarget()
        let writer = FieldWriter(target: field)
        writer.apply(.commit(delta: "meet on friday "))
        writer.apply(.revise(TranscriptRevision(n: 1, start: 0, raw: "meet on friday ", text: "Meet on Friday. ")))
        writer.apply(.commit(delta: "no wait thursday "))
        writer.apply(.revise(TranscriptRevision(
            n: 2, start: 0, raw: "meet on friday no wait thursday ", text: "Meet on Thursday. ")))
        #expect(field.string == "Meet on Thursday. ")
    }

    @Test func theCaretStaysAfterTheDictatedText() {
        let field = FakeTextTarget("Dear ")
        let writer = streamed(field)
        writer.apply(.revise(hello))
        #expect(field.selection == UTF16Range(location: field.string.utf16.count, length: 0))
        writer.apply(.commit(delta: "bye"))
        #expect(field.string == "Dear Hello world. how are you bye")
    }

    @Test func anOlderRevisionIsIgnored() {
        let field = FakeTextTarget()
        let writer = streamed(field)
        writer.apply(.revise(whole))
        writer.apply(.revise(hello))
        #expect(field.string == "Hello world. How are you? ")
    }

    @Test func aRevisionIsSkippedWhenTheUserTypedAfterTheText() {
        let field = FakeTextTarget()
        let writer = streamed(field)
        field.userTypes("ok")
        let before = field.writes.count
        writer.apply(.revise(hello))
        #expect(field.string == "hello world how are you ok")
        #expect(field.writes.count == before, "nothing was written")
        #expect(writer.degradeReason == nil, "skipped silently")
    }

    @Test func onceARevisionWasSkippedLaterOnesAreToo() {
        let field = FakeTextTarget()
        let writer = streamed(field)
        field.moveCaret(to: 0)
        writer.apply(.revise(hello))
        #expect(field.string == "hello world how are you ")
        field.moveCaret(to: field.string.utf16.count)
        writer.apply(.revise(whole))
        #expect(field.string == "hello world how are you ", "the user worked in the field: it stays theirs")
    }

    @Test func aRevisionIsSkippedWhenTheTextWasEdited() {
        let field = FakeTextTarget()
        let writer = streamed(field)
        field.externalEdit(UTF16Range(location: 0, length: 1), with: "J")
        writer.apply(.revise(hello))
        #expect(field.string == "Jello world how are you ")
    }

    @Test func theFirstPhrasesLeadingWhitespaceThatWasNeverWrittenIsHandled() {
        let field = FakeTextTarget()
        let writer = FieldWriter(target: field)
        writer.apply(.commit(delta: " hello world"))
        #expect(field.string == "hello world")
        writer.apply(.revise(TranscriptRevision(n: 1, start: 0, raw: " hello world", text: " Hello world.")))
        #expect(field.string == "Hello world.")
    }

    @Test func tentativeTextStaysAfterTheRevisedText() {
        let field = FakeTextTarget()
        let writer = FieldWriter(target: field, mode: .streamLive)
        writer.apply(.commit(delta: "hello world "))
        writer.apply(.replaceVolatile("how"))
        writer.apply(.revise(hello))
        #expect(field.string == "Hello world. how")
        writer.apply(.replaceVolatile("how are"))
        #expect(field.string == "Hello world. how are")
    }

    // MARK: finish

    @Test func aLiveRunWhoseRevisionLandedIsDone() {
        let field = FakeTextTarget()
        let writer = streamed(field)
        writer.apply(.revise(hello))
        writer.apply(.revise(whole))
        #expect(writer.finish(rawText: "hello world how are you", cleanedText: cleaned, delivery: .live) == .done)
        #expect(field.string == "Hello world. How are you? ")
    }

    @Test func aLiveRunWithASkippedRevisionCopiesTheCleanedTextAndLeavesTheField() {
        let field = FakeTextTarget()
        let writer = streamed(field)
        field.moveCaret(to: 0)
        writer.apply(.revise(whole))
        field.moveCaret(to: field.string.utf16.count)
        #expect(writer.finish(rawText: "hello world how are you", cleanedText: cleaned, delivery: .live) == .copy(cleaned))
        #expect(field.string == "hello world how are you ")
    }

    @Test func insertOnStopWritesTheCleanedTextOnceAtTheEnd() {
        let field = FakeTextTarget()
        let writer = streamed(field, mode: .insertOnStop)
        writer.apply(.revise(hello))
        #expect(field.string.isEmpty)
        #expect(writer.finish(rawText: "hello world how are you", cleanedText: cleaned, delivery: .live) == .done)
        #expect(field.string == cleaned)
    }

    @Test func withoutATargetTheCleanedTextIsPasted() {
        let writer = FieldWriter(target: nil)
        writer.apply(.commit(delta: "hello world "))
        writer.apply(.revise(hello))
        #expect(writer.finish(rawText: "hello world", cleanedText: "Hello world.", delivery: .live) == .paste("Hello world."))
    }

    @Test func versionsSwapAfterALiveRun() {
        let field = FakeTextTarget()
        let writer = streamed(field)
        writer.apply(.revise(whole))
        _ = writer.finish(rawText: "hello world how are you", cleanedText: cleaned, delivery: .live)
        #expect(writer.swapWritten(for: "hello world how are you") == .swapped)
        #expect(field.string == "hello world how are you ")
    }
}
