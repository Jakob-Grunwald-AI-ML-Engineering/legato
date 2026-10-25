import LegatoCore
import Testing
@testable import LegatoMac

@MainActor
@Suite struct FieldWriterInsertOnStopTests {
    @Test func nothingIsWrittenUntilFinishThenOneVerifiedWrite() {
        let field = FakeTextTarget()
        let writer = FieldWriter(target: field, mode: .insertOnStop)
        writer.apply(.replaceVolatile("hel"))
        writer.apply(.commit(delta: "Hello"))
        writer.apply(.commit(delta: " world"))
        #expect(field.writes.isEmpty)
        #expect(writer.finish(finalText: "Hello world") == .done)
        #expect(field.writes.count == 1)
        #expect(field.string == "Hello world")
    }

    @Test func theSelectionIsReplaced() {
        let field = FakeTextTarget("abcdefghi", selection: UTF16Range(location: 3, length: 3))
        let writer = FieldWriter(target: field, mode: .insertOnStop)
        writer.apply(.commit(delta: "Hello"))
        #expect(writer.finish(finalText: "Hello") == .done)
        #expect(field.string == "abcHelloghi")
    }

    @Test func withoutFinalTextItInsertsItsOwnTrimmedText() {
        let field = FakeTextTarget()
        let writer = FieldWriter(target: field, mode: .insertOnStop)
        writer.apply(.commit(delta: " Hello"))
        writer.apply(.commit(delta: " world "))
        #expect(writer.finish(finalText: nil) == .done)
        #expect(field.string == "Hello world")
    }

    @Test func nothingDictatedWritesNothing() {
        let field = FakeTextTarget()
        let writer = FieldWriter(target: field, mode: .insertOnStop)
        #expect(writer.finish(finalText: nil) == .done)
        #expect(field.writes.isEmpty)
    }

    @Test func noTargetPastes() {
        let writer = FieldWriter(target: nil, mode: .insertOnStop)
        writer.apply(.commit(delta: "Hello"))
        #expect(writer.finish(finalText: "Hello") == .paste("Hello"))
    }

    @Test func throwingWritePastes() {
        let field = FakeTextTarget()
        field.failWritesAfter = 0
        let writer = FieldWriter(target: field, mode: .insertOnStop)
        writer.apply(.commit(delta: "Hello"))
        #expect(writer.finish(finalText: "Hello") == .paste("Hello"))
        #expect(writer.degradeReason == .writeFailed)
        #expect(field.string == "")
    }

    @Test func ignoredWritePastes() {
        let field = FakeTextTarget()
        field.ignoreWrites = true
        let writer = FieldWriter(target: field, mode: .insertOnStop)
        writer.apply(.commit(delta: "Hello"))
        #expect(writer.finish(finalText: "Hello") == .paste("Hello"))
        #expect(writer.degradeReason == .notApplied)
    }

    @Test func lyingWritePastes() {
        let field = FakeTextTarget()
        field.lieOnWrites = true
        let writer = FieldWriter(target: field, mode: .insertOnStop)
        writer.apply(.commit(delta: "Hello"))
        #expect(writer.finish(finalText: "Hello") == .paste("Hello"))
        #expect(writer.degradeReason == .notApplied)
    }

    @Test func lostFocusPastesWithoutWriting() {
        let field = FakeTextTarget()
        let writer = FieldWriter(target: field, mode: .insertOnStop)
        writer.apply(.commit(delta: "Hello"))
        field.focused = false
        #expect(writer.finish(finalText: "Hello") == .paste("Hello"))
        #expect(writer.degradeReason == .focusLost)
        #expect(field.writes.isEmpty)
    }

    @Test func unverifiableWriteIsCopiedNotPasted() {
        let field = FakeTextTarget()
        field.failReads = true
        let writer = FieldWriter(target: field, mode: .insertOnStop)
        writer.apply(.commit(delta: "Hello"))
        #expect(writer.finish(finalText: "Hello") == .copy("Hello"))
    }
}
