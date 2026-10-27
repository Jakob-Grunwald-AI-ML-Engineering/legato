import Testing
@testable import LegatoKeyboardCore

@Suite struct InputWordEditTests {
    @Test func replacingASpanMovesPastTheRestDeletesBackAndInserts() {
        let edit = WordEdit.replace(span: WordSpan(before: 3, after: 1), with: "Hauses")
        #expect(edit == WordEdit(forward: 1, deleteCount: 4, insert: "Hauses"))
    }

    @Test func replacingAMultiWordSpanDeletesAllOfIt() {
        // "ein Hau|s hier": three words around the cursor.
        let edit = WordEdit.replace(span: WordSpan(before: 12, after: 9), with: "a b c")
        #expect(edit.forward == 9)
        #expect(edit.deleteCount == 21)
        #expect(edit.insert == "a b c")
    }

    @Test func replacingDoesNotAddASpace() {
        #expect(WordEdit.replace(span: WordSpan(before: 2, after: 0), with: "ab").insert == "ab")
    }

    @Test func completingReplacesThePrefixAndAddsATrailingSpace() {
        let edit = WordEdit.complete(prefix: "hel", with: "hello")
        #expect(edit == WordEdit(forward: 0, deleteCount: 3, insert: "hello "))
    }

    @Test func aCapitalisedPrefixCapitalisesALowercaseCandidate() {
        #expect(WordEdit.complete(prefix: "Hel", with: "hello").insert == "Hello ")
        #expect(WordEdit.complete(prefix: "H", with: "hello").insert == "Hello ")
    }

    @Test func anAllCapsPrefixUppercasesALowercaseCandidate() {
        #expect(WordEdit.complete(prefix: "HEL", with: "hello").insert == "HELLO ")
    }

    @Test func aLowercasePrefixKeepsTheCandidateAsIs() {
        #expect(WordEdit.complete(prefix: "hel", with: "Hello").insert == "Hello ")
        #expect(WordEdit.complete(prefix: "hel", with: "hello").insert == "hello ")
    }

    @Test func aCandidateWithItsOwnCapitalsIsNotRecased() {
        #expect(WordEdit.complete(prefix: "HEL", with: "HelloWorld").insert == "HelloWorld ")
        #expect(WordEdit.complete(prefix: "ip", with: "iPhone").insert == "iPhone ")
    }

    @Test func caseMatchingWorksWithUmlautsAndEszett() {
        #expect(WordEdit.complete(prefix: "Üb", with: "über").insert == "Über ")
        #expect(WordEdit.complete(prefix: "STR", with: "straße").insert == "STRASSE ")
    }

    @Test func deleteCountIsInCharactersNotScalars() {
        #expect(WordEdit.complete(prefix: "cafe\u{301}", with: "cafés").deleteCount == 4)
    }

    @Test func replaceCanMatchTheCaseOfWhatWasThere() {
        let edit = WordEdit.replace(span: WordSpan(before: 3, after: 0), with: "wand", matchingCaseOf: "Win")
        #expect(edit.insert == "Wand")
    }

    // MARK: a completion tapped after the field moved on

    @Test func aCompletionIsRefusedWhenTheWordHasGrownSinceTheRowWasBuilt() {
        // The row offered "hello" for "hel"; a key made it "hell" before the tap landed.
        #expect(WordEdit.complete(prefix: "hel", with: "hello", contextBefore: "say hell") == nil)
    }

    @Test func aCompletionIsRefusedWhenTheWordHasShrunkSinceTheRowWasBuilt() {
        #expect(WordEdit.complete(prefix: "hel", with: "hello", contextBefore: "say he") == nil)
    }

    @Test func aCompletionOfTheCurrentPrefixIsTheUsualEdit() {
        #expect(
            WordEdit.complete(prefix: "hel", with: "hello", contextBefore: "say hel")
                == WordEdit(forward: 0, deleteCount: 3, insert: "hello "))
    }

    @Test func aPredictionNeedsAnEmptyPrefix() {
        #expect(WordEdit.complete(prefix: "", with: "world", contextBefore: "hello ") == WordEdit(forward: 0, deleteCount: 0, insert: "world "))
        #expect(WordEdit.complete(prefix: "", with: "world", contextBefore: "hello w") == nil)
    }

    // MARK: the proxy counts UTF-16 units

    @Test func theForwardMoveIsCountedInUTF16UnitsOfTheCharactersItCrosses() {
        let edit = WordEdit(forward: 2, deleteCount: 5, insert: "x")
        #expect(edit.utf16Forward(contextAfter: "😀é rest") == 3, "😀 is two units, é (precomposed) one")
        #expect(WordEdit(forward: 0, deleteCount: 1, insert: "").utf16Forward(contextAfter: "😀") == 0)
    }

    @Test func aCombinedEmojiCountsAsOneCharacterButManyUnits() {
        let family = "👨‍👩‍👧"
        #expect(WordEdit(forward: 1, deleteCount: 0, insert: "").utf16Forward(contextAfter: family + "a") == family.utf16.count)
    }

    @Test func aForwardMoveBeyondTheKnownTextCountsWhatIsThere() {
        #expect(WordEdit(forward: 5, deleteCount: 0, insert: "").utf16Forward(contextAfter: "😀") == 2)
    }
}
