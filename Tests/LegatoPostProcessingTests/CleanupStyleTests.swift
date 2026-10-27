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

@Suite("CleanupGuard message faithfulness")
struct CleanupGuardMessageFaithfulnessTests {
    @Test func anAnswerToADictatedQuestionIsRejected() {
        #expect(!CleanupGuard.message.accepts("Paris is the capital of France.", reference: "what is the capital of france"))
    }

    @Test func aTranslationIsRejected() {
        #expect(!CleanupGuard.message.accepts(
            "Wir sollten uns am Donnerstag treffen.", reference: "um we should meet on thursday"))
    }

    @Test func aRewordingWithNewContentIsRejected() {
        #expect(!CleanupGuard.message.accepts(
            "Let's schedule it for Thursday.", reference: "uh we should meet on thursday"))
    }

    @Test func fillersAndASpokenCorrectionStillPass() {
        #expect(CleanupGuard.message.accepts(
            "I think we should meet on Thursday.",
            reference: "um so i think uh we should meet on friday no wait thursday"))
    }

    @Test func germanFillersAndACorrectionStillPass() {
        #expect(CleanupGuard.message.accepts(
            "Ich glaube, wir sollten uns am Donnerstag treffen.",
            reference: "äh also ich glaube halt wir sollten uns am freitag nee doch donnerstag treffen"))
    }

    @Test func aGrammarFixThatAddsAFunctionWordStillPasses() {
        #expect(CleanupGuard.message.accepts(
            "I'm going to send you the report tomorrow.",
            reference: "um i gonna send you the report tomorrow"))
    }

    @Test func numbersWrittenAsDigitsStillPass() {
        #expect(CleanupGuard.message.accepts(
            "The meeting is at 3:30 in room 12.", reference: "uh the meeting is at three thirty in room twelve"))
    }

    @Test func oneMisheardWordFixedInALongMessageStillPasses() {
        let spoken = "hey so um i wanted to let you know that the new legato build is ready and you can try it on your fone tonight"
        #expect(CleanupGuard.message.accepts(
            "Hey, I wanted to let you know that the new Legato build is ready and you can try it on your phone tonight.",
            reference: spoken))
    }
}
