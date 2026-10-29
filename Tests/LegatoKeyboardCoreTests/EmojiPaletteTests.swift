import Testing
@testable import LegatoKeyboardCore

@Suite struct EmojiPaletteTests {
    @Test func paletteOffersSimpleSkinToneAndJoinedEmojiAsUniqueGraphemes() {
        #expect(EmojiPalette.all.contains("😀"))
        #expect(EmojiPalette.all.contains("👍🏽"))
        #expect(EmojiPalette.all.contains("👩‍💻"))
        #expect(Set(EmojiPalette.all).count == EmojiPalette.all.count)
        #expect(EmojiPalette.all.allSatisfy { $0.count == 1 && $0.unicodeScalars.contains { $0.properties.isEmoji } })
    }

    @Test func typingBufferKeepsComplexEmojiLiteralAndDeletesOneWholeGrapheme() {
        var buffer = TypedSentenceBuffer()
        #expect(buffer.typed("Hello there ") == nil)
        #expect(buffer.typed("👍🏽") == nil)
        #expect(buffer.typed("👩‍💻") == nil)
        buffer.deleted()
        #expect(buffer.typed("!") == "Hello there 👍🏽!")
    }
}
