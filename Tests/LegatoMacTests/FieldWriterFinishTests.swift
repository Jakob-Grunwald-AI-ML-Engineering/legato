import LegatoCore
import Testing
@testable import LegatoMac

@MainActor
@Suite struct FieldWriterFinishTests {
    @Test func noTargetPastesTheFinalText() {
        let writer = FieldWriter(target: nil)
        writer.apply(.commit(delta: "Hi"))
        writer.apply(.replaceVolatile("tentative"))
        #expect(writer.finish(finalText: "Hi there") == .paste("Hi there"))
    }

    @Test func noTargetWithoutFinalTextPastesItsOwnTrimmedCommittedText() {
        let writer = FieldWriter(target: nil)
        writer.apply(.commit(delta: " Hello"))
        writer.apply(.commit(delta: " world "))
        #expect(writer.finish(finalText: nil) == .paste("Hello world"))
    }

    @Test func nothingDictatedFinishesDone() {
        #expect(FieldWriter(target: nil).finish(finalText: nil) == .done)
        #expect(FieldWriter(target: nil).finish(finalText: " \n") == .done)
        #expect(FieldWriter(target: FakeTextTarget()).finish(finalText: "") == .done)
        #expect(FieldWriter(target: FakeTextTarget()).finish(finalText: nil) == .done)
    }

    @Test func missingFinalTextFallsBackToWhatWasCommitted() {
        let field = FakeTextTarget()
        let writer = FieldWriter(target: field)
        writer.apply(.commit(delta: "Hi"))
        #expect(writer.finish(finalText: nil) == .done)
    }

    @Test func trailingWhitespaceWeWroteDoesNotCountAsMissing() {
        // The history entry's final text is trimmed; the field got the raw phrases.
        let field = FakeTextTarget()
        let writer = FieldWriter(target: field)
        writer.apply(.commit(delta: "Hello world "))
        #expect(writer.finish(finalText: "Hello world") == .done)
        #expect(field.writes.count == 1)
    }

    // MARK: finishing flushes what the field is still missing

    @Test func finishWritesTextTheFieldIsStillMissing() {
        let field = FakeTextTarget()
        let writer = FieldWriter(target: field)
        writer.apply(.commit(delta: "Hello"))
        #expect(writer.finish(finalText: "Hello world") == .done)
        #expect(field.string == "Hello world")
    }

    @Test func finishWritesEverythingWhenNoEditWasApplied() {
        let field = FakeTextTarget("abc", selection: UTF16Range(location: 1, length: 1))
        let writer = FieldWriter(target: field)
        #expect(writer.finish(finalText: "Hello") == .done)
        #expect(field.string == "aHelloc")
    }

    @Test func flushDoesNotDoubleTheWhitespaceWeAlreadyWrote() {
        let field = FakeTextTarget()
        let writer = FieldWriter(target: field)
        writer.apply(.commit(delta: "Hello  "))
        #expect(writer.finish(finalText: "Hello world") == .done)
        #expect(field.string == "Hello  world")
    }

    @Test func failedFlushCopiesTheRemainder() {
        let field = FakeTextTarget()
        let writer = FieldWriter(target: field)
        writer.apply(.commit(delta: "Hello"))
        field.failWritesAfter = 1
        #expect(writer.finish(finalText: "Hello world") == .copy("world"))
        #expect(writer.degradeReason == .writeFailed)
    }

    @Test func failedFlushOfEverythingPastesTheFullText() {
        let field = FakeTextTarget()
        field.failWritesAfter = 0
        let writer = FieldWriter(target: field)
        #expect(writer.finish(finalText: "Hello") == .paste("Hello"))
    }

    @Test func flushAfterDriftCopiesTheRemainder() {
        let field = FakeTextTarget()
        let writer = FieldWriter(target: field)
        writer.apply(.commit(delta: "Hello"))
        field.externalEdit(UTF16Range(location: 0, length: 1), with: "J")
        #expect(writer.finish(finalText: "Hello world") == .copy("world"))
        #expect(field.string == "Jello")
    }

    @Test func finalTextThatDoesNotContinueWhatWasWrittenIsCopiedWhole() {
        let field = FakeTextTarget()
        let writer = FieldWriter(target: field)
        writer.apply(.commit(delta: "Hello"))
        #expect(writer.finish(finalText: "Howdy world") == .copy("Howdy world"))
        #expect(field.string == "Hello") // never appended blindly
    }
}
