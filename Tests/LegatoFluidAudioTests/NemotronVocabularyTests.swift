import FluidAudio
import LegatoCore
import Synchronization
import Testing
@testable import LegatoFluidAudio

/// A provider that records which sink and limit it was asked for.
private final class RecordingProvider: VocabularyHintProvider {
    struct Call: Equatable { var sink: HintSink; var limit: Int }
    private let recorded = Mutex<[Call]>([])
    let answer: [VocabularyHint]
    init(_ answer: [VocabularyHint]) { self.answer = answer }
    var calls: [Call] { recorded.withLock { $0 } }
    func hints(for sink: HintSink, limit: Int) async -> [VocabularyHint] {
        recorded.withLock { $0.append(Call(sink: sink, limit: limit)) }
        return answer
    }
}

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

    @Test func asksTheProviderForTheNemotronSinkWithAFiftyTermLimitAndMapsTheAnswer() async {
        let provider = RecordingProvider([VocabularyHint(text: "Grünwald", spellings: ["Grunwald"])])
        let terms = await NemotronVocabulary.terms(from: provider)
        #expect(provider.calls == [.init(sink: .nemotron, limit: 50)])
        #expect(terms.map(\.text) == ["Grünwald"])
        #expect(terms.first?.aliases == ["Grunwald"])
    }
}
