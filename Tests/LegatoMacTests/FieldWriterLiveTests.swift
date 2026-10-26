import LegatoCore
import Testing
@testable import LegatoMac

/// Live cleanup on the Mac: a cleaned segment replaces its raw text in the field with one verified write
/// while the field still reads as the writer left it and the caret is right after its text; otherwise the
/// revision is skipped and the writer keeps going.
@MainActor
@Suite struct FieldWriterLiveTests {
    private let hello = TranscriptRevision(start: 0, raw: "hello world ", text: "Hello world. ")
    private let howAreYou = TranscriptRevision(start: 12, raw: "how are you ", text: "How are you? ")
    private let cleaned = "Hello world. How are you?"

    private func streamed(_ field: FakeTextTarget, mode: FieldWriter.Mode = .streamCommitted) -> FieldWriter {
        let writer = FieldWriter(target: field, mode: mode)
        writer.apply(.commit(delta: "hello world "))
        writer.apply(.commit(delta: "how are you "))
        return writer
    }

    @Test func aRevisionReplacesItsSegmentWithOneVerifiedWrite() {
        let field = FakeTextTarget("Dear ")
        let writer = streamed(field)
        let before = field.writes.count
        writer.apply(.revise(hello))
        #expect(field.string == "Dear Hello world. how are you ")
        #expect(field.writes.count == before + 1)
        #expect(writer.degradeReason == nil)
    }

    @Test func theCaretStaysAfterTheDictatedText() {
        let field = FakeTextTarget("Dear ")
        let writer = streamed(field)
        writer.apply(.revise(hello))
        #expect(field.selection == UTF16Range(location: field.string.utf16.count, length: 0))
        writer.apply(.commit(delta: "bye"))
        #expect(field.string == "Dear Hello world. how are you bye")
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

    @Test func aRevisionIsSkippedWhenTheCaretMovedAndALaterOneStillApplies() {
        let field = FakeTextTarget()
        let writer = streamed(field)
        field.moveCaret(to: 0)
        writer.apply(.revise(hello))
        #expect(field.string == "hello world how are you ")
        field.moveCaret(to: field.string.utf16.count)
        writer.apply(.revise(howAreYou))
        #expect(field.string == "hello world How are you? ")
    }

    @Test func aRevisionIsSkippedWhenTheSegmentWasEdited() {
        let field = FakeTextTarget()
        let writer = streamed(field)
        field.externalEdit(UTF16Range(location: 0, length: 1), with: "J")
        writer.apply(.revise(hello))
        #expect(field.string == "Jello world how are you ")
    }

    @Test func theFirstSegmentsLeadingWhitespaceThatWasNeverWrittenIsHandled() {
        let field = FakeTextTarget()
        let writer = FieldWriter(target: field)
        writer.apply(.commit(delta: " hello world"))
        #expect(field.string == "hello world")
        writer.apply(.revise(TranscriptRevision(start: 0, raw: " hello world", text: " Hello world.")))
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

    @Test func aLiveRunWhoseRevisionsAllLandedIsDone() {
        let field = FakeTextTarget()
        let writer = streamed(field)
        writer.apply(.revise(hello))
        writer.apply(.revise(howAreYou))
        #expect(writer.finish(rawText: "hello world how are you", cleanedText: cleaned, delivery: .live) == .done)
        #expect(field.string == "Hello world. How are you? ")
    }

    @Test func aLiveRunWithASkippedRevisionCopiesTheCleanedTextAndLeavesTheField() {
        let field = FakeTextTarget()
        let writer = streamed(field)
        field.moveCaret(to: 0)
        writer.apply(.revise(hello))
        field.moveCaret(to: field.string.utf16.count)
        writer.apply(.revise(howAreYou))
        #expect(writer.finish(rawText: "hello world how are you", cleanedText: cleaned, delivery: .live) == .copy(cleaned))
        #expect(field.string == "hello world How are you? ")
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
        writer.apply(.revise(hello))
        writer.apply(.revise(howAreYou))
        _ = writer.finish(rawText: "hello world how are you", cleanedText: cleaned, delivery: .live)
        #expect(writer.swapWritten(for: "hello world how are you") == .swapped)
        #expect(field.string == "hello world how are you ")
    }
}
