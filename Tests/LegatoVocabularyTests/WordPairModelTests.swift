import Foundation
import Testing
@testable import LegatoVocabulary

/// A letters-only unique word for index `i` ("wa", "wb", … "waaa").
func uniqueWord(_ i: Int) -> String {
    var n = i
    var s = ""
    repeat {
        s = String(UnicodeScalar(UInt8(97 + n % 26))) + s
        n /= 26
    } while n > 0
    return "w" + String(repeating: "a", count: max(0, 3 - s.count)) + s
}

@Suite("WordPairModel")
struct WordPairModelTests {
    let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    let day: TimeInterval = 24 * 60 * 60

    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("legato-pairs-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("pairs.json")
    }

    // MARK: tokenization

    @Test func pairsStayWithinASentence() {
        var model = WordPairModel()
        model.observe(text: "Das ist schön. Müller fährt Auto.", at: t0)
        #expect(model.predict(after: ["Das"], now: t0) == ["ist"])
        #expect(model.predict(after: ["ist"], now: t0) == ["schön"])
        #expect(model.predict(after: ["schön"], now: t0) == [])
        #expect(model.predict(after: ["Müller"], now: t0) == ["fährt"])
        #expect(model.predict(after: ["fährt"], now: t0) == ["Auto"])
    }

    @Test func keysFoldCaseAndPunctuationButKeepTheDisplayForm() {
        var model = WordPairModel()
        model.observe(text: "Ich liebe Berlin", at: t0)
        #expect(model.predict(after: ["LIEBE"], now: t0) == ["Berlin"])
        #expect(model.predict(after: ["liebe,"], now: t0) == ["Berlin"])
        #expect(model.predict(after: ["Ich", "liebe"], now: t0) == ["Berlin"])
    }

    @Test func englishContractionsAndUmlautsAreSingleWords() {
        var model = WordPairModel()
        model.observe(text: "We don't know. Über Straßen gehen wir.", at: t0)
        #expect(model.predict(after: ["we"], now: t0) == ["don't"])
        #expect(model.predict(after: ["über"], now: t0) == ["Straßen"])
    }

    @Test func numbersAndPunctuationAreNotWords() {
        var model = WordPairModel()
        model.observe(text: "Es kostet 42 Euro - wirklich!", at: t0)
        #expect(model.predict(after: ["kostet"], now: t0) == [])
        #expect(model.predict(after: ["42"], now: t0) == [])
    }

    @Test func emptyOrUnknownPreviousPredictsNothing() {
        var model = WordPairModel()
        model.observe(text: "ich liebe Berlin", at: t0)
        #expect(model.predict(after: [], now: t0) == [])
        #expect(model.predict(after: ["nie"], now: t0) == [])
        #expect(model.predict(after: ["ich"], limit: 0, now: t0) == [])
    }

    // MARK: ranking, predict, complete

    @Test func predictRanksByWeightAndHonoursTheLimit() {
        var model = WordPairModel()
        for _ in 0..<2 { model.observe(text: "ich liebe", at: t0) }
        for _ in 0..<4 { model.observe(text: "ich bin", at: t0) }
        for _ in 0..<3 { model.observe(text: "ich laufe", at: t0) }
        model.observe(text: "ich habe", at: t0)
        #expect(model.predict(after: ["ich"], limit: 3, now: t0) == ["bin", "laufe", "liebe"])
        #expect(model.predict(after: ["ich"], limit: 1, now: t0) == ["bin"])
    }

    @Test func completeReturnsOnlyNextWordsWithThePrefix() {
        var model = WordPairModel()
        model.observe(text: "ich liebe", at: t0)
        for _ in 0..<2 { model.observe(text: "ich laufe", at: t0) }
        model.observe(text: "ich bin", at: t0)
        #expect(model.complete(prefix: "l", after: ["ich"], now: t0) == ["laufe", "liebe"])
        #expect(model.complete(prefix: "L", after: ["ich"], now: t0) == ["laufe", "liebe"])
        #expect(model.complete(prefix: "li", after: ["ich"], now: t0) == ["liebe"])
        #expect(model.complete(prefix: "x", after: ["ich"], now: t0) == [])
        #expect(model.complete(prefix: "l", after: [], now: t0) == [])
    }

    // MARK: decay

    @Test func oldPairsFadeBelowFreshOnes() {
        var model = WordPairModel()
        model.observe(text: "ein Haus", at: t0)
        model.observe(text: "ein Haus", at: t0)
        let later = t0.addingTimeInterval(60 * day)
        model.observe(text: "ein Auto", at: later)
        #expect(model.predict(after: ["ein"], now: t0) == ["Haus", "Auto"])
        #expect(model.predict(after: ["ein"], now: later) == ["Auto", "Haus"])
    }

    @Test func weightDecaysWithTheSharedHalfLife() throws {
        var model = WordPairModel()
        model.observe(text: "ein Haus", at: t0)
        model.observe(text: "ein Haus", at: t0)
        let w = try #require(model.weight(of: "haus", after: "ein", now: t0.addingTimeInterval(Decay.defaultHalfLife)))
        #expect(abs(w - 1) < 1e-9)
    }

    @Test func reobservingAddsToTheDecayedWeight() throws {
        var model = WordPairModel()
        model.observe(text: "ein Haus", at: t0)
        let later = t0.addingTimeInterval(Decay.defaultHalfLife)
        model.observe(text: "ein Haus", at: later)
        let w = try #require(model.weight(of: "haus", after: "ein", now: later))
        #expect(abs(w - 1.5) < 1e-9)
    }

    // MARK: caps and prune

    @Test func eachPreviousWordKeepsTheEightHeaviestNextWords() {
        var model = WordPairModel()
        for i in 1...10 {
            for _ in 0..<i { model.observe(text: "ich \(uniqueWord(i))", at: t0) }
        }
        let out = model.predict(after: ["ich"], limit: 20, now: t0)
        #expect(out.count == WordPairModel.maxNext)
        #expect(out == (3...10).reversed().map(uniqueWord))
    }

    @Test func atMostFourThousandPreviousWordsLowestWeightGoesFirst() {
        var model = WordPairModel()
        let later = t0.addingTimeInterval(1)
        for i in 0..<100 { model.observe(text: "\(uniqueWord(i)) zielwort", at: t0) }
        for i in 100..<4_100 {
            model.observe(text: "\(uniqueWord(i)) zielwort", at: later)
            model.observe(text: "\(uniqueWord(i)) zielwort", at: later)
        }
        model.prune(now: later)
        #expect(model.previousWordCount == WordPairModel.maxPrevious)
        #expect(model.predict(after: [uniqueWord(0)], now: later) == [])
        #expect(model.predict(after: [uniqueWord(99)], now: later) == [])
        #expect(model.predict(after: [uniqueWord(100)], now: later) == ["zielwort"])
        #expect(model.predict(after: [uniqueWord(4_099)], now: later) == ["zielwort"])
    }

    @Test func pruneDropsDecayedPairsToTheCaps() {
        var model = WordPairModel()
        for i in 0..<(WordPairModel.maxPrevious + 50) { model.observe(text: "\(uniqueWord(i)) ziel", at: t0) }
        #expect(model.previousWordCount > WordPairModel.maxPrevious)
        model.prune(now: t0.addingTimeInterval(day))
        #expect(model.previousWordCount <= WordPairModel.maxPrevious)
    }

    @Test func pruneDropsPairsThatDecayedAway() {
        var model = WordPairModel()
        model.observe(text: "ein Haus", at: t0)
        model.prune(now: t0.addingTimeInterval(Decay.defaultHalfLife * 10))
        #expect(model.previousWordCount == 0)
    }

    // MARK: merge

    @Test func mergedSumsWeightsUnionsLanguagesAndLeavesTheInputsAlone() throws {
        var dictated = WordPairModel(languages: ["de"])
        dictated.observe(text: "ich liebe", at: t0)
        dictated.observe(text: "ich liebe", at: t0)
        dictated.observe(text: "ich bin", at: t0)
        var typed = WordPairModel(languages: ["en", "de"])
        typed.observe(text: "ich liebe", at: t0)
        typed.observe(text: "ich laufe", at: t0)
        typed.observe(text: "ich laufe", at: t0)

        let merged = dictated.merged(with: typed, now: t0)
        #expect(merged.languages == ["de", "en"])
        #expect(merged.predict(after: ["ich"], now: t0) == ["liebe", "laufe", "bin"])
        #expect(try #require(merged.weight(of: "liebe", after: "ich", now: t0)) == 3)
        #expect(dictated.predict(after: ["ich"], now: t0) == ["liebe", "bin"])
        #expect(typed.predict(after: ["ich"], now: t0) == ["laufe", "liebe"])
    }

    @Test func mergedWithAnEmptyModelIsTheModel() {
        var model = WordPairModel()
        model.observe(text: "ich liebe", at: t0)
        #expect(model.merged(with: WordPairModel(), now: t0).predict(after: ["ich"], now: t0) == ["liebe"])
        #expect(WordPairModel().merged(with: model, now: t0).predict(after: ["ich"], now: t0) == ["liebe"])
    }

    @Test func mergedRespectsTheCaps() {
        var a = WordPairModel()
        var b = WordPairModel()
        for i in 0..<5 {
            a.observe(text: "ich \(uniqueWord(i))", at: t0)
            b.observe(text: "ich \(uniqueWord(i + 5))", at: t0)
        }
        #expect(a.merged(with: b, now: t0).predict(after: ["ich"], limit: 20, now: t0).count == WordPairModel.maxNext)
    }

    // MARK: persistence

    @Test func readIsNilForAMissingOrBrokenOrForeignVersionFile() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        #expect(WordPairModel.read(from: url) == nil)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("nope".utf8).write(to: url)
        #expect(WordPairModel.read(from: url) == nil)
        try Data(#"{"version":99,"languages":[],"pairs":{}}"#.utf8).write(to: url)
        #expect(WordPairModel.read(from: url) == nil)
    }

    @Test func encodeDecodeRoundTripsWithWholeMilliseconds() throws {
        var model = WordPairModel(languages: ["de", "en"])
        model.observe(text: "Müller fährt Auto", at: t0)
        let decoded = try #require(WordPairModel.decode(try WordPairModel.encode(model)))
        #expect(decoded == model)
    }
}
