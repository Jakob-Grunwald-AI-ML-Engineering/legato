import Testing
@testable import LegatoKeyboardCore

@Suite struct InputTypedSentenceBufferTests {
    private func type(_ buffer: inout TypedSentenceBuffer, _ text: String) -> String? {
        var out: String?
        for ch in text { if let done = buffer.typed(String(ch)) { out = done } }
        return out
    }

    @Test func aSentenceEndingInAPeriodIsHandedOverOnceFinished() {
        var b = TypedSentenceBuffer()
        #expect(type(&b, "Hello big world") == nil)
        #expect(b.typed(".") == "Hello big world.")
    }

    @Test func aNewlineFinishesTheText() {
        var b = TypedSentenceBuffer()
        _ = type(&b, "see you soon")
        #expect(b.typed("\n") == "see you soon")
    }

    @Test func aBackspaceRemovesTheLastTypedCharacter() {
        var b = TypedSentenceBuffer()
        _ = type(&b, "good dayy")
        b.deleted()
        #expect(b.typed("!") == "good day!")
    }

    @Test func aSingleWordIsNotWorthLearning() {
        var b = TypedSentenceBuffer()
        _ = type(&b, "Okay")
        #expect(b.typed(".") == nil)
        #expect(b.interrupted() == nil)
    }

    @Test func interruptionHandsOverWhatWasTypedSoFarAndStartsOver() {
        var b = TypedSentenceBuffer()
        _ = type(&b, "we meet at noon")
        #expect(b.interrupted() == "we meet at noon")
        #expect(b.interrupted() == nil)
    }

    @Test func aLongRunWithoutAnEndIsHandedOverAtTheCap() {
        var b = TypedSentenceBuffer()
        var handed: String?
        for _ in 0..<TypedSentenceBuffer.maxLength { if let done = b.typed("ab ") { handed = done } }
        #expect(handed != nil)
        #expect((handed?.count ?? 0) <= TypedSentenceBuffer.maxLength + 3)
    }

    @Test func deletingFromAnEmptyBufferIsHarmless() {
        var b = TypedSentenceBuffer()
        b.deleted()
        #expect(b.interrupted() == nil)
    }
}
