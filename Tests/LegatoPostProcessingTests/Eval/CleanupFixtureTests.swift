import Foundation
import Testing
@testable import LegatoPostProcessing

@Suite("CleanupFixtures")
struct CleanupFixtureTests {
    private let all = Result { try CleanupSplit.allCases.flatMap { try CleanupFixtures.load($0) } }
    private func fixtures(_ split: CleanupSplit) throws -> [CleanupFixture] { try CleanupFixtures.load(split) }

    @Test func thereAreAtLeastThirtyFixturesSplitAboutTwoToOne() throws {
        let dev = try fixtures(.dev)
        let heldout = try fixtures(.heldout)
        #expect(dev.count + heldout.count >= 30)
        let devShare = Double(dev.count) / Double(dev.count + heldout.count)
        #expect(abs(devShare - 2.0 / 3.0) < 0.05)
    }

    @Test func theOriginalFiveFixturesAreHeldOut() throws {
        let names = Set(try fixtures(.heldout).map(\.name))
        for name in ["punctuation-casing-en", "spelled-number-de", "misrecognition-en", "spelling-de", "long-de"] {
            #expect(names.contains(name), "missing original fixture \(name)")
        }
    }

    @Test func namesAreUniqueAcrossSplits() throws {
        let names = try all.get().map(\.name)
        #expect(Set(names).count == names.count)
    }

    @Test func eachSplitMixesLanguagesAndLengths() throws {
        for split in CleanupSplit.allCases {
            let list = try fixtures(split)
            for language in ["de", "en", "mixed"] {
                #expect(list.contains { $0.language == language }, "\(split): no \(language)")
            }
            for length in ["short", "long"] {
                #expect(list.contains { $0.length == length }, "\(split): no \(length)")
            }
        }
    }

    @Test func theSplitsAreStratifiedByLanguageAndLength() throws {
        let dev = try fixtures(.dev)
        let heldout = try fixtures(.heldout)
        for language in ["de", "en"] {
            for length in ["short", "long"] {
                let d = dev.filter { $0.language == language && $0.length == length }.count
                let h = heldout.filter { $0.language == language && $0.length == length }.count
                #expect(d > h, "\(language)/\(length): dev \(d) should outnumber heldout \(h)")
                #expect(h >= 1, "\(language)/\(length): heldout has none")
            }
        }
    }

    @Test func aboutHalfTheFixturesAreGermanAndHalfEnglishWithAFewMixed() throws {
        let list = try all.get()
        let de = list.filter { $0.language == "de" }.count
        let en = list.filter { $0.language == "en" }.count
        let mixed = list.filter { $0.language == "mixed" }.count
        #expect(abs(de - en) <= 3)
        #expect(mixed >= 3 && mixed <= list.count / 5)
    }

    @Test func theLanguageFieldAgreesWithTheLocale() throws {
        for fixture in try all.get() where fixture.language != "mixed" {
            #expect(fixture.locale.hasPrefix(fixture.language), "\(fixture.name)")
        }
    }

    @Test func shortFixturesHaveAtMostThreeSentencesAndLongOnesAtLeastFive() throws {
        for fixture in try all.get() {
            let sentences = CleanupGuard.sentenceCount(fixture.reference)
            if fixture.length == "long" {
                #expect(sentences >= 5, "\(fixture.name) has \(sentences) sentences")
            } else {
                #expect(sentences <= 3, "\(fixture.name) has \(sentences) sentences")
            }
        }
    }

    @Test func theReferenceMeetsItsOwnRequirements() throws {
        for fixture in try all.get() {
            let score = CleanupScorer.score(
                output: fixture.reference, input: fixture.input, fixture: fixture, rejectedChunks: 0)
            #expect(score.violations.isEmpty, "\(fixture.name): reference holds \(score.violations)")
            #expect(score.mustContainHits == score.mustContainTotal, "\(fixture.name): reference misses a required term")
            #expect(score.guardAccepted, "\(fixture.name): the guard rejects the reference")
            #expect(score.editDistance <= score.referenceTokens, "\(fixture.name)")
        }
    }

    @Test func doingNothingFailsEveryFixture() throws {
        for fixture in try all.get() {
            let score = CleanupScorer.score(output: fixture.input, input: fixture.input, fixture: fixture, rejectedChunks: 0)
            #expect(!score.passed, "\(fixture.name): the untouched input passes")
        }
    }

    @Test func everyVocabularyTermIsUsedInTheReference() throws {
        for fixture in try all.get() {
            for term in fixture.vocabulary {
                #expect(fixture.reference.contains(term), "\(fixture.name): \(term)")
            }
        }
    }

    @Test func theInputsLookLikeRawRecognizerOutput() throws {
        for fixture in try all.get() {
            // No digits: numbers are spelled out.
            #expect(!fixture.input.contains { $0.isNumber }, "\(fixture.name) has digits")
            // Lowercase throughout, as the recognizer writes names and nouns.
            #expect(fixture.input == fixture.input.lowercased(), "\(fixture.name) has capitals")
        }
    }
}
