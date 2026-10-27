import Foundation
import Testing
@testable import LegatoVocabulary

private func context(_ text: String, tapping word: String) -> AlternativeContext {
    AlternativeContext(sentence: text, wordRange: text.range(of: word)!, languages: ["de"])
}

@Suite("VersionWordsSource")
struct VersionWordsSourceTests {
    @Test func offersTheOtherVersionsWordAtTheTap() async {
        let texts = ["kloud code ist gut", "Claude Code ist gut"]
        let source = VersionWordsSource(texts: texts, shown: 1, wordIndex: 0)
        let out = await source.candidates(for: "Claude", context: context(texts[1], tapping: "Claude"))
        #expect(out.map(\.text) == ["kloud"])
        #expect(out.first?.source == .engine)
    }

    @Test func aWordAllVersionsShareHasNoAlternative() async {
        let texts = ["kloud code ist gut", "Claude Code ist gut"]
        let source = VersionWordsSource(texts: texts, shown: 1, wordIndex: 2)
        #expect(await source.candidates(for: "ist", context: context(texts[1], tapping: "ist")) == [])
    }

    @Test func aPureInsertionHasNoCounterpart() async {
        let texts = ["Claude Code ist gut", "Claude Code ist sehr gut"]
        let source = VersionWordsSource(texts: texts, shown: 1, wordIndex: 3)
        #expect(await source.candidates(for: "sehr", context: context(texts[1], tapping: "sehr")) == [])
    }

    @Test func aMultiWordSpanIsOfferedWhole() async {
        let texts = ["kuber netties läuft", "Kubernetes läuft"]
        let fromCleaned = VersionWordsSource(texts: texts, shown: 1, wordIndex: 0)
        let a = await fromCleaned.candidates(for: "Kubernetes", context: context(texts[1], tapping: "Kubernetes"))
        #expect(a.map(\.text) == ["kuber netties"])
        let fromRaw = VersionWordsSource(texts: texts, shown: 0, wordIndex: 1)
        let b = await fromRaw.candidates(for: "netties", context: context(texts[0], tapping: "netties"))
        #expect(b.map(\.text) == ["Kubernetes"])
    }

    @Test func dictatedTextRanksFirstThroughWordAlternatives() async {
        let texts = ["kloud Code", "Cloud Code", "Claude Code"]
        let source = VersionWordsSource(texts: texts, shown: 2, wordIndex: 0)
        let ctx = context(texts[2], tapping: "Claude")
        let ranked = await WordAlternatives.rank(word: "Claude", context: ctx, sources: [source])
        #expect(ranked.map(\.text) == ["kloud", "Cloud"])
        #expect(ranked.allSatisfy { $0.source == .engine })
    }

    @Test func punctuationAtTheEdgesIsTrimmed() async {
        let texts = ["das ist kloud, oder?", "Das ist Claude, oder?"]
        let source = VersionWordsSource(texts: texts, shown: 1, wordIndex: 2)
        let out = await source.candidates(for: "Claude", context: context(texts[1], tapping: "Claude"))
        #expect(out.map(\.text) == ["kloud"])
    }

    @Test func outOfRangeInputsGiveNothing() async {
        let texts = ["a b", "a c"]
        let ctx = context("a c", tapping: "c")
        #expect(await VersionWordsSource(texts: texts, shown: 5, wordIndex: 1).candidates(for: "c", context: ctx) == [])
        #expect(await VersionWordsSource(texts: texts, shown: 1, wordIndex: 9).candidates(for: "c", context: ctx) == [])
        #expect(await VersionWordsSource(texts: [], shown: 0, wordIndex: 0).candidates(for: "c", context: ctx) == [])
        #expect(await VersionWordsSource(texts: ["a c"], shown: 0, wordIndex: 1).candidates(for: "c", context: ctx) == [])
    }

    // MARK: window cap

    @Test func theWindowIsAtMostFortyTokensAndClampedToTheText() {
        #expect(VersionWordsSource.window(around: 1_000, count: 2_000) == 980..<1_020)
        #expect(VersionWordsSource.window(around: 0, count: 2_000) == 0..<40)
        #expect(VersionWordsSource.window(around: 1_999, count: 2_000) == 1_960..<2_000)
        #expect(VersionWordsSource.window(around: 3, count: 10) == 0..<10)
        #expect(VersionWordsSource.window(around: 0, count: 0).isEmpty)
        #expect(VersionWordsSource.windowSize == 40)
    }

    @Test func aTwoThousandWordTextAlignsWithinTheWindowDespiteDrift() async {
        let words = (0..<2_000).map(uniqueWord)
        var raw = words
        raw[1_500] = "kloud"
        // The cleaned text lost every 23rd word before the tap, so the positions drift by 60.
        var cleaned: [String] = []
        for (i, w) in words.enumerated() where !(i < 1_400 && i % 23 == 5) { cleaned.append(i == 1_500 ? "Claude" : w) }
        let tap = cleaned.firstIndex(of: "Claude")!
        #expect(tap < 1_500 - 55)
        let rawText = raw.joined(separator: " ")
        let cleanedText = cleaned.joined(separator: " ")
        let source = VersionWordsSource(texts: [rawText, cleanedText], shown: 1, wordIndex: tap)
        let ctx = AlternativeContext(sentence: cleanedText, wordRange: cleanedText.range(of: "Claude")!, languages: [])
        let out = await source.candidates(for: "Claude", context: ctx)
        #expect(out.map(\.text) == ["kloud"])
        let aligned = VersionWordsSource.align(
            tapped: VersionWordsSource.tokenize(cleanedText), index: tap, other: VersionWordsSource.tokenize(rawText))
        #expect(aligned.words == ["kloud"])
        #expect(aligned.cells > 0)
        #expect(aligned.cells <= VersionWordsSource.windowSize * VersionWordsSource.windowSize * 2)
    }

    @Test func tokenIndexCountsTokensTheWayTheSourceDoes() {
        let text = "  Das ist, - ein Test!"
        let range = text.range(of: "Test")!
        #expect(VersionWordsSource.tokenIndex(of: range, in: text) == 3)
        #expect(VersionWordsSource.tokens(in: text) == ["Das", "ist", "ein", "Test"])
        #expect(VersionWordsSource.tokenIndex(of: text.range(of: "ist")!, in: text) == 1)
    }
}
