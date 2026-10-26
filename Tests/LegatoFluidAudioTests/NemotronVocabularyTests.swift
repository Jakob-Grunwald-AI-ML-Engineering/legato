import FluidAudio
import LegatoCore
import Testing
@testable import LegatoFluidAudio

@Suite("Nemotron vocabulary mapping")
struct NemotronVocabularyTests {
    @Test func mapsTextAndLeavesTheWeightToTheDefault() {
        let terms = NemotronVocabulary.terms([VocabularyHint(text: "Kubernetes")])
        #expect(terms.count == 1)
        #expect(terms[0].text == "Kubernetes")
        #expect(terms[0].weight == nil)
        #expect(terms[0].aliases == nil)
    }

    @Test func mapsSpellingsToAliases() {
        let terms = NemotronVocabulary.terms([VocabularyHint(text: "Grünwald", spellings: ["Grunwald", "Gruenwald"])])
        #expect(terms[0].text == "Grünwald")
        #expect(terms[0].aliases == ["Grunwald", "Gruenwald"])
    }

    @Test func dropsDuplicateTermsAndAliases() {
        let terms = NemotronVocabulary.terms([
            VocabularyHint(text: "Claude", spellings: ["Claude", "claude", "Klaud", "Klaud"]),
            VocabularyHint(text: "claude"),
        ])
        #expect(terms.count == 1)
        #expect(terms[0].text == "Claude")
        #expect(terms[0].aliases == ["Klaud"])
    }

    @Test func noHintsMeansNoTerms() {
        #expect(NemotronVocabulary.terms([]).isEmpty)
    }

    @Test func skipsBlankText() {
        #expect(NemotronVocabulary.terms([VocabularyHint(text: "  ")]).isEmpty)
    }
}
