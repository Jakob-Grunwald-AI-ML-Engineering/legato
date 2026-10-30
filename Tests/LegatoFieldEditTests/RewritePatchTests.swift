import Foundation
import Testing
@testable import LegatoFieldEdit

/// A rewritten sentence becomes the smallest word-level patches against the recognized text.
struct RewritePatchTests {
    private func applied(_ steps: [EditStep], to text: String) -> String {
        var out = text
        for step in steps.sorted(by: { $0.span.location > $1.span.location }) { out = step.apply(to: out)! }
        return out
    }

    @Test func aMisheardWordIsOnePatchOfJustThatWord() {
        let steps = RewritePatch.steps("I can't decide weather to go.", "I can't decide whether to go.", at: 0)
        #expect(steps == [EditStep(span: Span(location: 16, length: 2), text: "he", expect: "ea")])
    }

    @Test func separateChangesAreSeparateStepsAndLeaveTheRestAlone() {
        let old = "um we fly to paris on monday."
        let new = "We fly to Paris on Monday."
        let steps = RewritePatch.steps(old, new, at: 10)
        #expect(steps.count == 3)
        #expect(steps.allSatisfy { $0.span.location >= 10 })
        // Non-overlapping, in order, all against the same base.
        for (a, b) in zip(steps, steps.dropFirst()) { #expect(a.span.end <= b.span.location) }
        let field = String(repeating: "x", count: 10) + old
        #expect(applied(steps, to: field) == String(repeating: "x", count: 10) + new)
    }

    /// A rewrite that touches every word of a stretch (case, filler, punctuation) still lands as find-and-replace
    /// sized steps, never the whole stretch written again.
    @Test func neighbouringChangesStayFindAndReplaceSized() {
        let old = "hi um testing if this is working okay okay it seems to work"
        let new = "Hi, testing if this is working. Okay, it seems to work."
        let steps = RewritePatch.steps(old, new, at: 0)
        #expect(applied(steps, to: old) == new)
        #expect(steps.count >= 4)
        #expect(steps.allSatisfy { $0.expect.utf16.count <= 8 && $0.text.utf16.count <= 8 })
    }

    @Test func aRecasedWordIsOneLetter() {
        let steps = RewritePatch.steps("we fly to paris.", "We fly to Paris.", at: 0)
        #expect(steps == [
            EditStep(span: Span(location: 0, length: 1), text: "W", expect: "w"),
            EditStep(span: Span(location: 10, length: 1), text: "P", expect: "p"),
        ])
    }

    @Test func anIdenticalRewriteIsNoStep() {
        #expect(RewritePatch.steps("The ferry leaves at noon.", "The ferry leaves at noon.", at: 3).isEmpty)
    }

    @Test func whitespaceOnlyDifferencesAreNoStep() {
        #expect(RewritePatch.steps("One  two three.", "One two three.", at: 0).isEmpty)
    }

    @Test func insertionsAndDeletionsKeepTheSpacing() {
        let cases: [(String, String)] = [
            ("I think the the plan works.", "I think the plan works."),
            ("Book a table for six, no wait, seven people.", "Book a table for seven people."),
            ("I saw it", "I saw it."),
            ("the room costs one hundred twenty euros", "The room costs 120 euros."),
            ("hello world", "Well, hello world"),
            ("a b c", "c"),
            ("a b c", "x a b c y"),
        ]
        for (old, new) in cases {
            #expect(applied(RewritePatch.steps(old, new, at: 0), to: old) == new, "\(old) -> \(new)")
        }
    }

    @Test func utf16OffsetsCountEmojiAndAccents() {
        let old = "😀 Café teh 👍 dog."
        let new = "😀 Café the 👍 dog."
        let steps = RewritePatch.steps(old, new, at: 0)
        #expect(steps.count == 1)
        #expect(applied(steps, to: old) == new)
        #expect(steps.first?.span.location == "😀 Café t".utf16.count)
    }

    @Test func aRewriteWithLineBreaksBringsThemIn() {
        let old = "bullet point buy milk bullet point call anna."
        let new = "- Buy milk\n- Call Anna."
        #expect(applied(RewritePatch.steps(old, new, at: 0), to: old) == new)
    }

    @Test func hunksMapEveryChangeToItsRegions() {
        let hunks = RewritePatch.hunks("a b c d", "a x c d e")
        #expect(hunks.count == 2)
        // Each region runs between the unchanged words around it: " b " -> " x ", then "" -> " e" at the end.
        #expect(hunks[0].old == 1..<4 && hunks[0].new == 1..<4)
        #expect(hunks[1].old == 7..<7 && hunks[1].new == 7..<9)
    }
}
