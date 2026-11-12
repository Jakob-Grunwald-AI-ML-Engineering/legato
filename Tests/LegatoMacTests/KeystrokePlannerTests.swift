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

    @Test func aReplacementNeverLeavesItsLineEmpty() {
        // A rich editor puts a placeholder into a line that becomes empty: the first old letter stays until the new
        // text is typed before it.
        for (old, new) in [("Sailing To Noon", "SAILING TO NOON"), ("ab\nhi", "ab\nHO"), ("x", "y")] {
            let steps = KeystrokePlanner.steps(from: Array(old), to: Array(new))
            var text = Array(old)
            for step in steps {
                text = step.after
                let lines = String(text).split(separator: "\n", omittingEmptySubsequences: false)
                #expect(lines.allSatisfy { !$0.isEmpty }, "\(old) → \(new) passed through \(String(text).debugDescription)")
            }
            #expect(String(text) == new)
        }
        // Inside a line nothing changes: "colour" → "color" is still one Backspace.
        #expect(KeystrokePlanner.steps(from: Array("a colour b"), to: Array("a color b")).count == 1)
    }

    @Test func nearbyChangesMergeAndTheCheaperModeWins() {
        let spans = KeystrokePlanner.spans(from: Array("a-b-c-d"), to: Array("x-y-z-w"))
        #expect(spans.count == 1)
        // Far-apart one-letter fixes stay minimal: two short edits, no retyping of the words between them.
        let far = KeystrokePlanner.spans(from: Array("cab and then some more words dog"), to: Array("cat and then some more words dot"))
        #expect(far.count == 2 && far.allSatisfy { !$0.block })
    }

    @Test func thePaceSpreadsAChangeOverTheBudgetWithinItsBounds() {
        // Small changes at the calm pace (25 to 35 ms), never slower.
        #expect(KeystrokePlanner.paceMs(ops: 4) == KeystrokePlanner.calmMs)
        #expect((25.0...35.0).contains(KeystrokePlanner.calmMs))
        // A middling change spreads over the budget, between the floor and the calm pace.
        let middling = KeystrokePlanner.paceMs(ops: KeystrokePlanner.behindOps - 1)
        #expect(middling >= KeystrokePlanner.floorMs && middling <= KeystrokePlanner.calmMs)
    }

    @Test func fallingBehindSpeechGoesStraightToTheFloor() {
        // Speech is about 15 characters a second (67 ms each): a backlog of behindOps goes at the floor, which is at
        // least 30 characters a second, and a field written by Accessibility goes at its own, lower floor.
        #expect(KeystrokePlanner.paceMs(ops: KeystrokePlanner.behindOps) == KeystrokePlanner.floorMs)
        #expect(KeystrokePlanner.paceMs(ops: 1_000) == KeystrokePlanner.floorMs)
        #expect(1_000 / KeystrokePlanner.floorMs >= 30)
        #expect(KeystrokePlanner.paceMs(ops: 1_000, floor: KeystrokePlanner.writeFloorMs) == KeystrokePlanner.writeFloorMs)
        #expect(KeystrokePlanner.writeFloorMs <= KeystrokePlanner.floorMs)
        // The pace never gets slower as the backlog grows.
        let paces = (1...60).map { KeystrokePlanner.paceMs(ops: $0) }
        #expect(zip(paces, paces.dropFirst()).allSatisfy { $0 >= $1 })
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
