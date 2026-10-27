import Testing
@testable import LegatoKeyboardCore

@Suite struct InputWordContextTests {
    @Test func theWordBeforeThePartialWordIsThePreviousWord() {
        #expect(WordContext.previousWord(beforePrefixIn: "I am goi") == "am")
    }

    @Test func aTrailingSpaceMeansNoPartialWordAndTheLastWordIsPrevious() {
        #expect(WordContext.previousWord(beforePrefixIn: "I am ") == "am")
    }

    @Test func punctuationBreaksTheChain() {
        #expect(WordContext.previousWord(beforePrefixIn: "Hello, wor") == nil)
        #expect(WordContext.previousWord(beforePrefixIn: "Hello. ") == nil)
    }

    @Test func aNewlineBreaksTheChain() {
        #expect(WordContext.previousWord(beforePrefixIn: "Hello\nwor") == nil)
    }

    @Test func theFirstWordHasNoPreviousWord() {
        #expect(WordContext.previousWord(beforePrefixIn: "Hel") == nil)
        #expect(WordContext.previousWord(beforePrefixIn: "") == nil)
    }

    @Test func umlautsAndApostrophesCountAsLetters() {
        #expect(WordContext.previousWord(beforePrefixIn: "wir fahren über Brü") == "über")
        #expect(WordContext.previousWord(beforePrefixIn: "I don't kn") == "don't")
    }
}
