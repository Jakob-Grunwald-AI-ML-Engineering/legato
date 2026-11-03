import Testing
import LegatoComposerDoc
@testable import LegatoComposerUI

struct EditPresentationTests {
    @Test func typoOnlyAnimatesChangedWordAndRetainsAllNeighbours() {
        let old = [Word(id: "a", text: "Keep"), Word(id: "b", text: "ths"), Word(id: "c", text: "sentence")]
        let new = [old[0], Word(id: "fixed", text: "this"), old[2]]
        let plan = WordEditPresentation(old: old, new: new)
        #expect(plan.ranks == ["fixed": 0])
        #expect(plan.deletionBoundary.isEmpty)
        #expect(plan.progress(for: "a", overall: 0) == 1)
        #expect(plan.progress(for: "c", overall: 0.5) == 1)
        #expect(plan.progress(for: "fixed", overall: 0) == 0)
        #expect(plan.progress(for: "fixed", overall: 1) == 1)
        #expect(new.map(\.text).joined(separator: " ") == "Keep this sentence")
    }

    @Test func deletionPulsesOnlyOneSurvivingBoundary() {
        let old = [Word(id: "a", text: "Keep"), Word(id: "b", text: "really"), Word(id: "c", text: "this")]
        let plan = WordEditPresentation(old: old, new: [old[0], old[2]])
        #expect(plan.ranks.isEmpty)
        #expect(plan.deletionBoundary == ["c"])
    }

    @Test func replacementStaggersOnlyBoundedWordsAndNeverChangesCanonicalText() {
        let words = (0..<5_000).map { Word(id: "w\($0)", text: "token\($0)") }
        let plan = WordEditPresentation(old: [], new: words)
        #expect(plan.ranks.count == WordEditPresentation.maximumAnimatedWords)
        #expect(plan.progress(for: "w0", overall: 0.2) > plan.progress(for: "w12", overall: 0.2))
        #expect(plan.progress(for: "w4999", overall: 0) == 1)
        #expect(plan.ranks.keys.allSatisfy { plan.progress(for: $0, overall: 1) == 1 })
        #expect(words.count == 5_000)
    }

    @Test func paragraphReplacementFollowsWordIdentityAndPreservesCanonicalSelectionIDs() {
        let a = Line(id: "old-a", words: [Word(id: "a", text: "First")])
        let b = Line(id: "old-b", words: [Word(id: "b", text: "Second")])
        let initial = ParagraphPresentation.reconcile(previous: [], lines: [a, b])
        let replacement = Line(id: "new-b", words: [b.words[0], Word(text: "edited")])
        let inserted = Line(id: "inserted", words: [Word(text: "New")])
        let next = ParagraphPresentation.reconcile(previous: initial, lines: [inserted, replacement, a])
        #expect(next.map(\.id) == ["inserted", "old-b", "old-a"])
        #expect(next[1].line == replacement)
        let selection = QuoteSelection(lineID: replacement.id, wordID: "b")
        #expect(selection.wordIDs(in: .init(revision: 2, lines: next.map(\.line))) == ["b"])
    }

    @Test func completeRewriteReusesPositionButEmptyBoundaryStartsFresh() {
        let a = Line(id: "old", words: [Word(text: "Before")])
        let b = Line(id: "new", words: [Word(text: "After")])
        let initial = ParagraphPresentation.reconcile(previous: [], lines: [a])
        #expect(ParagraphPresentation.reconcile(previous: initial, lines: [b]).first?.id == "old")
        let cleared = ParagraphPresentation.reconcile(previous: initial, lines: [])
        #expect(ParagraphPresentation.reconcile(previous: cleared, lines: [b]).first?.id == "new")
        let inserted = ParagraphPresentation.reconcile(previous: cleared, lines: [b], animateInsertions: true)
        #expect(inserted[0].animateInsertion)
        #expect(ParagraphPresentation.reconcile(previous: inserted, lines: [b])[0].animateInsertion)
    }

    @Test func reusedRevisionOverDifferentLinesDropsStalePresentation() {
        let old = Line(id: "L1", words: [Word(id: "w1", text: "Old")])
        let fresh = Line(id: "L9", words: [Word(id: "w9", text: "Fresh")])
        let presented = ParagraphPresentation.reconcile(previous: [], lines: [old])
        func previous(_ rev: Int, presentedRevision: Int = 4, lines: [Line]) -> [PresentedParagraph] {
            ParagraphPresentation.previous(presented: presented, presentedRevision: presentedRevision, snapshot: .init(revision: rev, lines: lines))
        }
        #expect(previous(4, lines: [fresh]).isEmpty)          // same revision, other lines (restarted document)
        #expect(previous(3, lines: [old]).isEmpty)            // lower revision
        #expect(previous(4, lines: [old]) == presented)       // same revision, same lines
        #expect(previous(5, lines: [fresh]) == presented)     // a normal advance reconciles against what is shown
    }

    @Test func presentationIDsStayUniqueWhenALineReusesAnInheritedID() {
        let a = Line(id: "old-b", words: [Word(id: "b", text: "Second")])
        let initial = ParagraphPresentation.reconcile(previous: [], lines: [Line(id: "x", words: a.words)])
        let renamed = ParagraphPresentation.reconcile(previous: initial, lines: [Line(id: "y", words: a.words)])
        #expect(renamed[0].id == "x")
        // Another line now owns the ID "x" while the first keeps its inherited "x".
        let next = ParagraphPresentation.reconcile(previous: renamed, lines: [Line(id: "z", words: a.words), Line(id: "x", words: [Word(text: "Other")])])
        #expect(Set(next.map(\.id)).count == 2)
        #expect(next[0].id == "x")
    }
}
