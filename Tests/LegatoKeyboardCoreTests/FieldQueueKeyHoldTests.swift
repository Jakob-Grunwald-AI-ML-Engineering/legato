import Testing
@testable import LegatoKeyboardCore

/// Keys pressed while the take is still being typed (#268): they wait until the text already heard is typed (bounded by
/// `FieldQueue.keyHoldMaxMs`), then land in order. The caret shown again after a jump unit.
@Suite struct FieldQueueKeyHoldTests {
    private func rig(_ text: String, safari: Bool, keysWait: Bool = true) -> QueueRig {
        var field = FakeField(text)
        field.hostDelays = safari
        return QueueRig(field, config: .init(animated: true, keysWaitForTake: keysWait))
    }

    private func type(_ keys: String, _ rig: inout QueueRig) {
        for key in keys { rig.queue.enqueue(.insert(String(key))); rig.run(ms: 90) }
    }

    /// Every op of the take went out before the user's first key (none of it jumped back in front of the keys).
    private func takeWentFirst(_ rig: QueueRig) -> Bool {
        let lanes = rig.events.compactMap { if case .sent(_, let lane) = $0.event { lane } else { nil } }
        guard let firstKey = lanes.firstIndex(of: .user) else { return false }
        return !lanes[firstKey...].contains(.live)
    }

    /// The simulator repro: dictate, stop, Enter and "- " at once. On main the item came out as "- Water the plan".
    @Test(arguments: [false, true])
    func enterRightAfterAStopWaitsForTheItemsHeardText(safari: Bool) {
        var rig = rig("- ", safari: safari)
        let item = "Water the plants on the balcony"
        // The stop comes before the complete snapshot (the app publishes that with the cleanup).
        rig.queue.enqueue(snap(1, item))
        rig.tick()
        rig.queue.takeStopped("r")
        while !rig.field.string.hasSuffix("Water the plan"), rig.clockMs < 5_000 { rig.tick() }
        #expect(rig.field.string == "- Water the plan")
        type("\n- ", &rig)
        do { let drained = rig.drain(); #expect(drained) }
        #expect(rig.field.string == "- " + item + "\n- ")
        // The keys went one by one, in order, after the take's last grapheme.
        let sends = rig.events.compactMap { if case .sent(let op, let lane) = $0.event { (op, lane) } else { nil } }
        let keys = sends.enumerated().filter { $0.element.1 == .user }
        #expect(keys.map(\.element.0) == [.insert("\n"), .insert("-"), .insert(" ")])
        let lastLive = sends.lastIndex { $0.1 == .live }
        #expect(lastLive.map { $0 < (keys.first?.offset ?? 0) } == true)
        // The cleanup lands in the item's own text.
        rig.queue.enqueue(LiveDictationSnapshot(runID: "r", version: 2, segments: [.init(id: 0, text: item + ".", cleaned: true, final: true)], complete: true))
        do { let drained = rig.drain(); #expect(drained) }
        #expect(rig.field.string == "- " + item + ".\n- ")
    }

    /// Without the rule the keys cut the item (the bug).
    @Test func withoutTheRuleTheKeysCutTheItem() {
        var rig = rig("- ", safari: true, keysWait: false)
        rig.queue.enqueue(snap(1, "Water the plants on the balcony"))
        rig.tick()
        rig.queue.takeStopped("r")
        while !rig.field.string.hasSuffix("Water the plan"), rig.clockMs < 5_000 { rig.tick() }
        type("\n- ", &rig)
        rig.drain()
        #expect(rig.field.string != "- Water the plants on the balcony\n- ")
    }

    /// A key that cut a word of a stopped take short starts a word of its own once the take is typed.
    @Test func aLetterAfterACutWordStartsANewWord() {
        var rig = rig("", safari: false)
        rig.queue.enqueue(snap(1, "wonderful day", complete: true))
        while rig.field.string.count < 3, rig.clockMs < 2_000 { rig.tick() }
        rig.queue.enqueue(.insert("x"))
        do { let drained = rig.drain(); #expect(drained) }
        #expect(rig.field.string == "wonderful day x")
    }

    /// While the take is still spoken, a key goes at once as before: the cut word is finished, later words follow it.
    @Test func aKeyDuringSpeechGoesAtOnce() {
        var rig = rig("", safari: false)
        rig.queue.enqueue(snap(1, "wonderful day"))
        while rig.field.string.count < 3, rig.clockMs < 2_000 { rig.tick() }
        rig.queue.enqueue(.insert("x"))
        do { let drained = rig.drain(); #expect(drained) }
        #expect(rig.field.string == "wonderful x day")
    }

    /// A backlog longer than the hard cap holds the keys no longer than it: they land, and the rest of the take follows.
    @Test func theWaitIsCappedAndTheRestFollowsTheKeys() {
        var rig = rig("", safari: true)
        let long = String(repeating: "dictated words keep coming ", count: 12).trimmingCharacters(in: .whitespaces)
        rig.queue.enqueue(snap(1, long, complete: true))
        rig.run(ms: 300)
        rig.queue.enqueue(.insert("!"))
        let asked = rig.clockMs
        rig.run(ms: FieldQueue.keyHoldMaxMs + 400)
        let keyAt = rig.sent.first { if $0.ms > asked, case .insert(let s) = $0.op { s.hasSuffix("!") } else { false } }?.ms
        #expect(keyAt != nil)
        #expect((keyAt ?? .infinity) - asked <= FieldQueue.keyHoldMaxMs + FieldQueue.transitMs + 3 * rig.tickMs)
        do { let drained = rig.drain(limitMs: 30_000); #expect(drained) }
        let text = rig.field.string
        #expect(text.filter { $0 == "!" }.count == 1)
        #expect(text.replacingOccurrences(of: "!", with: "").replacingOccurrences(of: "  ", with: " ") == long)
        #expect(!text.hasSuffix("!"), "the rest of the take went on after the key")
    }

    /// UAT finding 2: a long item is typed whole before the keys, however long that takes (here about 5 s; on a device
    /// 190 characters take about 7 s), up to the hard cap. A fixed 2 s cap let them land mid-item.
    @Test func theWaitScalesWithTheTypingStillToDo() {
        var rig = rig("- ", safari: true)
        let item = "call the landlord about the heating and ask when the plumber can come by"
        rig.queue.enqueue(snap(1, item))
        rig.tick()
        rig.queue.takeStopped("r")
        rig.run(ms: 300)
        let asked = rig.clockMs
        type("\n- ", &rig)
        do { let drained = rig.drain(limitMs: 30_000); #expect(drained) }
        #expect(rig.field.string == "- " + item + "\n- ")
        let keyAt = rig.sent.first { $0.ms > asked && $0.op == .insert("\n") }?.ms ?? 0
        #expect(keyAt - asked > 3_000, "the item took longer than the old cap")
    }

    /// The take's cleanup arrives while the item is still being typed (Claude is quicker than a long item): the keys
    /// still wait for the item's end; the cleanup's changes to the words already typed follow them.
    @Test(arguments: [false, true])
    func aCleanupMidItemStillTypesTheItemsEndBeforeTheKeys(safari: Bool) {
        var rig = rig("- ", safari: safari)
        let item = "call the landlord about the heating and ask when the plumber can come by"
        let cleaned = "Call the landlord about the heating, and ask when the plumber can come by."
        rig.queue.enqueue(snap(1, item))
        rig.tick()
        rig.queue.takeStopped("r")
        rig.run(ms: 300)
        rig.queue.enqueue(.insert("\n"))
        rig.run(ms: 700)
        rig.queue.enqueue(LiveDictationSnapshot(runID: "r", version: 2, segments: [.init(id: 0, text: cleaned, cleaned: true, final: true)], complete: true))
        do { let drained = rig.drain(limitMs: 30_000); #expect(drained) }
        #expect(rig.field.string == "- " + cleaned + "\n")
        // Before the key went, the item's end was typed whole.
        let inserts = rig.events.compactMap { if case .sent(.insert(let s), let lane) = $0.event { (s, lane) } else { nil } }
        let key = inserts.firstIndex { $0.1 == .user } ?? inserts.endIndex
        #expect(inserts[..<key].map(\.0).joined().hasSuffix("come by."))
    }

    /// UAT finding 1: once stopped, the keys wait for the take to complete, so its final words, arriving after the
    /// text then known was typed, still go in before them.
    @Test(arguments: [false, true])
    func aStoppedTakesLateFinalWordsGoBeforeTheKeys(safari: Bool) {
        var rig = rig("- ", safari: safari)
        rig.queue.enqueue(snap(1, "third call the landlord about the"))
        rig.tick()
        rig.queue.takeStopped("r")
        while !rig.field.string.hasSuffix("about the"), rig.clockMs < 5_000 { rig.tick() }
        rig.run(ms: 100)
        rig.queue.enqueue(.insert("\n"))
        rig.run(ms: 500)
        #expect(!rig.field.string.contains("\n"), "the key waits for the take's final words")
        rig.queue.enqueue(snap(2, "third call the landlord about the heating"))
        do { let drained = rig.drain(); #expect(drained) }
        #expect(rig.field.string == "- third call the landlord about the heating\n")
        #expect(takeWentFirst(rig))
    }

    /// The app says the take stopped (any route: Action Button, bridge), not only the keyboard's mic key.
    @Test func aStopTheSnapshotCarriesHoldsTheKeys() {
        var rig = rig("- ", safari: true)
        let item = "third call the landlord about the heating"
        rig.queue.enqueue(snap(1, item))
        rig.tick()
        rig.queue.enqueue(LiveDictationSnapshot(runID: "r", version: 2, segments: [.init(id: 0, text: item, final: true)], stopped: true))
        while !rig.field.string.hasSuffix("about the"), rig.clockMs < 5_000 { rig.tick() }
        type("\n- ", &rig)
        do { let drained = rig.drain(); #expect(drained) }
        #expect(rig.field.string == "- " + item + "\n- ")
        #expect(takeWentFirst(rig))
    }

    /// A stopped take that never completes holds the keys only briefly once its text is typed.
    @Test func aTakeThatNeverCompletesReleasesTheKeysAfterTheSlack() {
        var rig = rig("", safari: true)
        rig.queue.enqueue(snap(1, "all typed"))
        rig.tick()
        rig.queue.takeStopped("r")
        do { let drained = rig.drain(); #expect(drained) }
        rig.queue.enqueue(.insert("!"))
        let asked = rig.clockMs
        rig.drain()
        let keyAt = rig.sent.first { if $0.ms > asked, case .insert(let s) = $0.op { s == "!" } else { false } }?.ms ?? .infinity
        #expect(keyAt - asked >= FieldQueue.keyHoldSlackMs - 2 * rig.tickMs)
        #expect(keyAt - asked <= FieldQueue.keyHoldSlackMs + FieldQueue.transitMs + 3 * rig.tickMs)
        #expect(rig.field.string == "all typed!")
    }

    /// The typed-line path: graphemes of the line already queued go before the key.
    @Test(arguments: [false, true])
    func aKeyWaitsForTheTypedLinesQueuedGraphemes(safari: Bool) {
        var rig = rig("Note:", safari: safari)
        rig.run(ms: 100)
        for grapheme in " buy milk" { rig.queue.enqueue(FieldQueue.Edit(kind: .typist, target: String(grapheme), atCursor: true)) }
        rig.queue.enqueue(.insert("\n"))
        do { let drained = rig.drain(); #expect(drained) }
        #expect(rig.field.string == "Note: buy milk\n")
    }

    /// The caret is shown again once after a cleanup's jumps, at the take's end only.
    @Test func theCaretIsRevealedOnceAtTheTakesEndOnly() {
        var rig = rig("", safari: true)
        rig.queue.enqueue(snap(1, "the plan is fine"))
        do { let drained = rig.drain(); #expect(drained) }
        var from = rig.sent.count
        rig.queue.enqueue(snap(2, "The plan is fine.", complete: true))
        do { let drained = rig.drain(); #expect(drained) }
        #expect(rig.field.string == "The plan is fine.")
        #expect(rig.sent[from...].map(\.op).suffix(3) == [.insert("."), .deleteBackward(1), .insert(".")])
        // The user moved into the text: a later cleanup's jump back goes there, and nothing is retyped.
        rig.queue.enqueue(.move(-10))
        do { let drained = rig.drain(); #expect(drained) }
        from = rig.sent.count
        rig.queue.enqueue(LiveDictationSnapshot(runID: "r", version: 3, segments: [.init(id: 0, text: "The plan is great.", cleaned: true, final: true)], complete: true))
        do { let drained = rig.drain(); #expect(drained) }
        #expect(rig.field.string == "The plan is great.")
        #expect(rig.sent[from...].last.map { if case .move = $0.op { true } else { false } } == true)
        #expect(rig.field.caret == 7)
    }
}

/// The Mac's rhythm (`KeystrokePlanner.paceMs` on macOS), bounded below by Safari's confirmation.
@Suite struct TypingRhythmTests {
    @Test func theCurveIsTheMacs() {
        // The Mac's values: calm 30 ms for a short change, its 5 ms floor once 14 or more wait, the budget between.
        #expect(SpanPlanner.macPaceMs(ops: 0) == 30)
        #expect(SpanPlanner.macPaceMs(ops: 5) == 30)
        #expect(SpanPlanner.macPaceMs(ops: 13) == 30)
        #expect(SpanPlanner.macPaceMs(ops: 14) == 5)
        #expect(SpanPlanner.macPaceMs(ops: 10, fixedMs: 600) == 10)
        #expect(SpanPlanner.macPaceMs(ops: 10, fixedMs: 690) == 5)
    }

    @Test func iOSNeverGoesFasterThanTheConfirmation() {
        for ops in 0...40 {
            for fixed in [0.0, 300, 690] {
                let pace = SpanPlanner.paceMs(ops: ops, fixedMs: fixed)
                #expect(pace == max(SpanPlanner.floorMs, SpanPlanner.macPaceMs(ops: ops, fixedMs: fixed)))
                #expect(pace >= SpanPlanner.floorMs)
            }
        }
    }

    @Test func noPauseBetweenWords() {
        var rig = QueueRig(FakeField(""), config: .init(animated: true))
        rig.queue.enqueue(snap(1, "ab cd"))
        do { let drained = rig.drain(); #expect(drained) }
        let inserts = rig.sent.compactMap { if case .insert(let s) = $0.op { ($0.ms, s) } else { nil } }
        #expect(inserts.map(\.1) == ["a", "b", " ", "c", "d"])
        let gaps = zip(inserts, inserts.dropFirst()).map { $1.0 - $0.0 }
        #expect(gaps.allSatisfy { $0 < 2 * SpanPlanner.floorMs })
    }
}
