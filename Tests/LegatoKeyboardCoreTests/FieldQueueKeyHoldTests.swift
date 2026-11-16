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

    private func words(_ text: String) -> [String] {
        text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }
    private func firstNewline(in rig: QueueRig) -> Double {
        rig.events.first { event in
            if case .sent(.insert(let text), .user) = event.event { return text.contains("\n") }
            return false
        }?.ms ?? .infinity
    }

    /// Every op of the take went out before the user's first key (none of it jumped back in front of the keys).
    private func takeWentFirst(_ rig: QueueRig) -> Bool {
        let lanes = rig.events.compactMap { if case .sent(_, let lane) = $0.event { lane } else { nil } }
        guard let firstKey = lanes.firstIndex(of: .user) else { return false }
        return !lanes[firstKey...].contains(.live)
    }

    /// A stopped backlog cannot hold native keys beyond 500 ms; every heard word survives once.
    @Test(arguments: [false, true])
    func enterAfterStopYieldsWithinBudgetWithoutDroppingHeardWords(safari: Bool) {
        var rig = rig("- ", safari: safari)
        let item = "Water the plants on the balcony"
        rig.queue.enqueue(snap(1, item)); rig.tick(); rig.queue.takeStopped("r")
        while !rig.field.string.hasSuffix("Water the plan"), rig.clockMs < 5_000 { rig.tick() }
        let asked = rig.clockMs
        type("\n- ", &rig)
        do { let drained = rig.drain(); #expect(drained) }
        #expect(firstNewline(in: rig) - asked < FieldQueue.responsivenessTargetMs)
        #expect(rig.field.string.components(separatedBy: "\n- ").count == 2)
        #expect(words(rig.field.string) == words(item))
        rig.queue.enqueue(LiveDictationSnapshot(runID: "r", version: 2,
            segments: [.init(id: 0, text: item + ".", cleaned: true, final: true)], complete: true))
        do { let drained = rig.drain(); #expect(drained) }
        #expect(words(rig.field.string) == words(item))
        #expect(rig.field.string.components(separatedBy: "\n- ").count == 2)
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
        // Preserve the historical total burst allowance (8 s old key hold + 30 s drain),
        // while the key itself must now land inside the independent 500 ms budget.
        do { let drained = rig.drain(limitMs: max(0, 38_000 - rig.clockMs)); #expect(drained) }
        let text = rig.field.string
        #expect(text.filter { $0 == "!" }.count == 1)
        #expect(text.replacingOccurrences(of: "!", with: "").replacingOccurrences(of: "  ", with: " ") == long)
        #expect(!text.hasSuffix("!"), "the rest of the take went on after the key")
    }

    /// The explicit 500 ms requirement supersedes waiting several seconds for a stopped backlog.
    @Test func aLongBacklogYieldsBeforeTheInputBudget() {
        var rig = rig("- ", safari: true)
        let item = "call the landlord about the heating and ask when the plumber can come by"
        rig.queue.enqueue(snap(1, item)); rig.tick(); rig.queue.takeStopped("r"); rig.run(ms: 300)
        let asked = rig.clockMs
        type("\n- ", &rig)
        do { let drained = rig.drain(limitMs: 30_000); #expect(drained) }
        #expect(firstNewline(in: rig) - asked < FieldQueue.responsivenessTargetMs)
        #expect(words(rig.field.string) == words(item))
        #expect(rig.field.string.components(separatedBy: "\n- ").count == 2)
    }

    /// Cleanup never extends the input wait; the key and every heard word still land once.
    @Test(arguments: [false, true])
    func aCleanupMidItemNeverHoldsTheKeys(safari: Bool) {
        var rig = rig("- ", safari: safari)
        let item = "call the landlord about the heating and ask when the plumber can come by"
        let cleaned = "Call the landlord about the heating, and ask when the plumber can come by."
        rig.queue.enqueue(snap(1, item)); rig.tick(); rig.queue.takeStopped("r"); rig.run(ms: 300)
        let asked = rig.clockMs
        rig.queue.enqueue(.insert("\n")); rig.run(ms: 700)
        rig.queue.enqueue(LiveDictationSnapshot(runID: "r", version: 2,
            segments: [.init(id: 0, text: cleaned, cleaned: true, final: true)], complete: true))
        do { let drained = rig.drain(limitMs: 30_000); #expect(drained) }
        #expect(firstNewline(in: rig) - asked < FieldQueue.responsivenessTargetMs)
        #expect(words(rig.field.string) == words(item))
        #expect(rig.field.string.filter { $0 == "\n" }.count == 1)
    }

    /// Missing provider finals cannot keep a native key captive; late words continue afterward.
    @Test(arguments: [false, true])
    func lateFinalWordsFollowTheKeyOnceTheInputBudgetExpires(safari: Bool) {
        var rig = rig("- ", safari: safari)
        rig.queue.enqueue(snap(1, "third call the landlord about the")); rig.tick(); rig.queue.takeStopped("r")
        while !rig.field.string.hasSuffix("about the"), rig.clockMs < 5_000 { rig.tick() }
        rig.run(ms: 100)
        let asked = rig.clockMs
        rig.queue.enqueue(.insert("\n")); rig.run(ms: 500)
        #expect(rig.field.string.contains("\n"), "late provider words cannot lock a native key past the input budget")
        #expect(firstNewline(in: rig) - asked < FieldQueue.responsivenessTargetMs)
        rig.queue.enqueue(snap(2, "third call the landlord about the heating"))
        do { let drained = rig.drain(); #expect(drained) }
        #expect(words(rig.field.string) == words("third call the landlord about the heating"))
        #expect(rig.field.string.hasSuffix("heating"))
        #expect(rig.field.string.filter { $0 == "\n" }.count == 1)
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
        #expect(keyAt - asked <= FieldQueue.responsivenessTargetMs)
        #expect(keyAt - asked >= FieldQueue.keyHoldMaxMs - 2 * rig.tickMs)
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

    /// Corrections preserve unchanged characters and restore the moved caret after verified jumps.
    @Test func cleanupUsesMinimalEditsAndReturnsTheMovedCaret() {
        var rig = rig("", safari: true)
        rig.queue.enqueue(snap(1, "the plan is fine"))
        do { let drained = rig.drain(); #expect(drained) }
        let from = rig.sent.count
        rig.queue.enqueue(snap(2, "The plan is fine.", complete: true))
        do { let drained = rig.drain(); #expect(drained) }
        #expect(rig.field.string == "The plan is fine.")
        #expect(rig.sent[from...].allSatisfy { if case .deleteBackward(let count) = $0.op { count == 1 } else { true } })
        rig.queue.enqueue(.move(-10))
        do { let drained = rig.drain(); #expect(drained) }
        let user = rig.field.caret
        rig.queue.enqueue(LiveDictationSnapshot(runID: "r", version: 3,
            segments: [.init(id: 0, text: "The plan is great.", cleaned: true, final: true)], complete: true))
        do { let drained = rig.drain(); #expect(drained) }
        #expect(rig.field.string == "The plan is great.")
        #expect(rig.field.caret == user)
        #expect(rig.drops.isEmpty)
    }
}

/// The 5 ms trial's cosmetic rhythm; queue safety checks separately cover host confirmation.
@Suite struct TypingRhythmTests {
    @Test func theTrialUsesFiveMillisecondsForEveryBacklog() {
        for ops in [0, 5, 13, 14, 100] {
            for fixed in [0.0, 600, 690] {
                #expect(SpanPlanner.macPaceMs(ops: ops, fixedMs: fixed) == 5)
                #expect(SpanPlanner.paceMs(ops: ops, fixedMs: fixed) == 5)
            }
        }
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
        // An immediate host and a fine clock isolate pacing from proxy latency and timer quantization.
        rig.tickMs = 1
        rig.queue.enqueue(snap(1, "ab cd"))
        do { let drained = rig.drain(); #expect(drained) }
        let inserts = rig.sent.compactMap { if case .insert(let s) = $0.op { ($0.ms, s) } else { nil } }
        #expect(inserts.map(\.1) == ["a", "b", " ", "c", "d"])
        let gaps = zip(inserts, inserts.dropFirst()).map { $1.0 - $0.0 }
        #expect(gaps == [5, 5, 5, 5], "spaces add no delay to the 5 ms character pace")
    }
}
