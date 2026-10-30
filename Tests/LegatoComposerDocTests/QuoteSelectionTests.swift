import Testing
@testable import LegatoComposerDoc

@Test func quoteSelectionNormalizesDirectionAndKeepsObservedLineBoundaries() throws {
    let snapshot = DocumentSnapshot(revision: 8, lines: [
        Line(id: "a", version: 2, words: [Word(id: "a0", text: "Hello"), Word(id: "a1", text: "Morgan")]),
        Line(id: "b", version: 4, words: [Word(id: "b0", text: "Tuesday"), Word(id: "b1", text: "afternoon"), Word(id: "b2", text: "works")])])
    let selection = try #require(QuoteSelection(lineID: "b", wordID: "b1", endLineID: "a", endWordID: "a1").resolved(in: snapshot))
    #expect(selection.lineID == "a")
    #expect(selection.wordID == "a1")
    #expect(selection.endLineID == "b")
    #expect(selection.endWordID == "b1")
    #expect(selection.quote(in: snapshot) == "Morgan\nTuesday afternoon")
    #expect(selection.wordIDs(in: snapshot) == ["a1", "b0", "b1"])
    #expect(selection.lines(in: snapshot).map(\.version) == [2, 4])
    #expect(QuoteSelection(lineID: "a", wordID: "missing").resolved(in: snapshot) == nil)
    let word = QuoteSelection(lineID: "a", wordID: "a0")
    #expect(word.quote(in: snapshot) == "Hello")
    #expect(word.isSingleWord)
}
