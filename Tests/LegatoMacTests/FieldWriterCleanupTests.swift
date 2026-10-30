import LegatoCore
import Testing
@testable import LegatoMac

/// A cleaned text reaching a field the raw text streamed into: Replace swaps it in with one verified write
/// while the field still ends with the raw text, Clipboard leaves the raw text and copies, Hold writes the
/// cleaned text once at the end.
@MainActor
@Suite struct FieldWriterCleanupTests {
    private let raw = "hello world"
    private let cleaned = "Hello, world."

    private func streamed(_ field: FakeTextTarget, mode: FieldWriter.Mode = .streamCommitted) -> FieldWriter {
        let writer = FieldWriter(target: field, mode: mode)
        writer.apply(.commit(delta: "hello"))
        writer.apply(.commit(delta: " world"))
        return writer
    }

    // MARK: Replace

    @Test func replaceSwapsTheStreamedTextForTheCleanedText() {
        let field = FakeTextTarget("Dear ")
        let writer = streamed(field)
        #expect(field.string == "Dear hello world")
        #expect(writer.finish(rawText: raw, cleanedText: cleaned, delivery: .replace) == .done)
        #expect(field.string == "Dear Hello, world.")
    }

    @Test func replaceIsOneWrite() {
        let field = FakeTextTarget()
        let writer = streamed(field)
        let before = field.writes.count
        _ = writer.finish(rawText: raw, cleanedText: cleaned, delivery: .replace)
        #expect(field.writes.count == before + 1)
    }

    @Test func replaceKeepsTrailingWhitespaceTheFieldGot() {
        let field = FakeTextTarget()
        let writer = FieldWriter(target: field)
        writer.apply(.commit(delta: "hello world "))
        #expect(writer.finish(rawText: raw, cleanedText: cleaned, delivery: .replace) == .done)
        #expect(field.string == "Hello, world. ")
    }

    @Test func replaceFlushesAMissingRawTailFirst() {
        let field = FakeTextTarget()
        let writer = FieldWriter(target: field)
        writer.apply(.commit(delta: "hello"))
        #expect(writer.finish(rawText: raw, cleanedText: cleaned, delivery: .replace) == .done)
        #expect(field.string == "Hello, world.")
    }

    @Test func replaceLeavesAnEditedFieldAndCopiesTheCleanedText() {
        let field = FakeTextTarget()
        let writer = streamed(field)
        field.externalEdit(UTF16Range(location: 0, length: 1), with: "J")
        #expect(writer.finish(rawText: raw, cleanedText: cleaned, delivery: .replace) == .copy(cleaned))
        #expect(field.string == "Jello world")
    }

    @Test func replaceLeavesTheFieldWhenTheUserTypedAfterIt() {
        let field = FakeTextTarget()
        let writer = streamed(field)
        field.userTypes(" again")
        #expect(writer.finish(rawText: raw, cleanedText: cleaned, delivery: .replace) == .copy(cleaned))
        #expect(field.string == "hello world again")
    }

    @Test func replaceLeavesTheFieldWhenTheCaretMoved() {
        let field = FakeTextTarget()
        let writer = streamed(field)
        field.moveCaret(to: 0)
        #expect(writer.finish(rawText: raw, cleanedText: cleaned, delivery: .replace) == .copy(cleaned))
        #expect(field.string == "hello world")
    }

    @Test func replaceLeavesTheFieldWhenFocusMoved() {
        let field = FakeTextTarget()
        let writer = streamed(field)
        field.focused = false
        #expect(writer.finish(rawText: raw, cleanedText: cleaned, delivery: .replace) == .copy(cleaned))
        #expect(field.string == "hello world")
    }

    @Test func failedSwapCopiesTheCleanedTextAndKeepsTheRaw() {
        let field = FakeTextTarget()
        let writer = streamed(field)
        field.failWritesAfter = 2
        #expect(writer.finish(rawText: raw, cleanedText: cleaned, delivery: .replace) == .copy(cleaned))
        #expect(field.string == "hello world")
    }

    @Test func ignoredSwapCopiesTheCleanedText() {
        let field = FakeTextTarget()
        let writer = streamed(field)
        field.ignoreWrites = true
        #expect(writer.finish(rawText: raw, cleanedText: cleaned, delivery: .replace) == .copy(cleaned))
        #expect(field.string == "hello world")
    }

    @Test func nothingStreamedYetWritesTheCleanedTextOnce() {
        let field = FakeTextTarget("abc")
        let writer = FieldWriter(target: field)
        #expect(writer.finish(rawText: raw, cleanedText: cleaned, delivery: .replace) == .done)
        #expect(field.string == "abcHello, world.")
        #expect(field.writes.count == 1)
    }

    @Test func noTargetPastesTheCleanedText() {
        let writer = FieldWriter(target: nil)
        writer.apply(.commit(delta: raw))
        #expect(writer.finish(rawText: raw, cleanedText: cleaned, delivery: .replace) == .paste(cleaned))
    }

    @Test func firstWriteIgnoredPastesTheCleanedText() {
        let field = FakeTextTarget()
        field.ignoreWrites = true
        let writer = streamed(field)
        #expect(writer.finish(rawText: raw, cleanedText: cleaned, delivery: .replace) == .paste(cleaned))
    }

    // MARK: Insert on stop

    @Test func insertOnStopWritesOnlyTheCleanedTextAtTheEnd() {
        let field = FakeTextTarget()
        let writer = streamed(field, mode: .insertOnStop)
        #expect(field.string == "")
        #expect(writer.finish(rawText: raw, cleanedText: cleaned, delivery: .replace) == .done)
        #expect(field.string == "Hello, world.")
        #expect(field.writes.count == 1)
    }

    // MARK: Versions after the run

    @Test func swapWrittenGoesBackToTheRawTextAndForwardAgain() {
        let field = FakeTextTarget("Dear ")
        let writer = streamed(field)
        _ = writer.finish(rawText: raw, cleanedText: cleaned, delivery: .replace)
        #expect(writer.swapWritten(for: raw) == .swapped)
        #expect(field.string == "Dear hello world")
        #expect(writer.swapWritten(for: "Hello world!") == .swapped)
        #expect(field.string == "Dear Hello world!")
    }

    @Test func swapWrittenLeavesAFieldThatNoLongerEndsWithOurText() {
        let field = FakeTextTarget()
        let writer = streamed(field)
        _ = writer.finish(finalText: raw)
        field.userTypes(".")
        let before = field.writes.count
        #expect(writer.swapWritten(for: cleaned) == .leftInPlace)
        #expect(field.string == "hello world.")
        #expect(field.writes.count == before)
    }

    @Test func swapWrittenWithNothingWrittenSaysSo() {
        #expect(FieldWriter(target: FakeTextTarget()).swapWritten(for: cleaned) == .nothingWritten)
        #expect(FieldWriter(target: nil).swapWritten(for: cleaned) == .nothingWritten)
    }

    @Test func swapWrittenAfterRevertSaysNothingWritten() {
        let field = FakeTextTarget()
        let writer = streamed(field)
        _ = writer.revert()
        #expect(writer.swapWritten(for: cleaned) == .nothingWritten)
    }
}
