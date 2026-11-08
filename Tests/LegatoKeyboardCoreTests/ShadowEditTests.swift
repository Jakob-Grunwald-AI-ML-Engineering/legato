import Testing
@testable import LegatoKeyboardCore

private func run(_ shadow: String, cursor: Int? = nil, _ target: String) -> (plan: ShadowPlan, text: String, cursor: Int) {
    let c = cursor ?? shadow.utf16.count
    let plan = ShadowEditPlanner.plan(shadow: shadow, cursor: c, target: target)
    let result = ShadowEditPlanner.simulate(ops: plan.ops, shadow: shadow, cursor: c)
    return (plan, result.text, result.cursor)
}

@Suite struct ShadowEditTests {
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
