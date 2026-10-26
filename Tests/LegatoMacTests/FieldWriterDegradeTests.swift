import LegatoCore
import Testing
@testable import LegatoMac

/// Failure modes of the streaming modes. Once degraded, the writer never touches the field again.
@MainActor
@Suite struct FieldWriterDegradeTests {
    // MARK: mid-run failures: what is in the field stays, the rest is copied

    @Test func focusLostMidRunStopsWritingAndCopiesTheRemainder() {
        let field = FakeTextTarget()
        let writer = FieldWriter(target: field)
        writer.apply(.commit(delta: "Hello"))
        field.focused = false
        writer.apply(.commit(delta: " world"))
        #expect(writer.degradeReason == .focusLost)
        #expect(field.writes.count == 1)
        #expect(field.string == "Hello")
        #expect(writer.finish(finalText: "Hello world") == .copy("world"))
    }

    @Test func externalEditInsideTheSpanIsDriftAndNothingMoreIsWritten() {
        let field = FakeTextTarget()
        let writer = FieldWriter(target: field)
        writer.apply(.commit(delta: "Hello"))
        field.externalEdit(UTF16Range(location: 0, length: 1), with: "J")
        writer.apply(.commit(delta: " world"))
        #expect(writer.degradeReason == .drift)
        #expect(field.string == "Jello")
        #expect(writer.finish(finalText: "Hello world") == .copy("world"))
    }

    @Test func textInsertedBeforeTheSpanIsDrift() {
        let field = FakeTextTarget()
        let writer = FieldWriter(target: field)
        writer.apply(.commit(delta: "Hello"))
        field.externalEdit(UTF16Range(location: 0, length: 0), with: "Oh, ")
        writer.apply(.commit(delta: " world"))
        #expect(writer.degradeReason == .drift)
        #expect(field.string == "Oh, Hello")
        #expect(writer.finish(finalText: "Hello world") == .copy("world"))
    }

    @Test func textTypedAfterTheSpanIsNotDrift() {
        let field = FakeTextTarget()
        let writer = FieldWriter(target: field)
        writer.apply(.commit(delta: "Hello"))
        field.externalEdit(UTF16Range(location: 5, length: 0), with: "!!")
        writer.apply(.commit(delta: " world"))
        #expect(writer.degradeReason == nil)
        #expect(field.string == "Hello world!!")
    }

    @Test func writeFailureMidRunCopiesTheRemainder() {
        let field = FakeTextTarget()
        field.failWritesAfter = 1
        let writer = FieldWriter(target: field)
        writer.apply(.commit(delta: "Hello"))
        writer.apply(.commit(delta: " world"))
        #expect(writer.degradeReason == .writeFailed)
        #expect(writer.finish(finalText: "Hello world") == .copy("world"))
    }

    @Test func ignoredWriteMidRunIsDetectedByReadback() {
        let field = FakeTextTarget()
        let writer = FieldWriter(target: field)
        writer.apply(.commit(delta: "Hello"))
        field.ignoreWrites = true
        writer.apply(.commit(delta: " world"))
        #expect(writer.degradeReason == .notApplied)
        #expect(writer.finish(finalText: "Hello world") == .copy("world"))
    }

    @Test func lyingWriteMidRunIsDetectedByReadback() {
        let field = FakeTextTarget()
        let writer = FieldWriter(target: field)
        writer.apply(.commit(delta: "Hello"))
        field.lieOnWrites = true
        writer.apply(.commit(delta: " world"))
        #expect(writer.degradeReason == .notApplied)
        #expect(writer.finish(finalText: "Hello world") == .copy("world"))
    }

    @Test func unreadableFieldMidRunDegrades() {
        let field = FakeTextTarget()
        let writer = FieldWriter(target: field)
        writer.apply(.commit(delta: "Hello"))
        field.failReads = true
        writer.apply(.commit(delta: " world"))
        #expect(writer.degradeReason == .unreadable)
        #expect(field.writes.count == 1)
        #expect(writer.finish(finalText: "Hello world") == .copy("world"))
    }

    @Test func everythingAlreadyWrittenFinishesDoneEvenIfFocusIsGoneNow() {
        let field = FakeTextTarget()
        let writer = FieldWriter(target: field)
        writer.apply(.commit(delta: "Hello"))
        field.focused = false
        #expect(writer.finish(finalText: "Hello") == .done)
        #expect(writer.degradeReason == nil)
    }

    // MARK: first write failing: nothing is in the field, so the whole text is pasted once

    @Test func firstWriteThrowingPastesTheFullText() {
        let field = FakeTextTarget()
        field.failWritesAfter = 0
        let writer = FieldWriter(target: field)
        writer.apply(.commit(delta: "Hello"))
        writer.apply(.commit(delta: " world"))
        #expect(writer.degradeReason == .writeFailed)
        #expect(field.writes.count == 1) // no retries once degraded
        #expect(field.string == "")
        #expect(writer.finish(finalText: "Hello world") == .paste("Hello world"))
    }

    @Test func firstWriteIgnoredPastesTheFullText() {
        let field = FakeTextTarget()
        field.ignoreWrites = true
        let writer = FieldWriter(target: field)
        writer.apply(.commit(delta: "Hello"))
        writer.apply(.commit(delta: " world"))
        #expect(writer.degradeReason == .notApplied)
        #expect(writer.finish(finalText: "Hello world") == .paste("Hello world"))
    }

    @Test func firstWriteIgnoredOverASelectionPastesTheFullText() {
        // The field is unchanged (the selection is still there), so nothing of ours is in it.
        let field = FakeTextTarget("Hello there", selection: UTF16Range(location: 6, length: 5))
        field.ignoreWrites = true
        let writer = FieldWriter(target: field)
        writer.apply(.commit(delta: "friend"))
        #expect(writer.degradeReason == .notApplied)
        #expect(field.string == "Hello there")
        #expect(writer.finish(finalText: "friend") == .paste("friend"))
    }

    @Test func firstWriteLyingCopiesTheFullTextNeverPastes() {
        // The field changed but does not show our text: pasting could duplicate what landed.
        let field = FakeTextTarget()
        field.lieOnWrites = true
        let writer = FieldWriter(target: field)
        writer.apply(.commit(delta: "Hello"))
        #expect(writer.degradeReason == .notApplied)
        #expect(writer.finish(finalText: "Hello") == .copy("Hello"))
    }

    @Test func firstWriteTruncatedCopiesTheFullTextNeverPastes() {
        let field = FakeTextTarget()
        field.storeOnlyFirst = 3
        let writer = FieldWriter(target: field)
        writer.apply(.commit(delta: "Hello"))
        #expect(writer.degradeReason == .notApplied)
        #expect(field.string == "Hel")
        #expect(writer.finish(finalText: "Hello") == .copy("Hello"))
    }

    @Test func firstWriteAlteredOverASelectionCopiesTheFullText() {
        let field = FakeTextTarget("Hello there", selection: UTF16Range(location: 6, length: 5))
        field.lieOnWrites = true
        let writer = FieldWriter(target: field)
        writer.apply(.commit(delta: "friend"))
        #expect(writer.finish(finalText: "friend") == .copy("friend"))
    }

    @Test func focusAlreadyGoneAtTheFirstWritePastesTheFullText() {
        let field = FakeTextTarget()
        field.focused = false
        let writer = FieldWriter(target: field)
        writer.apply(.commit(delta: "Hello"))
        #expect(writer.degradeReason == .focusLost)
        #expect(field.writes.isEmpty)
        #expect(writer.finish(finalText: "Hello") == .paste("Hello"))
    }

    @Test func unreadableSelectionAtTheFirstWritePastesTheFullText() {
        let field = FakeTextTarget()
        field.failSelection = true
        let writer = FieldWriter(target: field)
        writer.apply(.commit(delta: "Hello"))
        #expect(writer.degradeReason == .unreadable)
        #expect(field.writes.isEmpty)
        #expect(writer.finish(finalText: "Hello") == .paste("Hello"))
    }

    @Test func unverifiableFirstWriteIsCopiedNotPastedToAvoidADuplicate() {
        // The write may have landed; a pasted copy could then double the text.
        let field = FakeTextTarget()
        field.failReads = true
        let writer = FieldWriter(target: field)
        writer.apply(.commit(delta: "Hello"))
        #expect(writer.degradeReason == .unreadable)
        #expect(writer.finish(finalText: "Hello") == .copy("Hello"))
    }

    // MARK: remainder accounting

    @Test func remainderIsTrimmedForTheClipboard() {
        let field = FakeTextTarget()
        let writer = FieldWriter(target: field)
        writer.apply(.commit(delta: "Hello"))
        field.focused = false
        writer.apply(.commit(delta: " big world "))
        // The field holds "Hello"; the trimmed final text is "Hello big world".
        #expect(writer.finish(finalText: "Hello big world") == .copy("big world"))
    }

    @Test func remainderAccountsForTrailingWhitespaceWeWrote() {
        let field = FakeTextTarget()
        let writer = FieldWriter(target: field)
        writer.apply(.commit(delta: "Hello "))
        field.focused = false
        writer.apply(.commit(delta: "world "))
        #expect(field.string == "Hello ")
        #expect(writer.finish(finalText: "Hello world") == .copy("world"))
    }

    @Test func leadingWhitespaceOfTheFirstPhraseNeverCountsAsWritten() {
        let field = FakeTextTarget()
        let writer = FieldWriter(target: field)
        writer.apply(.commit(delta: " Hello"))
        field.focused = false
        writer.apply(.commit(delta: " world"))
        #expect(field.string == "Hello")
        #expect(writer.finish(finalText: "Hello world") == .copy("world"))
    }

    @Test func degradedWithoutFinalTextUsesItsOwnCommittedText() {
        let field = FakeTextTarget()
        let writer = FieldWriter(target: field)
        writer.apply(.commit(delta: "Hello"))
        field.focused = false
        writer.apply(.commit(delta: " world"))
        #expect(writer.finish(finalText: nil) == .copy("world"))
    }
}
