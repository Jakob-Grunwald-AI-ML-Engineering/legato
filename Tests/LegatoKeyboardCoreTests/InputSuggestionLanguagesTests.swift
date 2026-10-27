import Testing
@testable import LegatoKeyboardCore

@Suite struct InputSuggestionLanguagesTests {
    @Test func theChosenDictationLanguagesComeFirstAsBareCodes() {
        #expect(SuggestionLanguages.codes(stored: ["de_DE", "en_US"], system: ["fr-FR"]) == ["de", "en"])
    }

    @Test func withoutAChoiceTheSystemLanguagesAreUsedWithoutRepeats() {
        #expect(SuggestionLanguages.codes(stored: [], system: ["de-DE", "en-GB", "de-AT"]) == ["de", "en"])
    }

    @Test func withNothingAtAllItIsEnglish() {
        #expect(SuggestionLanguages.codes(stored: [], system: []) == ["en"])
    }
}
