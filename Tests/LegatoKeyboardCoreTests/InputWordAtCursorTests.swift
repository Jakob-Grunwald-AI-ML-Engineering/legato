import Testing
@testable import LegatoKeyboardCore

@Suite struct InputWordAtCursorTests {
    private func find(_ before: String, _ after: String, selection: Bool = false) -> WordAtCursor? {
        WordAtCursor.find(contextBefore: before, contextAfter: after, hasSelection: selection)
    }

    @Test func aCursorInsideAWordFindsItAndCountsBothSides() {
        let w = find("Das ist ein Hau", "s hier")
        #expect(w?.word == "Haus")
        #expect(w?.charsBefore == 3)
        #expect(w?.charsAfter == 1)
        #expect(w?.span == WordSpan(before: 3, after: 1))
    }

    @Test func aCursorAtTheEndOfAWordTouchesIt() {
        let w = find("hello wor", " rest")
        #expect(w?.word == "wor")
        #expect(w?.charsAfter == 0)
    }

    @Test func aCursorAtTheStartOfAWordTouchesIt() {
        let w = find("hello ", "world")
        #expect(w?.word == "world")
        #expect(w?.charsBefore == 0)
    }

    @Test func betweenTwoSpacesThereIsNoWord() {
        #expect(find("hello ", " world") == nil)
    }

    @Test func afterPunctuationThereIsNoWord() {
        #expect(find("Hello, ", "") == nil)
        #expect(find("Hello!", "") == nil)
        #expect(find("", "") == nil)
    }

    @Test func apostrophesInsideAWordBelongToIt() {
        #expect(find("I don'", "t go")?.word == "don't")
        #expect(find("wie geht’", "s dir")?.word == "geht’s")
    }

    @Test func quotingApostrophesAtTheEdgesAreNotPartOfTheWord() {
        let w = find("say 'hel", "lo' now")
        #expect(w?.word == "hello")
        #expect(w?.charsBefore == 3)
        #expect(w?.charsAfter == 2)
        #expect(find("say '", "hello'")?.word == "hello")
        #expect(find("say ", "'hello'") == nil)
    }

    @Test func umlautsAndEszettAreLetters() {
        let w = find("Die Straß", "e ist groß")
        #expect(w?.word == "Straße")
        #expect(find("schö", "n")?.word == "schön")
    }

    @Test func anEmojiEndsAWordAndCountsAsOneCharacter() {
        let w = find("ok 👍hel", "lo👨‍👩‍👧 x")
        #expect(w?.word == "hello")
        #expect(w?.charsBefore == 3)
        #expect(w?.charsAfter == 2)
        #expect(find("ok 👍", "") == nil)
        #expect(find("a", "👍")?.word == "a")
    }

    @Test func combiningMarksStayInsideTheirCharacter() {
        // "e" + combining acute is one Character.
        let w = find("cafe\u{301}", " au lait")
        #expect(w?.charsBefore == 4)
    }

    @Test func digitsCountAsWordCharacters() {
        #expect(find("room 12", "3 b")?.word == "123")
    }

    @Test func aHyphenSeparatesWords() {
        #expect(find("well-kn", "own")?.word == "known")
    }

    @Test func aSelectionFindsNothing() {
        #expect(find("hel", "lo", selection: true) == nil)
    }
}
