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
    #endif
}
