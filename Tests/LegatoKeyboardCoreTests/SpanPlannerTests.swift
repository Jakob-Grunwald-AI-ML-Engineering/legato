import Testing
@testable import LegatoKeyboardCore

@Suite struct SpanPlannerTests {
    private func spans(_ old: String, _ new: String) -> [SpanPlanner.Span] {
        SpanPlanner.spans(from: Array(old), to: Array(new), moveSettleMs: FieldQueue.moveSettleMs, editSettleMs: FieldQueue.editSettleMs)
    }

    /// Applies the spans back to front as the queue does.
    private func apply(_ spans: [SpanPlanner.Span], to old: String) -> String {
        var text = Array(old)
        for span in spans.reversed() {
            let hunks = span.block ? [SpanPlanner.Hunk(start: span.start, end: span.end, text: span.text)] : span.hunks
            for h in hunks.reversed() { text.replaceSubrange(h.start..<h.end, with: h.text) }
        }
        return String(text)
    }

    @Test func aSmallChangeInsideAWordStaysCharacterLevel() {
        let result = spans("the colour is red", "the color is red")
        #expect(result.count == 1)
        #expect(!result[0].block)
        #expect(result[0].hunks == [.init(start: 8, end: 9, text: [])])
    }

    @Test func aWordChangedMostlyIsReplacedWhole() {
        let result = spans("see you on Thursday at noon", "see you on Friday at noon")
        #expect(result.count == 1)
        #expect(result[0].hunks == [.init(start: 11, end: 19, text: Array("Friday"))])
    }

    @Test func twoNearbyFixesAreOneSpan() {
        let old = "I has a apple today", new = "I have an apple today"
        let result = spans(old, new)
        #expect(result.count == 1)
        #expect(result[0].start == 2 && result[0].end == 7)
        #expect(apply(result, to: old) == new)
    }

    @Test func farApartFixesAreSeparateSpans() {
        let old = "the colour of the sky over the harbour", new = "the color of the sky over the harbor"
        #expect(spans(old, new).count == 2)
        #expect(apply(spans(old, new), to: old) == new)
    }

    @Test func uppercasingASentenceIsOneBlockDeleteAndEveryGraphemeTyped() {
        let old = "the meeting is at three pm tomorrow, we need the slides"
        #expect(old.count == 55)
        let result = spans(old, old.uppercased())
        #expect(result.count == 1)
        #expect(result[0].block)
        #expect(result[0].start == 0 && result[0].end == 55)
        #expect(result[0].text == Array(old.uppercased()))
    }

    @Test func insertingAWordDoesNotRetypeItsNeighbour() {
        let result = spans("a b", "a new b")
        #expect(apply(result, to: "a b") == "a new b")
        #expect(result.allSatisfy { $0.hunks.allSatisfy { $0.start == $0.end } }, "nothing deleted")
    }

    @Test func aTailAppendIsLeftToTheTypewriter() {
        let old = Array("we need slides fr"), new = Array("we need slides for the meeting")
        let result = SpanPlanner.spans(from: old, to: new, leaveTailAppend: true, moveSettleMs: FieldQueue.moveSettleMs, editSettleMs: FieldQueue.editSettleMs)
        #expect(result.isEmpty || result.allSatisfy { $0.end < old.count || $0.start < $0.end })
    }

    @Test(arguments: [
        ("I think the plan is fine", "I think the plant is fine"),
        ("their going to the shop", "they're going to the shop"),
        ("hello world", "Hello, world."),
        ("one two three four five six", "1 2 3 4 5 6"),
        ("", "new text"),
        ("old text", ""),
    ])
    func spansAlwaysProduceTheTarget(old: String, new: String) {
        #expect(apply(spans(old, new), to: old) == new)
    }

    @Test func thePaceSpreadsTheBacklogBetweenTheFloorAndCalm() {
        #expect(SpanPlanner.paceMs(ops: 0) == SpanPlanner.calmMs)
        #expect(SpanPlanner.paceMs(ops: 5) == SpanPlanner.calmMs, "a short backlog types calmly")
        #expect(SpanPlanner.paceMs(ops: SpanPlanner.behindOps) == SpanPlanner.floorMs, "behind speech: straight to the floor")
        #expect(SpanPlanner.calmMs <= 30 && SpanPlanner.budgetMs <= 700, "the Mac's calm pace and budget")
        #expect(SpanPlanner.paceMs(ops: 500) == SpanPlanner.floorMs, "a long backlog goes at the floor")
        #expect(SpanPlanner.paceMs(ops: 10, fixedMs: 1_100) == SpanPlanner.floorMs, "settles use up the budget")
        let paces = (1...100).map { SpanPlanner.paceMs(ops: $0) }
        #expect(zip(paces, paces.dropFirst()).allSatisfy { $0 >= $1 }, "more to go is never slower")
    }
}
