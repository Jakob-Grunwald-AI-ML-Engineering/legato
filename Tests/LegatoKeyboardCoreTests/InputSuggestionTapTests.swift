import Testing
@testable import LegatoKeyboardCore

@Suite("Suggestion tap identity")
struct InputSuggestionTapTests {
    private let tap = SuggestionTap(rank: 0, word: "the", revision: 7, documentID: "field-a", before: "type teh", after: "")

    @Test func accessibilityAfterACanceledPressUsesTheCurrentlyAnnouncedProposal() {
        var press = SuggestionPress()
        press.began(tap)
        // A dragged-out Button does not invoke its action. A later row announces a new proposal.
        let announced = SuggestionTap(rank: 0, word: "then", revision: 8, documentID: "field-a", before: "type the", after: "")
        let activated = press.activate(current: announced, accessibility: true)
        #expect(activated?.matches(revision: 8, words: ["then"], documentID: "field-a", before: "type the", after: "") == true)
        #expect(press.activate(current: announced) == nil)
    }

    @Test func ordinaryTouchCannotInheritANewerProposal() {
        var press = SuggestionPress()
        press.began(tap)
        let newer = SuggestionTap(rank: 0, word: "then", revision: 8, documentID: "field-a", before: "type the", after: "")
        let activated = press.activate(current: newer)
        #expect(activated == tap)
        #expect(activated?.matches(revision: 8, words: ["then"], documentID: "field-a", before: "type the", after: "") == false)
        #expect(press.activate(current: newer) == nil)
    }

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
