import Foundation
import Testing
@testable import LegatoVocabulary

private final class FakeCompleter: WordCompleting, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [(prefix: String, languages: [String])] = []
    var results: [String]
    init(_ results: [String]) { self.results = results }
    var calls: [(prefix: String, languages: [String])] { lock.withLock { _calls } }
    func completions(prefix: String, languages: [String]) async -> [String] {
        lock.withLock { _calls.append((prefix, languages)) }
        return results
    }
}

private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

private func entry(_ text: String, score: Double = 1, pinned: Bool = false, blocked: Bool = false, aliases: [String] = []) -> VocabularyEntry {
    VocabularyEntry(text: text, score: score, lastSeen: t0, pinned: pinned, blocked: blocked, aliases: aliases)
}

private func pairs(_ lines: [String]) -> WordPairModel {
    var m = WordPairModel()
    for l in lines { m.observe(text: l, at: t0) }
    return m
}

@Suite("WordSuggester")
struct WordSuggesterTests {
    @Test func vocabularyComesBeforePairsBeforeTheChecker() async {
        let snapshot = VocabularySnapshot(entries: [entry("Helmholtz")])
        let model = pairs(["ich helfe"])
        let completer = FakeCompleter(["Hello", "Help"])
        let out = await WordSuggester.completions(
            prefix: "Hel", previous: ["ich"], snapshot: snapshot, pairs: model, completer: completer, languages: ["de", "en"], now: t0)
        #expect(out == ["Helmholtz", "helfe", "Hello"])
        #expect(completer.calls.first?.languages == ["de", "en"])
        #expect(completer.calls.first?.prefix == "Hel")
    }

    @Test func theCheckerIsSkippedWhenVocabularyAndPairsFillTheSlots() async {
        let snapshot = VocabularySnapshot(entries: [entry("Helmholtz"), entry("Helios")])
        let model = pairs(["ich helfe"])
        let completer = FakeCompleter(["Hello"])
        let out = await WordSuggester.completions(
            prefix: "hel", previous: ["ich"], snapshot: snapshot, pairs: model, completer: completer, languages: ["en"], now: t0)
        #expect(out.count == 3)
        #expect(completer.calls.isEmpty)
    }

    @Test func vocabularyRanksPinnedThenByDecayedScore() async {
        let snapshot = VocabularySnapshot(entries: [
            entry("Helix", score: 5), entry("Helga", score: 1, pinned: true), entry("Helene", score: 2),
        ])
        let out = await WordSuggester.completions(
            prefix: "Hel", previous: [], snapshot: snapshot, pairs: nil, completer: nil, languages: [], now: t0)
        #expect(out == ["Helga", "Helix", "Helene"])
    }

    @Test func blockedAliasAndMultiWordEntriesAreDropped() async {
        let snapshot = VocabularySnapshot(entries: [
            entry("Helmut", blocked: true),
            entry("Helo"),  // a mishearing of Hello
            entry("Hello", aliases: ["Helo"]),
            entry("Hello World"),
            entry("Haus"),
        ])
        let out = await WordSuggester.completions(
            prefix: "He", previous: [], snapshot: snapshot, pairs: nil, completer: nil, languages: [], now: t0)
        #expect(out == ["Hello"])
    }

    @Test func dedupesCaseInsensitivelyAcrossSources() async {
        let snapshot = VocabularySnapshot(entries: [entry("Hello")])
        let model = pairs(["ich hello"])
        let completer = FakeCompleter(["hello", "HELLO", "Help"])
        let out = await WordSuggester.completions(
            prefix: "Hel", previous: ["ich"], snapshot: snapshot, pairs: model, completer: completer, languages: ["en"], now: t0)
        #expect(out == ["Hello", "Help"])
    }

    @Test func neverReturnsThePrefixItself() async {
        let snapshot = VocabularySnapshot(entries: [entry("Hel")])
        let model = pairs(["ich hel"])
        let completer = FakeCompleter(["Hel", "Hello"])
        let out = await WordSuggester.completions(
            prefix: "Hel", previous: ["ich"], snapshot: snapshot, pairs: model, completer: completer, languages: ["en"], now: t0)
        #expect(out == ["Hello"])
    }

    @Test func theLimitIsThree() async {
        let completer = FakeCompleter(["Hello", "Help", "Helm", "Hell", "Helix"])
        let out = await WordSuggester.completions(
            prefix: "Hel", previous: [], snapshot: nil, pairs: nil, completer: completer, languages: ["en"], now: t0)
        #expect(out == ["Hello", "Help", "Helm"])
    }

    @Test func pairHitsNeedAPreviousWordAndTheRightPrefix() async {
        let model = pairs(["ich liebe", "ich laufe"])
        let none = await WordSuggester.completions(
            prefix: "li", previous: [], snapshot: nil, pairs: model, completer: nil, languages: [], now: t0)
        #expect(none == [])
        let hit = await WordSuggester.completions(
            prefix: "li", previous: ["ich"], snapshot: nil, pairs: model, completer: nil, languages: [], now: t0)
        #expect(hit == ["liebe"])
    }

    @Test func emptyPrefixOrNoSourcesGiveNothing() async {
        let completer = FakeCompleter(["Hello"])
        let empty = await WordSuggester.completions(
            prefix: "", previous: ["ich"], snapshot: VocabularySnapshot(entries: [entry("Hello")]), pairs: nil,
            completer: completer, languages: ["en"], now: t0)
        #expect(empty == [])
        #expect(completer.calls.isEmpty)
        let nothing = await WordSuggester.completions(
            prefix: "He", previous: [], snapshot: nil, pairs: nil, completer: nil, languages: [], now: t0)
        #expect(nothing == [])
    }

    @Test func predictionsComeFromThePairModel() {
        let model = pairs(["ich liebe", "ich liebe", "ich laufe", "ich bin", "ich habe"])
        #expect(WordSuggester.predictions(previous: ["ich"], pairs: model, now: t0).count == 3)
        #expect(WordSuggester.predictions(previous: ["ich"], pairs: model, limit: 1, now: t0) == ["liebe"])
        #expect(WordSuggester.predictions(previous: ["ich"], pairs: nil, now: t0) == [])
        #expect(WordSuggester.predictions(previous: [], pairs: model, now: t0) == [])
    }

    @Test func interleaveAlternatesLanguagesAndDropsDuplicates() {
        #expect(PlatformSpellChecker.interleave([["Haus", "Hand"], ["House", "Hand", "Hat"]]) == ["Haus", "House", "Hand", "Hat"])
        #expect(PlatformSpellChecker.interleave([]) == [])
        #expect(PlatformSpellChecker.interleave([[], ["a"]]) == ["a"])
    }
}
