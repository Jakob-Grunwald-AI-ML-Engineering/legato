import Foundation
import LegatoCore
import Testing
@testable import LegatoPostProcessing

@Suite("CleanupStyle")
struct CleanupStyleTests {
    private let en = Locale(identifier: "en-US")

    /// The raw values persist in the settings.
    @Test func rawValuesAreStable() {
        #expect(CleanupStyle.allCases.map(\.rawValue) == ["verbatim", "message"])
    }

    @Test func verbatimIsTodaysPromptWithTheStrictGuard() {
        #expect(CleanupStyle.verbatim.prompt.name == CleanupPrompt.standard.name)
        #expect(CleanupStyle.verbatim.cleanupGuard.wordRatio == nil)
        #expect(CleanupStyle.verbatim.cleanupGuard.maxDrift == CleanupGuard.defaultMaxDrift)
    }

    @Test func messageAddsToTheSameBasePrompt() {
        let base = CleanupPrompt.standard.instructions(en, ["Legato"])
        let message = CleanupStyle.message.prompt.instructions(en, ["Legato"])
        #expect(message.hasPrefix(base))
        #expect(message.count > base.count)
        for word in ["filler", "false starts", "correct", "grammar", "meaning"] {
            #expect(message.localizedCaseInsensitiveContains(word), "mentions \(word)")
        }
    }

    @Test func messageKeepsTheExamplesUserMessageAndReader() {
        let message = CleanupStyle.message.prompt
        #expect(message.examples(en) == CleanupPrompt.standard.examples(en))
        #expect(message.userMessage("hi", en, ["X"]) == CleanupPrompt.standard.userMessage("hi", en, ["X"]))
        #expect(message.extractText("<text>Hi.</text>") == "Hi.")
    }

    @Test func messageUsesTheLooserGuard() {
        #expect(CleanupStyle.message.cleanupGuard.wordRatio == 0.4 ... 1.3)
    }
}

@Suite("CleanupGuard word ratio")
struct CleanupGuardWordRatioTests {
    private let spoken = "um so i think uh we should meet on friday no wait thursday"

    @Test func aMessageWithoutFillersAndWithTheCorrectionPasses() {
        #expect(CleanupGuard.message.accepts("I think we should meet on Thursday.", reference: spoken))
    }

    @Test func theStrictGuardRejectsThatSameRewrite() {
        #expect(!CleanupGuard().accepts("I think we should meet on Thursday.", reference: spoken))
    }

    @Test func aReplyFarLongerThanTheInputIsRejected() {
        let added = "I think we should meet on Thursday. Let me know if that works for you and what time suits you best."
        #expect(!CleanupGuard.message.accepts(added, reference: spoken))
    }

    @Test func aReplyThatKeepsTooLittleIsRejected() {
        #expect(!CleanupGuard.message.accepts("Thursday.", reference: spoken))
    }

    @Test func anEmptyReplyIsRejected() {
        #expect(!CleanupGuard.message.accepts("", reference: spoken))
    }

    @Test func theBoundsAreInclusive() {
        let guardrail = CleanupGuard(wordRatio: 0.4 ... 1.3)
        let ten = "a b c d e f g h i j"
        #expect(guardrail.accepts("w w w w", reference: ten))  // 4 of 10
        #expect(!guardrail.accepts("w w w", reference: ten))  // 3 of 10
        #expect(guardrail.accepts(Array(repeating: "w", count: 13).joined(separator: " "), reference: ten))
        #expect(!guardrail.accepts(Array(repeating: "w", count: 14).joined(separator: " "), reference: ten))
    }
}
