import Testing
@testable import LegatoVocabulary

@Suite struct PlatformSpellCheckerTests {
    @Test func resolvesBareCodesToTheAvailableVariant() {
        #expect(PlatformSpellChecker.resolve("de", available: ["en_US", "de_DE"]) == "de_DE")
        #expect(PlatformSpellChecker.resolve("en", available: ["en", "de"]) == "en")
        #expect(PlatformSpellChecker.resolve("en", available: ["de_DE", "en_GB"]) == "en_GB")
        #expect(PlatformSpellChecker.resolve("fr", available: ["en", "de"]) == "fr")
        #expect(PlatformSpellChecker.resolve("de-AT", available: ["de_AT", "de"]) == "de")
    }

    #if canImport(AppKit)
    @Test func nonsenseIsUnknownAndACommonWordIsKnownInEnglish() async {
        let checker = PlatformSpellChecker()
        #expect(await checker.isKnown("qzxvbrt", language: "en") == false)
        #expect(await checker.isKnown("the", language: "en") == true)
    }

    @Test func aBatchAnswersEveryDistinctWordForEveryLanguageLikeTheSingleCalls() async {
        let checker = PlatformSpellChecker()
        let words = ["qzxvbrt", "the", "qzxvbrt", ""]
        let batch = await checker.knownLanguages(for: words, languages: ["en", "de"])
        #expect(Set(batch.keys) == ["qzxvbrt", "the", ""])
        for (word, languages) in batch {
            for language in ["en", "de"] {
                #expect(languages.contains(language) == (await checker.isKnown(word, language: language)))
            }
        }
        #expect(batch["qzxvbrt"] == [])
        #expect(batch["the"]?.contains("en") == true)
    }
    #endif
}
