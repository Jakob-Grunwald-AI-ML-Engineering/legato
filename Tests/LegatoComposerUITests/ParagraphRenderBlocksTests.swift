import Testing
import LegatoComposerDoc
@testable import LegatoComposerUI

struct ParagraphRenderBlocksTests {
    @Test func hugeCanonicalParagraphUsesBoundedNativeTextBlocksWithoutLosingWords() {
        let words = (0..<5_000).map { Word(id: "w\($0)", text: "token\($0)") }
        let line = Line(id: "canonical", words: words)
        let paragraphs = ParagraphPresentation.reconcile(previous: [], lines: [line])
        let blocks = ParagraphRenderBlocks.make(paragraphs, previous: [])
        #expect(blocks.count == 53)
        #expect(blocks.allSatisfy { $0.line.words.count <= ParagraphRenderBlocks.maximumWords })
        #expect(blocks.flatMap(\.line.words) == words)
        #expect(Set(blocks.map(\.line.id)) == [line.id])
        #expect(Set(blocks.map(\.id)).count == blocks.count)
        #expect(blocks[0].id == paragraphs[0].id)
        #expect(blocks.filter { !$0.continuation }.count == 1)
        // One paragraph-wide budget, rather than 32 independently animated words in every block.
        #expect(Set(blocks.flatMap { $0.edit.ranks.keys }).count == WordEditPresentation.maximumAnimatedWords)
    }
    @Test func quoteAcrossVisualBlocksStillUsesOneCanonicalParagraph() {
        let words = (0..<210).map { Word(id: "w\($0)", text: "token\($0)") }
        let line = Line(id: "canonical", kind: .oli, words: words)
        let blocks = ParagraphRenderBlocks.make(ParagraphPresentation.reconcile(previous: [], lines: [line]), previous: [])
        let selection = QuoteSelection(lineID: line.id, wordID: words[94].id, endWordID: words[99].id)
        #expect(selection.wordIDs(in: .init(revision: 1, lines: [line])) == Set(words[94...99].map(\.id)))
        #expect(blocks[0].line.words.contains { $0.id == words[94].id })
        #expect(blocks[1].line.words.contains { $0.id == words[99].id })
        #expect(blocks.map(\.ordinal) == [1, 1, 1])
        #expect(blocks.map(\.continuation) == [false, true, true])
    }
    @Test func localSpellingEditKeepsBlockIdentityAndAnimatesOnlyItsWord() {
        let words = (0..<200).map { Word(id: "w\($0)", text: "token\($0)") }
        let before = ParagraphPresentation.reconcile(previous: [], lines: [Line(id: "p", words: words)])
        var edited = words; edited[110] = Word(id: "fixed", text: "corrected")
        let after = ParagraphPresentation.reconcile(previous: before, lines: [Line(id: "p", version: 1, words: edited)])
        let oldBlocks = ParagraphRenderBlocks.make(before, previous: [])
        let newBlocks = ParagraphRenderBlocks.make(after, previous: before)
        #expect(oldBlocks.map(\.id) == newBlocks.map(\.id))
        #expect(newBlocks.allSatisfy { $0.edit.ranks == ["fixed": 0] })
        #expect(newBlocks[1].line.words[14].id == "fixed")
    }
}
