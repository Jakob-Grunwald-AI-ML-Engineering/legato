import Foundation
import LegatoCore
import Testing
@testable import LegatoPostProcessing

@Suite("CleanupStyle")
struct CleanupStyleTests {
    private let en = Locale(identifier: "en-US")

    /// The raw values persist in the settings.
    @Test func rawValuesAreStable() {
        #expect(CleanupStyle.allCases.map(\.rawValue) == ["verbatim", "message", "markdown"])
    }

    @Test func verbatimIsTodaysPromptWithTheStrictGuard() {
        #expect(CleanupStyle.verbatim.prompt.name == CleanupPrompt.standard.name)
        #expect(CleanupStyle.verbatim.cleanupGuard.wordRatio == nil)
        #expect(CleanupStyle.verbatim.cleanupGuard.maxDrift == CleanupGuard.defaultMaxDrift)
    }

    @Test func messageHasIndependentInstructions() {
        let base = CleanupPrompt.standard.instructions(en, ["Legato"])
        let message = CleanupStyle.message.prompt.instructions(en, ["Legato"])
        #expect(!message.hasPrefix(base))
        #expect(message != base)
        for word in ["filler", "false starts", "correct", "grammar", "meaning"] {
            #expect(message.localizedCaseInsensitiveContains(word), "mentions \(word)")
        }
    }

    @Test func messageHasIndependentExamplesAndCompatibleReader() {
        let message = CleanupStyle.message.prompt
        #expect(message.examples(en) != CleanupPrompt.standard.examples(en))
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

@Suite struct WritingModeContractTests {
    @Test func persistedModesAndRefineSelectionRemainCompatible() throws {
        #expect(CleanupStyle(rawValue: "verbatim") == .verbatim)
        #expect(CleanupStyle(rawValue: "message") == .message)
        #expect(CleanupStyle(rawValue: "markdown") == .markdown)
        #expect(CleanupStyle.verbatim.title == "Voice")
        #expect(CleanupStyle.verbatim.refineStyle == .message)
        #expect(CleanupStyle.message.refineStyle == .message)
        #expect(CleanupStyle.markdown.refineStyle == .markdown)
        for mode in CleanupStyle.allCases {
            #expect(try JSONDecoder().decode(CleanupStyle.self, from: JSONEncoder().encode(mode)) == mode)
            #expect(!mode.explanation.isEmpty)
        }
    }

    @Test func emojiPreferenceOnlyChangesMessage() {
        let locale = Locale(identifier: "en")
        for mode in [CleanupStyle.verbatim, .markdown] {
            #expect(mode.prompt(emoji: .expressive).instructions(locale, []) == mode.prompt.instructions(locale, []))
            #expect(mode.prompt(emoji: .expressive).examples(locale) == mode.prompt.examples(locale))
        }
        let off = CleanupStyle.message.prompt.instructions(locale, [])
        #expect(off.contains("Do not add automatic emoji"))
        #expect(off != CleanupStyle.message.prompt(emoji: .subtle).instructions(locale, []))
        #expect(off != CleanupStyle.message.prompt(emoji: .expressive).instructions(locale, []))
        #expect(MessageEmojiStyle.allCases.map(\.rawValue) == ["off", "subtle", "expressive"])
    }

    @Test func modesHaveIndependentWorkedExamplesAndPreserveMixedLanguage() {
        for identifier in ["en-US", "de-DE"] {
            let locale = Locale(identifier: identifier)
            let voice = CleanupStyle.verbatim.prompt.examples(locale)
            let message = CleanupStyle.message.prompt.examples(locale)
            let markdown = CleanupStyle.markdown.prompt.examples(locale)
            #expect(voice != message)
            #expect(message != markdown)
            #expect(markdown != voice)
            for examples in [voice, message, markdown] {
                #expect(examples.contains { $0.assistant.contains("Build") })
                #expect(examples.contains { $0.assistant.contains("Please check") || $0.assistant.contains("Please check".lowercased()) || $0.assistant.contains("Next steps") })
            }
        }
    }
}

/// Prompt construction contracts only: these do not establish real-model writing quality.
@Suite struct CleanupStylePromptQualityTests {
    @Test(arguments: CleanupStyle.allCases)
    func localeRulesPreservePassageLanguagesAndNumericValues(mode: CleanupStyle) {
        let german = mode.prompt.instructions(Locale(identifier: "de-DE"), [])
        let english = mode.prompt.instructions(Locale(identifier: "en-US"), [])
        #expect(german != english)
        #expect(german.contains("Nie übersetzen"))
        #expect(english.contains("Never translate"))
        for instructions in [german, english] {
            #expect(instructions.contains("24-hour"))
            #expect(instructions.contains("numeric values"))
            #expect(instructions.contains("exact dictated emoji type"))
        }
    }

    @Test(arguments: ["de-DE", "en-US"])
    func emojiExamplesReflectPreferenceWithoutChangingDictatedTypes(identifier: String) {
        let locale = Locale(identifier: identifier)
        let german = identifier == "de-DE"
        let serious = german
            ? "Die Untersuchung ist verschoben. Du musst heute nichts klären."
            : "The appointment was postponed. You do not need to decide today."
        let dictated = german ? "Gute Nacht 🌙" : "Welcome home 🌻"
        for (emoji, count) in [(MessageEmojiStyle.off, 0), (.subtle, 1), (.expressive, 2)] {
            let examples = CleanupStyle.message.prompt(emoji: emoji).examples(locale)
            let positive = examples.last?.assistant ?? ""
            #expect(positive.filter { "🙌👏🙂".contains($0) }.count == count)
            #expect(examples.contains { $0.assistant == "<text>\(serious)</text>" })
            #expect(examples.contains { $0.assistant == "<text>\(dictated)</text>" })
            #expect(positive.contains("\n\n"))
        }
    }

    @Test func examplesEndInTheLocaleAndShowLayoutRatherThanCueHeadings() {
        let de = Locale(identifier: "de-DE"), en = Locale(identifier: "en-US")
        #expect(CleanupStyle.message.prompt.examples(de).last?.assistant.hasPrefix("<text>Danke") == true)
        #expect(CleanupStyle.message.prompt.examples(en).last?.assistant.hasPrefix("<text>The rehearsal") == true)
        #expect(CleanupStyle.markdown.prompt.examples(de).last?.assistant.hasPrefix("<text># Werkbank") == true)
        #expect(CleanupStyle.markdown.prompt.examples(en).last?.assistant.hasPrefix("<text># Packing") == true)
        for locale in [de, en] {
            let markdown = CleanupStyle.markdown.prompt
            #expect(markdown.instructions(locale, []).contains("layout cues"))
            #expect(markdown.instructions(locale, []).contains("never create headings named New Paragraph/List"))
            #expect(markdown.examples(locale).contains { $0.assistant.contains("\n\n- ") || $0.assistant.contains("\n\n1. ") })
            #expect(CleanupStyle.message.prompt.instructions(locale, []).contains("Preserve existing paragraphs"))
        }
    }

    @Test func staticPromptBudgetsRemainCompact() {
        for identifier in ["en-US", "de-DE"] {
            let locale = Locale(identifier: identifier)
            for mode in CleanupStyle.allCases {
                for emoji in (mode == .message ? MessageEmojiStyle.allCases : [.off]) {
                    let prompt = mode.prompt(emoji: emoji)
                    let count = prompt.instructions(locale, []).count + prompt.examples(locale).reduce(0) { $0 + $1.user.count + $1.assistant.count }
                    let cap = mode == .verbatim ? 1400 : mode == .message ? 1800 : 1650
                    print("PROMPT_BUDGET \(identifier) \(mode.rawValue) \(emoji.rawValue) \(count) characters")
                    #expect(count <= cap)
                }
            }
        }
    }
}
