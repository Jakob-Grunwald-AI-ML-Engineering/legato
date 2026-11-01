import Foundation
import Testing
@testable import LegatoVocabulary

@Test func composerAlternativesRanksFixturesWithinLatencyBudget() async {
    let snapshot = VocabularySnapshot(entries: [
        VocabularyEntry(text: "Kubernetes", kind: .term, source: .manual, lastSeen: Date(), aliases: ["Kubernetis"]),
        VocabularyEntry(text: "Grunwald", kind: .term, source: .manual, lastSeen: Date(), aliases: ["Grunvalt"])
    ])
    let sources: [any AlternativeSource] = [VocabularySource(snapshot: snapshot), CorrectionHistorySource(snapshot: snapshot)]
    for word in ["Kubernetis", "Grunvalt"] {
        let context = AlternativeContext(sentence: word, wordRange: word.startIndex..<word.endIndex, languages: ["de"])
        let start = ContinuousClock.now
        let ranked = await WordAlternatives.rank(word: word, context: context, sources: sources)
        let elapsed = start.duration(to: .now)
        print("Composer alternatives \(word): \(elapsed)")
        #expect(elapsed < .milliseconds(50))
        #expect(ranked.count <= 3)
        #expect(ranked.first?.text == (word == "Kubernetis" ? "Kubernetes" : "Grunwald"))
    }
}

@Test func composerAlternativesUsesBigramBoost() async {
    var pairs = WordPairModel()
    pairs.observe(text: "use beta", at: Date())
    let word = "beto"
    let sentence = "use beto"
    let range = sentence.range(of: word)!
    let context = AlternativeContext(sentence: sentence, wordRange: range)
    let ranked = await WordAlternatives.rank(word: word, context: context, sources: [EngineAlternativesSource(["alpha", "beta"])], wordPairs: pairs)
    // Repeated contextual evidence can overtake the engine's 0.1 rank gap.
    for _ in 0..<5 { pairs.observe(text: "use beta", at: Date()) }
    let boosted = await WordAlternatives.rank(word: word, context: context, sources: [EngineAlternativesSource(["alpha", "beta"])], wordPairs: pairs)
    #expect(ranked.first?.text == "alpha")
    #expect(boosted.first?.text == "beta")
}
