import Testing
@testable import LegatoKeyboardCore

@Suite struct LinkDictationLocatorTests {
    private func word(_ before: String, _ after: String) -> WordAtCursor {
        WordAtCursor.find(contextBefore: before, contextAfter: after)!
    }

    private func located(_ texts: [String], _ before: String, _ after: String, preferred: Int? = nil) -> (Int, String)? {
        guard let hit = DictationLocator.locate(
            texts: texts, contextBefore: before, contextAfter: after, word: word(before, after), preferred: preferred)
        else { return nil }
        let chars = Array(texts[hit.version])
        return (hit.version, String(chars[hit.start..<hit.start + hit.length]))
    }

    private let raw = "ich nutze kuber netties jeden tag"
    private let cleaned = "Ich nutze Kubernetes jeden Tag."

    @Test func findsTheVersionThatSitsInTheFieldAndTheWordInIt() {
        let hit = located([raw, cleaned], "Hallo. ich nutze kuber", " netties jeden tag")
        #expect(hit?.0 == 0)
        #expect(hit?.1 == "kuber")
    }

    @Test func findsTheCleanedVersionWhenThatIsWhatTheFieldHolds() {
        let hit = located([raw, cleaned], "Ich nutze Kubernetes jeden", " Tag.")
        #expect(hit?.0 == 1)
        #expect(hit?.1 == "jeden")
    }

    @Test func aWordElsewhereInTheFieldIsNotFoundInTheDictation() {
        #expect(located([raw, cleaned], "Notes: hello wor", "ld and more") == nil)
    }

    @Test func theShownVersionWinsATie() {
        let texts = ["we go home", "we go home"]
        #expect(located(texts, "we go ho", "me", preferred: 1)?.0 == 1)
        #expect(located(texts, "we go ho", "me", preferred: 0)?.0 == 0)
    }

    @Test func aWordNextToEditedTextIsStillFoundByItsCloserNeighbours() {
        // The user changed the start of the sentence; the words around the tap are as dictated.
        let hit = located([raw], "Xyz abc nutze kuber", " netties jeden tag")
        #expect(hit?.1 == "kuber")
    }

    @Test func theSameWordTwiceIsToldApartByItsNeighbours() {
        let texts = ["der hund und der hund"]
        let hit = DictationLocator.locate(
            texts: texts, contextBefore: "der hund und der hu", contextAfter: "nd", word: word("der hund und der hu", "nd"))
        #expect(hit?.start == 17)
    }
}
