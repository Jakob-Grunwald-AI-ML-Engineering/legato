import LegatoCore
import Testing
@testable import LegatoAppleSpeech

@Suite("Apple Speech contextual strings")
struct AppleSpeechVocabularyTests {
    @Test func flattensTextThenSpellingsInOrder() {
        let strings = AppleSpeechVocabulary.contextualStrings([
            VocabularyHint(text: "Grünwald", spellings: ["Grunwald"]),
            VocabularyHint(text: "Kubernetes"),
        ])
        #expect(strings == ["Grünwald", "Grunwald", "Kubernetes"])
    }

    @Test func dropsDuplicatesIgnoringCase() {
        let strings = AppleSpeechVocabulary.contextualStrings([
            VocabularyHint(text: "Claude", spellings: ["claude"]),
            VocabularyHint(text: "CLAUDE"),
        ])
        #expect(strings == ["Claude"])
    }

    @Test func noHintsMeansNoStrings() {
        #expect(AppleSpeechVocabulary.contextualStrings([]).isEmpty)
    }

    @Test func skipsBlankStrings() {
        #expect(AppleSpeechVocabulary.contextualStrings([VocabularyHint(text: " ", spellings: [""])]).isEmpty)
    }

    @Test func theEngineExposesItsProvider() {
        #expect(AppleSpeechEngine().vocabularyProvider == nil)
    }
}
