import Testing
@testable import LegatoKeyboardCore

@Suite("Suggestion tap identity")
struct InputSuggestionTapTests {
    private let tap = SuggestionTap(rank: 0, word: "the", revision: 7, documentID: "field-a", before: "type teh", after: "")

    @Test func requiresTheSameRowAndFieldRevision() {
        #expect(tap.matches(revision: 7, words: ["the"], documentID: "field-a", before: "type teh", after: ""))
        #expect(!tap.matches(revision: 8, words: ["the"], documentID: "field-a", before: "type teh", after: ""))
        #expect(!tap.matches(revision: 7, words: ["them"], documentID: "field-a", before: "type teh", after: ""))
        #expect(!tap.matches(revision: 7, words: ["the"], documentID: "field-b", before: "type teh", after: ""))
        #expect(!tap.matches(revision: 7, words: ["the"], documentID: "field-a", before: "other teh", after: ""))
        #expect(!tap.matches(revision: 7, words: ["the"], documentID: "field-a", before: "type teh", after: " text"))
        #expect(!tap.matches(revision: 7, words: [], documentID: "field-a", before: "type teh", after: ""))
    }
}
