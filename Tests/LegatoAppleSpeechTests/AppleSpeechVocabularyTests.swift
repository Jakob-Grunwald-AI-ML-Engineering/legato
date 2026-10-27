import Foundation
import LegatoCore
import Synchronization
import Testing
@testable import LegatoAppleSpeech

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

    @Test func asksTheProviderForTheAppleSpeechSinkWithAFiftyTermLimitAndFlattensTheAnswer() async {
        let provider = RecordingProvider([VocabularyHint(text: "Grünwald", spellings: ["Grunwald"])])
        let strings = await AppleSpeechVocabulary.contextualStrings(from: provider)
        #expect(provider.calls == [.init(sink: .appleSpeech, limit: 50)])
        #expect(strings == ["Grünwald", "Grunwald"])
    }

    private struct Leaky: Error, CustomStringConvertible {
        var description: String { "could not set context for: my secret dictated sentence" }
    }

    @Test func aLoggedErrorCarriesItsTypeAndCodeButNeverItsDescription() {
        let line = AppleSpeechEngine.describe(Leaky())
        #expect(line.contains("Leaky"))
        #expect(line.contains("secret") == false)
        let ns = NSError(domain: "SFSpeechErrorDomain", code: 7, userInfo: [NSLocalizedDescriptionKey: "heard: my secret"])
        #expect(AppleSpeechEngine.describe(ns).contains("SFSpeechErrorDomain 7"))
        #expect(AppleSpeechEngine.describe(ns).contains("secret") == false)
    }

    @Test func theEngineExposesItsProvider() {
        #expect(AppleSpeechEngine().vocabularyProvider == nil)
    }
}
