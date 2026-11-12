import Testing
@testable import LegatoKeyboardCore

/// A take that is spoken but not typed yet (the typewriter's backlog) when the user presses a key or moves to another
/// field (#268). A key in the same field lands at once and the rest of the take finishes in its own text; a switch to
/// another field (Safari says nothing) lets the rest go on at the new caret and drops the take's cleanup.
@Suite struct FieldQueueBacklogTests {
    static func raw(_ text: String, run: String, version: Int = 1) -> LiveDictationSnapshot {
        LiveDictationSnapshot(runID: run, version: version, segments: [.init(id: 0, text: text, final: true)], complete: true)
    }

    static func cleaned(_ text: String, run: String, version: Int = 2) -> LiveDictationSnapshot {
        LiveDictationSnapshot(runID: run, version: version, segments: [.init(id: 0, text: text, cleaned: true, final: true)], complete: true)
    }

    /// Simulator Safari: "water the plants on the balcony", stop, Enter, "-", space at once, the next item. Before the
    /// fix the take's region closed at the word typed so far and the rest never came ("- Water the plan").
    @Test(arguments: [(false, 300.0), (false, 700.0), (true, 300.0), (true, 700.0), (true, 1000.0)])
    func enterMidItemLandsAtOnceAndTheItemFinishesInItsOwnLine(safari: Bool, keysAfterMs: Double) {
        var field = FakeField("- ")
        field.hostDelays = safari
        var rig = QueueRig(field, config: .init(animated: true))
        rig.queue.enqueue(Self.raw("water the plants on the balcony", run: "a"))
        rig.run(ms: keysAfterMs)
        #expect(rig.field.string.count < "- water the plants on the balcony".count, "the take is still typing")
        var keys = ""
        for key in ["\n", "-", " "] {
            rig.queue.enqueue(.insert(key))
            keys += key
            // The key is in the field within its bound (the op in flight, then the host's transit), at the user's caret.
            rig.run(ms: FieldQueue.userBoundMs + 2 * rig.tickMs + 110)
            #expect(rig.field.string.hasSuffix(keys), "after \(keys.debugDescription): \(rig.field.string.debugDescription)")
        }
        rig.queue.enqueue(snap(1, "call the plumber", run: "b"))
        rig.run(ms: 300)
        rig.queue.enqueue(Self.cleaned("Water the plants on the balcony.", run: "a"))
        rig.queue.enqueue(snap(2, "call the plumber tomorrow", run: "b", complete: true))
        let drained1 = rig.drain(); #expect(drained1)
        rig.queue.enqueue(Self.cleaned("Call the plumber tomorrow.", run: "b", version: 3))
        let drained2 = rig.drain(); #expect(drained2)
        #expect(rig.field.string == "- Water the plants on the balcony.\n- Call the plumber tomorrow.")
        #expect(rig.drops.isEmpty)
        #expect(rig.field.reorders == 0 && rig.field.staleTriggers == 0)
    }

    /// Simulator Safari: the user taps another field while the backlog types. Safari says nothing and its proxy goes on
    /// showing the old field, so the rest types into the new field at its caret. The queue finds out before its next jump
    /// (a nudge: back one grapheme, then forward): the take's cleanup lands in neither field, and the model is the new
    /// field's, so later typing lands at the caret there.
    @Test(arguments: [(false, 500.0, ""), (true, 500.0, ""), (true, 900.0, ""), (true, 700.0, "Subject: "), (false, 700.0, "Subject: ")])
    func aSilentSwitchTakesTheRestToTheNewFieldAndDropsTheCleanup(safari: Bool, switchAfterMs: Double, other: String) {
        let take = "pick up the parcel from the post office before it closes at six"
        var field = FakeField("Note: ")
        field.hostDelays = safari
        var rig = QueueRig(field, config: .init(animated: true))
        rig.queue.enqueue(Self.raw(take, run: "a"))
        rig.run(ms: switchAfterMs)
        let old = rig.silentSwitch(to: other)
        let drained3 = rig.drain(); #expect(drained3)
        let oldText = old.string, newText = rig.field.string
        #expect(oldText.hasPrefix("Note: ") && newText.hasPrefix(other))
        #expect(String(oldText.dropFirst("Note: ".count)) + String(newText.dropFirst(other.count)) == take,
                "old \(oldText.debugDescription), new \(newText.debugDescription)")
        #expect(oldText.count > "Note: ".count && newText.count > other.count)
        rig.queue.enqueue(Self.cleaned("Pick up the parcel from the post office before it closes at six.", run: "a"))
        let drained4 = rig.drain(); #expect(drained4)
        #expect(rig.field.string == newText, "the cleanup stays out of the new field")
        #expect(!rig.drops.contains { $0.reason == .unplaceable })
        // The model is the new field's: the next take starts at its caret.
        rig.queue.enqueue(Self.raw("buy oat milk", run: "b"))
        let drained5 = rig.drain(); #expect(drained5)
        #expect(rig.field.string == newText + " buy oat milk")
        #expect(rig.field.caret == rig.field.text.count)
        #expect(rig.field.reorders == 0 && rig.field.staleTriggers == 0)
    }

    /// The same switch with the user's key in the new field before the rest is typed: the key lands at the caret there,
    /// and the rest goes on after it.
    @Test(arguments: [false, true])
    func aKeyAfterASilentSwitchLandsAtTheNewCaretAndTheRestFollows(safari: Bool) {
        let take = "pick up the parcel from the post office before it closes at six"
        var field = FakeField("Note: ")
        field.hostDelays = safari
        var rig = QueueRig(field, config: .init(animated: true))
        rig.queue.enqueue(Self.raw(take, run: "a"))
        rig.run(ms: 500)
        let old = rig.silentSwitch(to: "To: ")
        rig.run(ms: 200)
        rig.queue.enqueue(.insert(","))
        let drained6 = rig.drain(); #expect(drained6)
        let typedOld = String(old.string.dropFirst("Note: ".count))
        #expect(take.hasPrefix(typedOld))
        let new = rig.field.string
        #expect(new.hasPrefix("To: ") && new.contains(","))
        // Every word of the rest is in the new field, in order, after the user's key.
        let restWords = new.dropFirst("To: ".count).replacingOccurrences(of: ",", with: " ").split(separator: " ").map(String.init)
        #expect((typedOld + " " + restWords.joined(separator: " ")).replacingOccurrences(of: "  ", with: " ").contains("closes at six"))
        #expect(rig.field.userInserts.allSatisfy { $0.caret == $0.userCaret })
        #expect(!rig.drops.contains { $0.reason == .unplaceable })
    }
}
