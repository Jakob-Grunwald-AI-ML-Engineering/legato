import LegatoCore
import Testing
@testable import LegatoMac

/// A cancelled run (chord during a hold) removes what it typed, when the field still shows exactly that.
@MainActor
@Suite struct FieldWriterRevertTests {
    @Test func revertWithNothingWrittenIsANoOp() {
        let field = FakeTextTarget("abc")
        let writer = FieldWriter(target: field)
        #expect(writer.revert() == .nothingWritten)
        #expect(field.writes.isEmpty)
    }

    @Test func revertWithoutTargetIsNothingWritten() {
        let writer = FieldWriter(target: nil)
        writer.apply(.commit(delta: "Hello"))
        #expect(writer.revert() == .nothingWritten)
    }

    @Test func revertRemovesTheTypedSpan() {
        let field = FakeTextTarget("Dear ")
        let writer = FieldWriter(target: field)
        writer.apply(.commit(delta: "Hello"))
        writer.apply(.commit(delta: " world"))
        #expect(field.string == "Dear Hello world")
        #expect(writer.revert() == .removed)
        #expect(field.string == "Dear ")
    }

    @Test func revertRestoresTheSelectionTheFirstWriteReplaced() {
        let field = FakeTextTarget("Hello there", selection: UTF16Range(location: 6, length: 5))
        let writer = FieldWriter(target: field)
        writer.apply(.commit(delta: "friend"))
        #expect(field.string == "Hello friend")
        #expect(writer.revert() == .removed)
        #expect(field.string == "Hello there")
    }

    @Test func revertRemovesTentativeTextInLiveMode() {
        let field = FakeTextTarget()
        let writer = FieldWriter(target: field, mode: .streamLive)
        writer.apply(.commit(delta: "Hello"))
        writer.apply(.replaceVolatile(" wor"))
        #expect(field.string == "Hello wor")
        #expect(writer.revert() == .removed)
        #expect(field.string == "")
    }

    @Test func revertLeavesAnEditedSpanAndTouchesNothing() {
        let field = FakeTextTarget()
        let writer = FieldWriter(target: field)
        writer.apply(.commit(delta: "Hello"))
        field.externalEdit(UTF16Range(location: 0, length: 1), with: "J")
        let writesBefore = field.writes.count
        #expect(writer.revert() == .leftInPlace)
        #expect(field.string == "Jello")
        #expect(field.writes.count == writesBefore)
    }

    @Test func revertLeavesTheTextWhenFocusMovedOn() {
        let field = FakeTextTarget()
        let writer = FieldWriter(target: field)
        writer.apply(.commit(delta: "Hello"))
        field.focused = false
        #expect(writer.revert() == .leftInPlace)
        #expect(field.string == "Hello")
    }

    @Test func revertLeavesTextWhenTheFieldCannotBeRead() {
        let field = FakeTextTarget()
        let writer = FieldWriter(target: field)
        writer.apply(.commit(delta: "Hello"))
        field.failReads = true
        #expect(writer.revert() == .leftInPlace)
        #expect(field.string == "Hello")
    }

    @Test func revertThatDoesNotLandIsLeftInPlace() {
        let field = FakeTextTarget()
        let writer = FieldWriter(target: field)
        writer.apply(.commit(delta: "Hello"))
        field.ignoreWrites = true
        #expect(writer.revert() == .leftInPlace)
        #expect(field.string == "Hello")
    }

    @Test func writerIsClosedAfterARevert() {
        let field = FakeTextTarget()
        let writer = FieldWriter(target: field)
        writer.apply(.commit(delta: "Hello"))
        #expect(writer.revert() == .removed)
        let writes = field.writes.count
        writer.apply(.commit(delta: " late")) // an edit still in flight when the run was cancelled
        #expect(field.writes.count == writes)
        #expect(field.string == "")
        #expect(writer.revert() == .nothingWritten)
    }

    @Test func writerIsClosedEvenWhenTheRevertLeftTheText() {
        let field = FakeTextTarget()
        let writer = FieldWriter(target: field)
        writer.apply(.commit(delta: "Hello"))
        field.focused = false
        #expect(writer.revert() == .leftInPlace)
        field.focused = true
        writer.apply(.commit(delta: " late"))
        #expect(field.string == "Hello")
    }

    @Test func degradedWriterWithOnlyVerifiedTextStillReverts() {
        let field = FakeTextTarget()
        let writer = FieldWriter(target: field)
        writer.apply(.commit(delta: "Hello"))
        field.focused = false
        writer.apply(.commit(delta: " world")) // degrades: focusLost
        field.focused = true
        #expect(writer.revert() == .removed)
        #expect(field.string == "")
    }
}
