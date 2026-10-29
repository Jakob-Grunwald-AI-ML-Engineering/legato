import Foundation
import Testing
@testable import LegatoPostProcessing

@Suite struct CleanupAgentPromptTests {
    private let sentences: [CleanupPrompt.Agent.Sentence] = [
        .init(number: 1, text: "Hello there.", role: .keep),
        .init(number: 2, text: "Teh fox.", role: .review),
        .init(number: 3, text: "Mine now.", role: .locked),
    ]

    @Test func requestNumbersSentencesAndNamesReviewAndLocked() {
        let request = CleanupPrompt.Agent.request(sentences: sentences, locale: Locale(identifier: "en"), vocabulary: ["Legato"])
        #expect(request.contains("1. Hello there.\n2. Teh fox.\n3. Mine now."))
        #expect(request.contains("Review: 2."))
        #expect(request.contains("Locked: 3."))
        #expect(request.contains("<terms>Legato</terms>"))
    }

    @Test func requestWithoutLockedOrReviewSaysSo() {
        let request = CleanupPrompt.Agent.request(
            sentences: [.init(number: 1, text: "Done.", role: .keep)], locale: Locale(identifier: "de"), vocabulary: [])
        #expect(request.contains("Review: none."))
        #expect(!request.contains("Locked:"))
        #expect(!request.contains("<terms>"))
    }

    @Test func statelessPromptIsUnchanged() {
        let instructions = CleanupPrompt.standard.instructions(Locale(identifier: "en"), [])
        #expect(!instructions.contains("numbered sentences"))
        #expect(CleanupPrompt.standard.userMessage("x", Locale(identifier: "en"), []) == "<text>\nx\n</text>")
    }

    @Test func theSessionHeadLeavesTheReplyFormatToEachRequest() {
        let head = CleanupPrompt.Agent.sessionHead(locale: Locale(identifier: "en"))
        #expect(!head.contains("<text>"))
        #expect(head.contains("Every request states the reply format"))
        #expect(CleanupPrompt.sessionRequest("<text>\nx\n</text>").hasSuffix("Reply only in <text></text>, nothing else."))
    }

    @Test func requestCarriesStyleEmojiAndNumberSettings() {
        let en = Locale(identifier: "en")
        let one = [CleanupPrompt.Agent.Sentence(number: 1, text: "Hi.", role: .review)]
        let markdown = CleanupPrompt.Agent.request(sentences: one, locale: en, vocabulary: [], style: .markdown)
        #expect(markdown.contains("Markdown"))
        let message = CleanupPrompt.Agent.request(sentences: one, locale: en, vocabulary: [], style: .message, emoji: .expressive)
        #expect(message.contains("ready-to-send"))
        #expect(message.contains("expressive emoji"))
        let digits = CleanupPrompt.Agent.request(sentences: one, locale: en, vocabulary: [], itn: true)
        #expect(digits.contains("as digits"))
        #expect(!CleanupPrompt.Agent.request(sentences: one, locale: en, vocabulary: []).contains("as digits"))
    }
}
