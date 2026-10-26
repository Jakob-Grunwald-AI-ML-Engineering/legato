import Foundation
import Testing
@testable import LegatoPostProcessing

private let de = Locale(identifier: "de-DE")
private let en = Locale(identifier: "en-US")

@Suite("CleanupPromptVariants")
struct CleanupVariantTests {
    private func variant(_ name: String) throws -> CleanupPrompt {
        try #require(CleanupPromptVariants.named(name), "no variant \(name)")
    }

    @Test func atLeastFiveVariantsWithDistinctNames() {
        let names = CleanupPromptVariants.all.map(\.name)
        #expect(names.count >= 5)
        #expect(Set(names).count == names.count)
        for required in ["V0", "V1", "V2", "V3", "V4a", "V4b"] { #expect(names.contains(required), "missing \(required)") }
    }

    @Test func v0IsTodaysPromptWithTheExamplesInsideTheSystemText() throws {
        let v0 = try variant("V0")
        #expect(v0.examples(de).isEmpty)
        #expect(v0.instructions(de, []).contains("Examples:"))
        #expect(v0.userMessage("hallo welt", de, []).contains("<transcript>\nhallo welt\n</transcript>"))
    }

    @Test func v1MovesTheSameExamplesIntoChatTurns() throws {
        let v1 = try variant("V1")
        let turns = v1.examples(de)
        #expect(!turns.isEmpty)
        #expect(!v1.instructions(de, []).contains("Examples:"))
        // The user turn is formatted like a real request, the answer is the bare cleaned text.
        for turn in turns {
            #expect(turn.user.contains("<transcript>"))
            #expect(!turn.assistant.contains("<transcript>"))
        }
    }

    @Test func v2WritesGermanInstructionsForGermanAndEnglishForEnglish() throws {
        let v2 = try variant("V2")
        #expect(v2.instructions(de, []).contains("Satzzeichen"))
        #expect(!v2.instructions(de, []).contains("punctuation"))
        #expect(v2.instructions(en, []).contains("punctuation"))
        #expect(!v2.instructions(en, []).contains("Satzzeichen"))
    }

    @Test func v2ShowsExamplesInTheLanguageOfTheTranscript() throws {
        let v2 = try variant("V2")
        let germanText = v2.examples(de).map(\.assistant).joined(separator: " ")
        let englishText = v2.examples(en).map(\.assistant).joined(separator: " ")
        #expect(germanText.contains("Uhr") || germanText.contains("Euro"))
        #expect(!englishText.contains("Uhr"))
        #expect(!v2.examples(de).isEmpty && !v2.examples(en).isEmpty)
    }

    @Test func v3HasShortInstructionsAndSixToEightExamples() throws {
        let v3 = try variant("V3")
        for locale in [de, en] {
            let lines = v3.instructions(locale, []).split(separator: "\n").filter { !$0.allSatisfy(\.isWhitespace) }
            #expect(lines.count <= 4, "\(lines.count) lines")
            #expect((6 ... 8).contains(v3.examples(locale).count))
        }
    }

    @Test func v3ExamplesAreDiverse() throws {
        let examples = try variant("V3").examples(de)
        let outputs = examples.map(\.assistant).joined(separator: "\n")
        // digits, a question, several sentences, and both languages
        #expect(outputs.contains { $0.isNumber })
        #expect(outputs.contains("?"))
        #expect(examples.contains { CleanupGuard.sentenceCount($0.assistant) >= 2 })
        #expect(outputs.contains("Uhr") || outputs.contains("Euro"))
        #expect(outputs.contains("The ") || outputs.contains("I "))
    }

    @Test func v4PutsTheVocabularyInTheUserMessageAndNotInTheInstructions() throws {
        for name in ["V4a", "V4b"] {
            let v4 = try variant(name)
            let instructions = v4.instructions(de, ["Legato", "Grunwald"])
            #expect(!instructions.contains("Legato"), "\(name)")
            let message = v4.userMessage("hallo ligato", de, ["Legato", "Grunwald"])
            #expect(message.contains("Legato") && message.contains("Grunwald") && message.contains("hallo ligato"), "\(name)")
        }
    }

    @Test func otherVariantsPutTheVocabularyInTheInstructions() throws {
        for name in ["V0", "V1", "V2", "V3"] {
            let v = try variant(name)
            #expect(v.instructions(en, ["Legato", "Grunwald"]).contains("Legato"), "\(name)")
            #expect(!v.userMessage("hello", en, ["Legato", "Grunwald"]).contains("Legato"), "\(name)")
        }
    }

    @Test func aVariantWithoutVocabularyAddsNoVocabularyText() throws {
        for variant in CleanupPromptVariants.all {
            let message = variant.userMessage("hello there", en, [])
            #expect(message.contains("hello there"))
            #expect(!message.lowercased().contains("vocabulary"), "\(variant.name)")
            #expect(!message.contains("Wortschatz"), "\(variant.name)")
        }
    }

    // MARK: no fixture text in the examples

    private func shingles(_ text: String, size: Int = 5) -> Set<String> {
        let tokens = CleanupScorer.tokens(text, caseSensitive: false)
        guard tokens.count >= size else { return [] }
        return Set((0 ... tokens.count - size).map { tokens[$0 ..< $0 + size].joined(separator: " ") })
    }

    @Test func noExampleReusesFixtureText() throws {
        var fixtureShingles = Set<String>()
        for split in CleanupSplit.allCases {
            for fixture in try CleanupFixtures.load(split) {
                fixtureShingles.formUnion(shingles(fixture.input))
                fixtureShingles.formUnion(shingles(fixture.reference))
            }
        }
        for variant in CleanupPromptVariants.all {
            for locale in [de, en] {
                for example in variant.examples(locale) {
                    for text in [example.user, example.assistant] {
                        let overlap = shingles(text).intersection(fixtureShingles)
                        #expect(overlap.isEmpty, "\(variant.name): \(overlap)")
                    }
                }
                // V0 keeps its examples in the system text.
                let overlap = shingles(variant.instructions(locale, [])).intersection(fixtureShingles)
                #expect(overlap.isEmpty, "\(variant.name) instructions: \(overlap)")
            }
        }
    }

    @Test func everyExampleAnswerIsAFaithfulCleanupOfItsInput() throws {
        // An example the guard would reject teaches the model to drift.
        let cleanupGuard = CleanupGuard()
        for variant in CleanupPromptVariants.all {
            for locale in [de, en] {
                for example in variant.examples(locale) {
                    let input = example.user
                    // Strip the request wrapper to get the transcript the answer belongs to.
                    let transcript = CleanupPromptVariants.transcript(inUserMessage: input)
                    let answer = variant.extractText(example.assistant)
                    #expect(cleanupGuard.accepts(answer, reference: transcript), "\(variant.name): \(input)")
                }
            }
        }
    }

    // MARK: V5 - tagged input and output

    private let tagged = ["V5a", "V5b", "V5c"]

    @Test func taggedVariantsAnswerInTextTagsInEveryExample() throws {
        for name in tagged {
            let v = try variant(name)
            for locale in [de, en] {
                let examples = v.examples(locale)
                #expect(!examples.isEmpty, "\(name)")
                for example in examples {
                    #expect(example.assistant.hasPrefix("<text>") && example.assistant.hasSuffix("</text>"), "\(name): \(example.assistant)")
                    #expect(!v.extractText(example.assistant).contains("<"), "\(name)")
                }
            }
        }
    }

    @Test func taggedVariantsReadTheTextOutOfTheTags() throws {
        for name in tagged {
            let v = try variant(name)
            #expect(v.extractText("Sure! <text>Hello, world.</text> Hope that helps.") == "Hello, world.", "\(name)")
            #expect(v.extractText("<text>\nHello, world.\n</text>") == "Hello, world.", "\(name)")
            // A reply cut off before the closing tag still yields its text.
            #expect(v.extractText("<text>Hello, world.") == "Hello, world.", "\(name)")
            // No tags at all: the plain reply, wrappers stripped.
            #expect(v.extractText("\"Hello, world.\"") == "Hello, world.", "\(name)")
        }
    }

    @Test func taggedVariantsSendTermsAndTextInTags() throws {
        for name in tagged {
            let v = try variant(name)
            let withTerms = v.userMessage("hallo ligato", de, ["Legato", "Grunwald"])
            #expect(withTerms.contains("<terms>Legato, Grunwald</terms>"), "\(name)")
            #expect(withTerms.contains("<text>\nhallo ligato\n</text>"), "\(name)")
            #expect(!v.instructions(de, ["Legato", "Grunwald"]).contains("Legato"), "\(name)")
            let without = v.userMessage("hallo welt", de, [])
            #expect(!without.contains("<terms>"), "\(name)")
            #expect(without.contains("<text>\nhallo welt\n</text>"), "\(name)")
        }
    }

    @Test func v5bAddsNumberExamplesToV5a() throws {
        for locale in [de, en] {
            #expect(try variant("V5b").examples(locale).count > variant("V5a").examples(locale).count)
        }
    }
}
