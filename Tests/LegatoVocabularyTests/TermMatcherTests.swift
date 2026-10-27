import Foundation
import Testing
@testable import LegatoVocabulary

@Suite("TermMatcher")
struct TermMatcherTests {
    /// A matcher over one term; the term's id is returned for the match assertions.
    func matcher(_ text: String, spellings: [String] = [], aliases: [String] = [], extra: [String] = [])
        -> (TermMatcher, UUID)
    {
        let term = TermMatcher.Term(text: text, spellings: spellings, aliases: aliases)
        let others = extra.map { TermMatcher.Term(text: $0) }
        return (TermMatcher(terms: [term] + others), term.id)
    }

    struct Row: Sendable, CustomTestStringConvertible {
        var said: String
        var term: String
        var range: Range<Int>
        var testDescription: String { "\(said) -> \(term)" }
    }

    // MARK: must match

    @Test(arguments: [
        Row(said: "kloud", term: "Claude", range: 0..<1),
        Row(said: "Grunwald", term: "Grünwald", range: 0..<1),
        Row(said: "Grünwald", term: "Grunwald", range: 0..<1),
        Row(said: "Gruenwald", term: "Grünwald", range: 0..<1),
        Row(said: "kuber netties", term: "Kubernetes", range: 0..<2),
        Row(said: "Mueller", term: "Müller", range: 0..<1),
        Row(said: "Meier", term: "Maier", range: 0..<1),
        Row(said: "Schmitt", term: "Schmidt", range: 0..<1),
    ])
    func matchesNearMisses(_ row: Row) {
        let (m, id) = matcher(row.term)
        let found = m.candidates(for: row.said)
        #expect(found.first?.termID == id)
        #expect(found.first?.range == row.range)
        let hits = m.hits(in: row.said)
        #expect(hits.map(\.termID) == [id])
    }

    @Test func findsASpanInsideASentenceWithItsWordRange() {
        let (m, id) = matcher("Kubernetes")
        let hits = m.hits(in: "we deploy it on kuber netties every day")
        #expect(hits.count == 1)
        #expect(hits.first?.termID == id)
        #expect(hits.first?.range == 4..<6)
    }

    @Test func aliasesAndSpellingsMatchToo() {
        let (m, id) = matcher("Claude", spellings: ["Claud Code"], aliases: ["cloud code"])
        #expect(m.hits(in: "ask cloud code about it").first?.termID == id)
        #expect(m.hits(in: "ask cloud code about it").first?.range == 1..<3)
        #expect(m.hits(in: "ask Claud Code").first?.termID == id)
    }

    @Test func anExactOccurrenceScoresOne() {
        let (m, id) = matcher("Claude")
        let hit = m.hits(in: "Claude is here").first
        #expect(hit?.termID == id)
        #expect(hit?.score == 1)
    }

    @Test func cleanupTermsListsTheHitTermsBestFirst() {
        let claude = TermMatcher.Term(text: "Claude")
        let kube = TermMatcher.Term(text: "Kubernetes")
        let unrelated = TermMatcher.Term(text: "Zeppelin")
        let m = TermMatcher(terms: [unrelated, kube, claude])
        let ids = m.cleanupTerms(for: "kloud runs on kuber netties, Kubernetes really")
        #expect(Set(ids) == [claude.id, kube.id])
        #expect(ids.first == kube.id)  // the exact hit outranks the fuzzy ones
        #expect(m.cleanupTerms(for: "nothing relevant here").isEmpty)
    }

    @Test func candidatesAreRankedAndLimited() {
        let terms = ["Claude", "Claus", "Clawd", "Kubernetes"].map { TermMatcher.Term(text: $0) }
        let m = TermMatcher(terms: terms)
        let found = m.candidates(for: "Claud", limit: 2)
        #expect(found.count == 2)
        #expect(found.allSatisfy { $0.score > 0 && $0.score <= 1 })
        #expect(found[0].termID == terms[0].id)  // the sound-alike with the closest spelling comes first
        #expect(found[0].score > found[1].score)
        #expect(!found.contains { $0.termID == terms[3].id })
    }

    // MARK: must not match

    @Test(arguments: [
        Row(said: "Maya", term: "EMEA", range: 0..<1),
        Row(said: "the", term: "thee", range: 0..<1),
        Row(said: "thee", term: "the", range: 0..<1),
        Row(said: "und", term: "Uwe", range: 0..<1),
        Row(said: "cat", term: "Kat", range: 0..<1),
        // length-ratio misses: sound similar, but one side is far shorter
        Row(said: "Claus", term: "Claude Monet", range: 0..<1),
        Row(said: "Kube", term: "Kubernetes", range: 0..<1),
        Row(said: "international", term: "Intel", range: 0..<1),
        // short joined spans: "in a" is not the name Ina, "is a" is not Isa
        Row(said: "in a", term: "Ina", range: 0..<2),
        Row(said: "is a", term: "Isa", range: 0..<2),
        Row(said: "an dre as", term: "Andreas", range: 0..<3),
    ])
    func doesNotMatch(_ row: Row) {
        let (m, _) = matcher(row.term)
        #expect(m.candidates(for: row.said).isEmpty)
        #expect(m.hits(in: row.said).isEmpty)
    }

    @Test func aMultiWordTermStillMatchesAShortSpan() {
        let (m, id) = matcher("IT AG")
        #expect(m.hits(in: "it ag").map(\.termID) == [id])
        #expect(m.candidates(for: "it ag").first?.termID == id)
    }

    @Test func aLongEnoughSpanOfWordsOfThreeLettersMatchesASingleWordTerm() {
        let (m, id) = matcher("Kubernetes")
        #expect(m.hits(in: "we use kuber netties").first?.range == 2..<4)
        #expect(m.hits(in: "we use kuber netties").first?.termID == id)
    }

    @Test func aTermListBeyondOneHundredGetsStricter() {
        let filler = (0..<120).map { "Filler\($0)x" }
        // One letter off (similarity 0.83) and not a sound-alike: enough on a short list, below 0.85 on a long one.
        let (smallA, andrea) = matcher("Andrea")
        let (bigA, _) = matcher("Andrea", extra: filler)
        #expect(smallA.candidates(for: "Andres").first?.termID == andrea)
        #expect(bigA.candidates(for: "Andres").isEmpty)
        // Sounds alike in Kölner only (387 both, Metaphone FXR vs FSR): a long list wants both keys to agree.
        let (smallF, fisher) = matcher("Fisher")
        let (bigF, _) = matcher("Fisher", extra: filler)
        #expect(smallF.candidates(for: "Visser").first?.termID == fisher)
        #expect(bigF.candidates(for: "Visser").isEmpty)
        // Both keys agree: still found on a long list.
        let (bigC, claude) = matcher("Claude", extra: filler)
        #expect(bigC.candidates(for: "kloud").first?.termID == claude)
    }
}
