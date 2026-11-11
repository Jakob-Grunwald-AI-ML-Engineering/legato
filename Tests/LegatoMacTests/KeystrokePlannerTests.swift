import Foundation
import Testing
@testable import LegatoMac

@Suite struct KeystrokePlannerTests {
    private func run(_ old: String, _ new: String) -> [KeystrokePlanner.Step] {
        KeystrokePlanner.steps(from: Array(old), to: Array(new))
    }

    @Test func stepsChainAndEndAtTheNewText() {
        for (old, new) in [("the cab is here", "the cat is here"), ("Thursday at noon", "Friday at noon"),
                           ("sail north", "Sail north."), ("ab⛵️cd", "a⛵️c d"), ("", "hello"), ("gone", "")] {
            let steps = run(old, new)
            var text = Array(old)
            for step in steps { #expect(step.before == text); text = step.after }
            #expect(String(text) == new)
        }
    }

    @Test func aWordThatChangesMostlyIsRetypedWhole() {
        // "Thursday" → "Friday": the whole word goes and comes back, not a few letters in the middle of it.
        let steps = run("on Thursday", "on Friday")
        #expect(steps.filter { $0.key == .backspace }.count == 8)
        #expect(steps.compactMap { if case .type(let c) = $0.key { c } else { nil } } == Array("Friday"))
        // "colour" → "color" stays one deleted letter.
        #expect(run("colour", "color").map(\.key) == [.backspace])
    }

    @Test func nearbyChangesMergeAndTheCheaperModeWins() {
        let spans = KeystrokePlanner.spans(from: Array("a-b-c-d"), to: Array("x-y-z-w"))
        #expect(spans.count == 1)
        // Far-apart one-letter fixes stay minimal: two short edits, no retyping of the words between them.
        let far = KeystrokePlanner.spans(from: Array("cab and then some more words dog"), to: Array("cat and then some more words dot"))
        #expect(far.count == 2 && far.allSatisfy { !$0.block })
    }

    @Test func thePaceSpreadsAChangeOverTheBudgetWithinItsBounds() {
        #expect(KeystrokePlanner.paceMs(ops: 4) == KeystrokePlanner.calmMs)
        #expect(KeystrokePlanner.paceMs(ops: 40) == KeystrokePlanner.budgetMs / 40)
        #expect(KeystrokePlanner.paceMs(ops: 1_000) == KeystrokePlanner.floorMs)
    }

    @Test func syntheticSequencesArePairedAndNeverReturnOrTab() {
        #expect(SyntheticEvent.isBalanced([(0x7B, true), (0x7B, false)]))
        #expect(SyntheticEvent.isBalanced([(0x37, true), (9, true), (9, false), (0x37, false)]))
        #expect(!SyntheticEvent.isBalanced([(0x37, true), (9, true), (9, false)]))
        #expect(!SyntheticEvent.isBalanced([(9, false)]))
        #expect(!SyntheticEvent.isBalanced([(0x24, true), (0x24, false)]))
        #expect(!SyntheticEvent.isBalanced([(0x30, true), (0x30, false)]))
        #expect(SyntheticEvent.typeable("é") && SyntheticEvent.typeable("⛵️"))
        #expect(!SyntheticEvent.typeable("\n") && !SyntheticEvent.typeable("\t") && !SyntheticEvent.typeable(""))
    }
}
