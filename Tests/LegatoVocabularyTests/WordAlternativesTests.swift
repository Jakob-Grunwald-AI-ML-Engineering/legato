import Foundation
import Testing
@testable import LegatoVocabulary

private struct Stub: AlternativeSource {
    var items: [ScoredCandidate]
    func candidates(for word: String, context: AlternativeContext) async -> [ScoredCandidate] { items }
}

private struct FakeSpell: SpellChecking {
    var guessesByWord: [String: [String]] = [:]
    func isKnown(_ word: String, language: String) async -> Bool { false }
    func guesses(for word: String, language: String) async -> [String] { guessesByWord[word] ?? [] }
}

private func context(_ sentence: String, tapping word: String, languages: [String] = ["en"]) -> AlternativeContext {
    AlternativeContext(sentence: sentence, wordRange: sentence.range(of: word)!, languages: languages)
}

private func snapshot(_ entries: VocabularyEntry...) -> VocabularySnapshot {
    VocabularySnapshot(entries: entries)
}

private func entry(_ text: String, blocked: Bool = false, aliases: [String] = []) -> VocabularyEntry {
    VocabularyEntry(text: text, lastSeen: Date(timeIntervalSince1970: 0), blocked: blocked, aliases: aliases)
}

private func c(_ text: String, _ score: Double, _ kind: AlternativeKind) -> ScoredCandidate {
    ScoredCandidate(text: text, score: score, source: kind)
}

@Suite("WordAlternatives")
struct WordAlternativesTests {
    private let ctx = context("send it to kloud now", tapping: "kloud")

    @Test func emptySourcesGiveAnEmptyResult() async {
        #expect(await WordAlternatives.rank(word: "kloud", context: ctx, sources: []) == [])
        #expect(await WordAlternatives.rank(word: "kloud", context: ctx, sources: [Stub(items: [])]) == [])
    }

    @Test func returnsAtMostThreeBestFirst() async {
        let source = Stub(items: [c("a", 0.5, .vocabulary), c("b", 0.9, .vocabulary), c("c", 0.7, .vocabulary), c("d", 0.8, .vocabulary)])
        let out = await WordAlternatives.rank(word: "kloud", context: ctx, sources: [source])
        #expect(out.map(\.text) == ["b", "d", "c"])
    }

    @Test func neverReturnsTheWordItselfInAnyCase() async {
        let source = Stub(items: [c("KLOUD", 1, .engine), c("Kloud", 0.9, .vocabulary), c("Claude", 0.6, .vocabulary)])
        let out = await WordAlternatives.rank(word: "kloud", context: ctx, sources: [source])
        #expect(out.map(\.text) == ["Claude"])
    }

    @Test func deduplicatesCaseInsensitivelyKeepingTheBestScore() async {
        let source = Stub(items: [c("claude", 0.5, .spellChecker), c("Claude", 0.9, .vocabulary), c("CLAUDE", 0.7, .engine)])
        let out = await WordAlternatives.rank(word: "kloud", context: ctx, sources: [source])
        #expect(out.map(\.text) == ["Claude"])
        #expect(out.first?.source == .vocabulary)
    }

    @Test func atEqualScoreEngineBeatsVocabularyBeatsSpellChecker() async {
        let sources: [any AlternativeSource] = [
            Stub(items: [c("spell", 0.7, .spellChecker)]),
            Stub(items: [c("vocab", 0.7, .vocabulary)]),
            Stub(items: [c("engine", 0.7, .engine)]),
        ]
        let out = await WordAlternatives.rank(word: "kloud", context: ctx, sources: sources)
        #expect(out.map(\.text) == ["engine", "vocab", "spell"])
    }

    @Test func aHigherRawScoreStillBeatsALowerPriorSource() async {
        let sources: [any AlternativeSource] = [
            Stub(items: [c("spell", 0.9, .spellChecker)]), Stub(items: [c("engine", 0.6, .engine)]),
        ]
        let out = await WordAlternatives.rank(word: "kloud", context: ctx, sources: sources)
        #expect(out.map(\.text) == ["spell", "engine"])
    }

    @Test func aVocabularyTermBeatsTheSpellCheckersSameGuess() async {
        let sentence = "we run kubernetis in prod"
        let context = context(sentence, tapping: "kubernetis")
        let sources: [any AlternativeSource] = [
            SpellCheckerSource(checker: FakeSpell(guessesByWord: ["kubernetis": ["Kubernetes", "kibernetics"]])),
            VocabularySource(snapshot: snapshot(entry("Kubernetes"))),
        ]
        let out = await WordAlternatives.rank(word: "kubernetis", context: context, sources: sources)
        #expect(out.first?.text == "Kubernetes")
        #expect(out.first?.source == .vocabulary)
        #expect(out.map(\.text) == ["Kubernetes", "kibernetics"])
    }

    @Test func engineAlternativesKeepTheirOrderAndRankHigh() async {
        let sources: [any AlternativeSource] = [
            SpellCheckerSource(checker: FakeSpell(guessesByWord: ["kloud": ["cloud"]])),
            EngineAlternativesSource(["Claude", "clod"]),
        ]
        let out = await WordAlternatives.rank(word: "kloud", context: ctx, sources: sources)
        #expect(out.map(\.text) == ["Claude", "clod", "cloud"])
    }

    @Test func spellCheckerAsksEveryConfiguredLanguage() async {
        struct PerLanguage: SpellChecking {
            func isKnown(_ word: String, language: String) async -> Bool { false }
            func guesses(for word: String, language: String) async -> [String] { ["\(word)-\(language)"] }
        }
        let out = await WordAlternatives.rank(
            word: "x", context: context("an x here", tapping: "x", languages: ["de", "en"]),
            sources: [SpellCheckerSource(checker: PerLanguage())])
        #expect(out.map(\.text) == ["x-de", "x-en"])
    }

    @Test func vocabularySourceMatchesAMishearingOfATerm() async {
        let out = await WordAlternatives.rank(
            word: "kloud", context: ctx, sources: [VocabularySource(snapshot: snapshot(entry("Claude"), entry("Maya")))])
        #expect(out.map(\.text) == ["Claude"])
    }

    @Test func vocabularySourceMatchesAnAliasButReturnsTheTerm() async {
        let out = await WordAlternatives.rank(
            word: "klaut", context: context("ask klaut now", tapping: "klaut"),
            sources: [VocabularySource(snapshot: snapshot(entry("Claude", aliases: ["klaut"])))])
        #expect(out.map(\.text) == ["Claude"])
    }

    @Test func vocabularySourceSkipsBlockedEntries() async {
        let out = await WordAlternatives.rank(
            word: "kloud", context: ctx, sources: [VocabularySource(snapshot: snapshot(entry("Claude", blocked: true)))])
        #expect(out == [])
    }

    @Test func vocabularySourceMatchesTheWordTogetherWithItsNeighbours() async {
        let sentence = "we deploy on kuber netties today"
        let out = await WordAlternatives.rank(
            word: "kuber", context: context(sentence, tapping: "kuber"),
            sources: [VocabularySource(snapshot: snapshot(entry("Kubernetes")))])
        #expect(out.map(\.text) == ["Kubernetes"])
        let second = await WordAlternatives.rank(
            word: "netties", context: context(sentence, tapping: "netties"),
            sources: [VocabularySource(snapshot: snapshot(entry("Kubernetes")))])
        #expect(second.map(\.text) == ["Kubernetes"])
    }

    @Test func vocabularySourceDoesNotMatchUnrelatedNeighbours() async {
        let out = await WordAlternatives.rank(
            word: "deploy", context: context("we deploy on kuber netties today", tapping: "deploy"),
            sources: [VocabularySource(snapshot: snapshot(entry("Kubernetes")))])
        #expect(out == [])
    }
}
