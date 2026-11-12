import Testing
@testable import LegatoKeyboardCore

/// A take's text that is heard but not typed yet (the typewriter's backlog) belongs to the place the take is typing:
/// the user's key lands at once, the rest finishes in the take's own text as a jump unit, and a switch to another field
/// (which Safari does not report) never takes any of it there (simulator UAT, 2026-11-11).
@Suite struct FieldQueueBacklogTests {
    /// A cleaned take published whole (the typed-line modes: on stop, after a pause, line by line).
    static func take(_ text: String, run: String, version: Int = 1) -> LiveDictationSnapshot {
        LiveDictationSnapshot(runID: run, version: version, segments: [.init(id: 0, text: text, cleaned: true, final: true)], complete: true)
    }

    private static let parcel = "pick up the parcel from the post office before it closes at six"

    /// The text typed so far is the take's start, cut at a word's end.
    private static func wholeWords(_ typed: String, of take: String) -> Bool {
        guard take.hasPrefix(typed) else { return false }
        let rest = take.dropFirst(typed.count)
        return rest.isEmpty || rest.first == " "
    }

    /// UAT bug 1: the user taps another field while the backlog types. Safari says nothing and its proxy goes on echoing
    /// the old field, so before the fix the rest of the take ("he post office…") typed into the new field. Now each word
    /// goes after a probe of the field: the old field keeps whole words, the new field gets nothing of the take (a word
    /// that landed there comes out again), the rest drops once to History, and words heard later start at the new caret.
    @Test(arguments: [(false, 300.0), (false, 650.0), (false, 1300.0), (true, 300.0), (true, 650.0), (true, 1300.0)])
    func aSwitchToAnotherFieldNeverTakesTheBacklogThere(safari: Bool, switchAfterMs: Double) {
        var field = FakeField("")
        field.hostDelays = safari
        var rig = QueueRig(field, config: .init(animated: true))
        rig.queue.enqueue(Self.take(Self.parcel, run: "a"))
        rig.run(ms: switchAfterMs)
        let old = rig.silentSwitch(to: "")
        let drained = rig.drain()
        #expect(drained)
        #expect(rig.field.string == "")
        #expect(Self.wholeWords(old.string, of: Self.parcel), "old field \(old.string.debugDescription)")
        #expect(old.string != Self.parcel)
        #expect(rig.drops.filter { $0.runID == "a" && $0.reason == .unplaceable }.count == 1)
        rig.queue.enqueue(Self.take("buy oat milk", run: "b"))
        let drained2 = rig.drain()
        #expect(drained2)
        #expect(rig.field.string == "buy oat milk")
    }

    /// A take that typed nothing yet when the user moved on is typed where the user is (every take starts at the caret).
    @Test(arguments: [false, true])
    func aTakeThatTypedNothingYetFollowsTheUserToTheOtherField(safari: Bool) {
        var field = FakeField("Notes: ")
        field.hostDelays = safari
        var rig = QueueRig(field, config: .init(animated: true))
        rig.queue.enqueue(Self.take("buy oat milk", run: "a"))
        let old = rig.silentSwitch(to: "To: ")
        let drained = rig.drain()
        #expect(drained)
        #expect(old.string == "Notes: ")
        #expect(rig.field.string == "To: buy oat milk")
        #expect(rig.drops.isEmpty)
    }

    /// UAT bug 2: Enter, "-" and space mid-typewriter. Before the fix the take's region closed at the word typed so far
    /// and its rest went to the caret ("- Water the plan" and the tail typed after the user's "- "). The keys land at
    /// once; the rest finishes in the take's own line; the next take starts at the caret.
    @Test(arguments: [(false, 450.0), (false, 700.0), (true, 450.0), (true, 700.0), (true, 1000.0)])
    func keysMidBacklogLandAtOnceAndTheTakeFinishesInItsOwnLine(safari: Bool, keysAfterMs: Double) {
        var field = FakeField("- ")
        field.hostDelays = safari
        var rig = QueueRig(field, config: .init(animated: true))
        rig.queue.enqueue(Self.take("water the plants on the balcony", run: "a"))
        rig.run(ms: keysAfterMs)
        var keys = ""
        for key in ["\n", "-", " "] {
            rig.queue.enqueue(.insert(key))
            keys += key
            // Each key is in the field within its bound (one op in flight, then the host's transit), at the line's end.
            rig.run(ms: FieldQueue.userBoundMs + 2 * rig.tickMs + 110)
            #expect(rig.field.string.hasSuffix(keys), "after \(keys.debugDescription): \(rig.field.string.debugDescription)")
        }
        #expect(rig.field.string.hasSuffix("\n- "))
        rig.queue.enqueue(Self.take("call the plumber tomorrow", run: "b"))
        let drained = rig.drain()
        #expect(drained)
        #expect(rig.field.string == "- water the plants on the balcony\n- call the plumber tomorrow")
        #expect(rig.drops.isEmpty)
    }

    /// The same with a tap elsewhere in the field: the rest finishes in the take's text, not at the tap.
    @Test(arguments: [false, true])
    func aTapElsewhereMidBacklogFinishesTheTakeInItsOwnText(safari: Bool) {
        var field = FakeField("Shopping: ")
        field.hostDelays = safari
        var rig = QueueRig(field, config: .init(animated: true))
        rig.queue.enqueue(Self.take("water the plants on the balcony", run: "a"))
        rig.run(ms: 500)
        rig.field.tap(at: 0)
        rig.outsidePending = true
        let drained = rig.drain()
        #expect(drained)
        #expect(rig.field.string == "Shopping: water the plants on the balcony")
        #expect(rig.field.caret == 0)
        #expect(rig.drops.isEmpty)
    }

    /// Live: the raw words are still typing when the user starts the next line; the cleanup that follows lands in the
    /// take's own words, and words heard after the keys start at the caret.
    @Test(arguments: [false, true])
    func aCleanupAfterKeysMidBacklogLandsInTheTakesOwnWords(safari: Bool) {
        var field = FakeField("- ")
        field.hostDelays = safari
        var rig = QueueRig(field, config: .init(animated: true))
        rig.queue.enqueue(snap(1, "water the plants on the balcony", run: "live"))
        rig.run(ms: 450)
        for key in ["\n", "-", " "] { rig.queue.enqueue(.insert(key)); rig.run(ms: 150) }
        rig.queue.enqueue(LiveDictationSnapshot(runID: "live", version: 2, segments: [
            .init(id: 0, text: "water the plants on the balcony", final: true),
            .init(id: 1, text: "call the plumber", final: false),
        ]))
        rig.run(ms: 600)
        rig.queue.enqueue(LiveDictationSnapshot(runID: "live", version: 3, segments: [
            .init(id: 0, text: "Water the plants on the balcony.", cleaned: true, final: true),
            .init(id: 1, text: "Call the plumber.", cleaned: true, final: true),
        ], complete: true))
        let drained = rig.drain()
        #expect(drained)
        #expect(rig.field.string == "- Water the plants on the balcony.\n- Call the plumber.")
    }

    /// The typewriter types a word per op, each after a probe whose report the host made: a move of one grapheme and back
    /// (Safari answers no zero-offset move, and its proxy echoes edits without the host), and a last probe after the
    /// last word.
    @Test func theTypewriterTypesAWordPerOpEachAfterAProbe() {
        var field = FakeField("Note: ")
        field.hostDelays = true
        var rig = QueueRig(field, config: .init(animated: true))
        rig.queue.enqueue(Self.take("one two three", run: "a"))
        let drained = rig.drain()
        #expect(drained)
        #expect(rig.field.string == "Note: one two three")
        let ops = rig.sent.map(\.op)
        #expect(ops.filter { if case .insert = $0 { true } else { false } } == [.insert("one"), .insert(" two"), .insert(" three")])
        #expect(ops == [.move(-1), .move(1), .insert("one"), .move(-1), .move(1), .insert(" two"), .move(-1), .move(1), .insert(" three"),
                        .move(-1), .move(1)])
    }
}
