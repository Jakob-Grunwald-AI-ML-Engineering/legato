import LegatoCore
import Testing
@testable import LegatoMac

/// The writer's final delivery for a run whose text was cleaned (the agent, or the stop's rewrite, did the rest).
@MainActor
@Suite struct FieldWriterLiveTests {
    private let cleaned = "Hello world. How are you?"

    private func streamed(_ field: FakeTextTarget, mode: FieldWriter.Mode = .streamCommitted) -> FieldWriter {
        let writer = FieldWriter(target: field, mode: mode)
        writer.apply(.commit(delta: "hello world "))
        writer.apply(.commit(delta: "how are you "))
        return writer
    }

    @Test func insertOnStopWritesTheCleanedTextOnceAtTheEnd() {
        let field = FakeTextTarget()
        let writer = streamed(field, mode: .insertOnStop)
        #expect(field.string.isEmpty)
        #expect(writer.finish(rawText: "hello world how are you", cleanedText: cleaned) == .done)
        #expect(field.string == cleaned)
    }

    @Test func withoutATargetTheCleanedTextIsPasted() {
        let writer = FieldWriter(target: nil)
        writer.apply(.commit(delta: "hello world "))
        #expect(writer.finish(rawText: "hello world", cleanedText: "Hello world.") == .paste("Hello world."))
    }

    @Test func versionsSwapAfterACleanedRun() {
        let field = FakeTextTarget()
        let writer = streamed(field)
        #expect(writer.finish(rawText: "hello world how are you", cleanedText: cleaned) == .done)
        #expect(field.string == "Hello world. How are you? ")
        #expect(writer.swapWritten(for: "hello world how are you") == .swapped)
        #expect(field.string == "hello world how are you ")
    }
}
