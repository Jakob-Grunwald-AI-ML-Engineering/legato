import Testing
@testable import LegatoKeyboardCore

@Suite struct InputWordSpanExpansionTests {
    private func tapped(_ before: String, _ after: String) -> WordAtCursor {
        WordAtCursor.find(contextBefore: before, contextAfter: after)!
    }

    private func span(_ before: String, _ after: String, left: Int, right: Int) -> WordSpan {
        WordSpanExpansion.span(contextBefore: before, contextAfter: after, tapped: tapped(before, after), left: left, right: right)
    }

    @Test func noExpansionKeepsTheTappedWordsOwnSpan() {
        #expect(span("I use kub", "er netties", left: 0, right: 0) == WordSpan(before: 3, after: 2))
    }

    @Test func oneWordToTheRightCoversTheSpaceAndTheNextWord() {
        // "kuber" ends at the cursor; " netties" is 8 characters.
        #expect(span("I use kuber", " netties daily", left: 0, right: 1) == WordSpan(before: 5, after: 8))
    }

    @Test func oneWordToTheLeftCoversThePreviousWordAndTheSpace() {
        // "kuber netties" is 13 characters before the cursor.
        #expect(span("I use kuber netties", " daily", left: 1, right: 0) == WordSpan(before: 13, after: 0))
    }

    @Test func bothSidesTogetherAndTheCursorInsideTheWord() {
        #expect(span("a b ne", "tties c d", left: 1, right: 1) == WordSpan(before: 4, after: 7))
    }

    @Test func expansionStopsAtPunctuation() {
        #expect(span("Hello, kuber", ", netties", left: 1, right: 1) == WordSpan(before: 5, after: 0))
    }

    @Test func expansionStopsAtANewline() {
        #expect(span("one\nkuber", "\nnetties", left: 1, right: 1) == WordSpan(before: 5, after: 0))
    }

    @Test func expansionStopsAtTheEdgesOfTheContext() {
        #expect(span("kuber", " netties", left: 2, right: 2) == WordSpan(before: 5, after: 8))
    }

    @Test func expansionTakesAsManyWordsAsThereAreUpToTheRequestedCount() {
        #expect(span("x one", " two three four", left: 0, right: 2) == WordSpan(before: 3, after: 10))
    }
}
