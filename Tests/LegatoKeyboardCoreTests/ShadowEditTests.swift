import Testing
@testable import LegatoKeyboardCore

private func run(_ shadow: String, cursor: Int? = nil, _ target: String) -> (plan: ShadowPlan, text: String, cursor: Int) {
    let c = cursor ?? shadow.utf16.count
    let plan = ShadowEditPlanner.plan(shadow: shadow, cursor: c, target: target)
    let result = ShadowEditPlanner.simulate(ops: plan.ops, shadow: shadow, cursor: c)
    return (plan, result.text, result.cursor)
}

@Suite struct ShadowEditTests {
    @Test func aCharacterFlipDeletesAndInsertsOnlyTheCharactersThatDiffer() {
        let shadow = "the whether is nice"
        let plan = ShadowEditPlanner.plan(shadow: shadow, cursor: shadow.utf16.count, target: "the weather is nice", characters: true)
        // "whether" to "weather": "h" goes, "a" comes in; the cursor returns to the end.
        #expect(plan.ops == [.move(-12), .insert("a"), .move(-2), .deleteBackward(1), .move(14)])
        let result = ShadowEditPlanner.simulate(ops: plan.ops, shadow: shadow, cursor: shadow.utf16.count)
        #expect(result.text == "the weather is nice" && result.cursor == result.text.utf16.count && plan.cursor == result.cursor)
    }

    @Test func aCharacterFlipCountsUTF16AroundEmojiAndInsertsOneCharacterPerOp() {
        let shadow = "😀 Hallo wrld 👨‍👩‍👧 tschüss"
        let target = "😀 Hallo wörld 👨‍👩‍👧 tschüß"
        let plan = ShadowEditPlanner.plan(shadow: shadow, cursor: shadow.utf16.count, target: target, characters: true)
        let result = ShadowEditPlanner.simulate(ops: plan.ops, shadow: shadow, cursor: shadow.utf16.count)
        #expect(result.text == target && result.cursor == target.utf16.count)
        let inserts = plan.ops.compactMap { if case .insert(let text) = $0 { text } else { nil } }
        let deleted = plan.ops.reduce(0) { if case .deleteBackward(let n) = $1 { $0 + n } else { $0 } }
        #expect(inserts == ["ß", "ö"] && deleted == 2, "\"ss\" becomes \"ß\", \"ö\" goes in")
        // From the end back to "w|rld": the emoji family is 8 UTF-16 units but one character, and the move counts units.
        #expect(plan.ops.first == .deleteBackward(2) && plan.ops.contains(.move(-19)))
    }

    @Test func aCharacterFlipTwoWordsBackLeavesTheWordsAfterItAlone() {
        let shadow = "we met their yesterday and"
        let plan = ShadowEditPlanner.plan(shadow: shadow, cursor: shadow.utf16.count, target: "we met there yesterday and", characters: true)
        #expect(plan.ops == [.move(-14), .insert("e"), .move(-2), .deleteBackward(1), .move(16)])
        let result = ShadowEditPlanner.simulate(ops: plan.ops, shadow: shadow, cursor: shadow.utf16.count)
        #expect(result.text == "we met there yesterday and")
    }

    @Test func flipsAWordInTheMiddleAndKeepsTheCursorAtTheEnd() {
        let s = "I think there going to the station. Then coffee."
        let t = "I think they're going to the station. Then coffee."
        let r = run(s, t)
        #expect(r.text == t)
        #expect(r.cursor == t.utf16.count)
        #expect(r.plan.cursor == t.utf16.count)
    }

    @Test func insertsRemovesAndChangesPunctuationInOnePlan() {
        let s = "Hello world, this is a test. Another one here"
        let t = "Hello big world. This is test! Another one here."
        let r = run(s, cursor: 5, t)
        #expect(r.text == t)
        #expect(r.cursor == r.plan.cursor)
        #expect(r.cursor == 5)
    }

    @Test func cursorInsideAReplacedWordLandsAfterIt() {
        let s = "one two three"
        let r = run(s, cursor: 6, "one 2 three") // inside "two"
        #expect(r.text == "one 2 three")
        #expect(r.cursor == 5)
    }

    @Test func identicalTextPlansNothing() {
        #expect(run("same text.", "same text.").plan.ops.isEmpty)
    }

    @Test func countsUTF16ForTheMoveAndCharactersForTheDelete() {
        let s = "caf\u{e9} \u{1F600} ok \u{1F44D}\u{1F3FD} end"
        let t = "caf\u{e9} \u{1F600} okay \u{1F44D}\u{1F3FD} end"
        let r = run(s, t)
        #expect(r.text == t)
        #expect(r.cursor == t.utf16.count)
        #expect(r.plan.ops.contains(.move(-(" \u{1F44D}\u{1F3FD} end".utf16.count))))
    }

    @Test func editsToTheEndAndTheStartRoundTrip() {
        let r = run("", cursor: 0, "Hi there")
        #expect(r.text == "Hi there")
        #expect(r.cursor == 8)
        let r2 = run("alpha beta", cursor: 0, "beta")
        #expect(r2.text == "beta")
        #expect(r2.cursor == 0)
    }
}
