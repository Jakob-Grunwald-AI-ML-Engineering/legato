import Testing
@testable import LegatoKeyboardCore

/// User input wins: a key waits only for the chunk that is running (#299). Speech is one chunk, typed whole, so a key
/// after a stop lands after the words already heard without any hold; heard words survive once.
@Suite struct FieldQueueKeyOrderTests {
    private func rig(_ text: String, safari: Bool) -> QueueRig {
        var field = FakeField(text)
        field.hostDelays = safari
        return QueueRig(field, config: .init())
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
    private static let budget = FieldEditCoordinator.inputResponseTargetMs

    @Test(arguments: [false, true])
    func enterAfterStopLandsAfterTheHeardWordsWithinBudget(safari: Bool) {
        var rig = rig("- ", safari: safari)
        let item = "Water the plants on the balcony"
        rig.queue.enqueue(snap(1, item)); rig.tick(); rig.queue.takeStopped("r")
        while !rig.field.string.hasSuffix("balcony"), rig.clockMs < 5_000 { rig.tick() }
        let asked = rig.clockMs
        type("\n- ", &rig)
        do { let drained = rig.drain(); #expect(drained) }
        #expect(firstNewline(in: rig) - asked < Self.budget)
        #expect(rig.field.string == "- " + item + "\n- ")
        rig.queue.enqueue(LiveDictationSnapshot(runID: "r", version: 2,
            segments: [.init(id: 0, text: item + ".", cleaned: true, final: true)], complete: true))
        do { let drained = rig.drain(); #expect(drained) }
        #expect(words(rig.field.string) == words(item))
        #expect(rig.field.string.components(separatedBy: "\n- ").count == 2)
    }

    /// A key pressed while a cleanup chunk runs goes right after that chunk (its return hop), before the next chunk,
    /// and lands at the user's caret.
    @Test(arguments: [false, true])
    func aKeyGoesBehindTheRunningChunkAndBeforeTheNext(safari: Bool) throws {
        var rig = rig("", safari: safari)
        rig.queue.enqueue(snap(1, "the plan is fine and the boat is ready"))
        do { let drained = rig.drain(); #expect(drained) }
        let from = rig.sent.count
        rig.queue.enqueue(LiveDictationSnapshot(runID: "r", version: 2,
            segments: [.init(id: 0, text: "The plan is fine, and the boat is ready.", cleaned: true, final: true)], complete: true))
        // Step until the first chunk's first op is out, then press a key.
        while rig.sent.count == from, rig.clockMs < 5_000 { rig.tick() }
        rig.queue.enqueue(.insert("!"))
        do { let drained = rig.drain(); #expect(drained) }
        let ops = rig.sent[from...].map(\.op)
        let key = try #require(ops.firstIndex(of: .insert("!")))
        // Everything before the key is one chunk: it ends with the hop back to the caret, no op of a second chunk.
        let before = Array(ops[..<key])
        #expect(before.filter { if case .move = $0 { true } else { false } }.count <= 2)
        #expect(rig.field.string.hasSuffix("!"))
        #expect(rig.field.string.filter { $0 == "!" }.count == 1)
        #expect(words(rig.field.string) == words("the plan is fine and the boat is ready"))
    }

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
        #expect(firstNewline(in: rig) - asked < Self.budget)
        #expect(words(rig.field.string) == words(item))
        #expect(rig.field.string.filter { $0 == "\n" }.count == 1)
    }

    /// Missing provider finals never keep a key captive; late words continue at the caret afterward.
    @Test(arguments: [false, true])
    func lateFinalWordsFollowTheKey(safari: Bool) {
        var rig = rig("- ", safari: safari)
        rig.queue.enqueue(snap(1, "third call the landlord about the")); rig.tick(); rig.queue.takeStopped("r")
        while !rig.field.string.hasSuffix("about the"), rig.clockMs < 5_000 { rig.tick() }
        let asked = rig.clockMs
        rig.queue.enqueue(.insert("\n")); rig.run(ms: 500)
        #expect(rig.field.string.contains("\n"))
        #expect(firstNewline(in: rig) - asked < Self.budget)
        rig.queue.enqueue(snap(2, "third call the landlord about the heating"))
        do { let drained = rig.drain(); #expect(drained) }
        #expect(words(rig.field.string) == words("third call the landlord about the heating"))
        #expect(rig.field.string.filter { $0 == "\n" }.count == 1)
    }

    /// A stop carried by the snapshot (any route) changes nothing for the keys: the typed take stands before them.
    @Test func keysAfterAStoppedTakeLandAfterIt() {
        var rig = rig("- ", safari: true)
        let item = "third call the landlord about the heating"
        rig.queue.enqueue(snap(1, item))
        rig.tick()
        rig.queue.enqueue(LiveDictationSnapshot(runID: "r", version: 2, segments: [.init(id: 0, text: item, final: true)], stopped: true))
        while !rig.field.string.hasSuffix("heating"), rig.clockMs < 5_000 { rig.tick() }
        type("\n- ", &rig)
        do { let drained = rig.drain(); #expect(drained) }
        #expect(rig.field.string == "- " + item + "\n- ")
    }

    /// No hold: a key after a stopped take that never completes goes at once.
    @Test func aKeyAfterAStoppedTakeGoesAtOnce() {
        var rig = rig("", safari: true)
        rig.queue.enqueue(snap(1, "all typed"))
        rig.tick()
        rig.queue.takeStopped("r")
        do { let drained = rig.drain(); #expect(drained) }
        rig.queue.enqueue(.insert("!"))
        let asked = rig.clockMs
        rig.drain()
        let keyAt = rig.sent.first { if $0.ms > asked, case .insert(let s) = $0.op { s == "!" } else { false } }?.ms ?? .infinity
        #expect(keyAt - asked <= 2 * rig.tickMs)
        #expect(rig.field.string == "all typed!")
    }

    /// Corrections preserve unchanged characters and return the moved caret.
    @Test func cleanupUsesMinimalEditsAndReturnsTheMovedCaret() {
        var rig = rig("", safari: true)
        rig.queue.enqueue(snap(1, "the plan is fine"))
        do { let drained = rig.drain(); #expect(drained) }
        let from = rig.sent.count
        rig.queue.enqueue(snap(2, "The plan is fine.", complete: true))
        do { let drained = rig.drain(); #expect(drained) }
        #expect(rig.field.string == "The plan is fine.")
        let deleted = rig.sent[from...].reduce(0) { if case .deleteBackward(let n) = $1.op { $0 + n } else { $0 } }
        #expect(deleted == 1, "only the changed letter goes")
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

/// The Mac's typing rhythm (`SpanPlanner` pace); the iPhone sends speech whole.
@Suite struct TypingRhythmTests {
    @Test func theTrialUsesFiveMillisecondsForEveryBacklog() {
        for ops in [0, 5, 13, 14, 100] {
            for fixed in [0.0, 600, 690] {
                #expect(SpanPlanner.macPaceMs(ops: ops, fixedMs: fixed) == 5)
                #expect(SpanPlanner.paceMs(ops: ops, fixedMs: fixed) == 5)
            }
        }
    }

    @Test func iPhoneSpeechGoesInOneInsert() {
        var rig = QueueRig(FakeField(""), config: .init())
        rig.tickMs = 1
        rig.queue.enqueue(snap(1, "ab cd"))
        do { let drained = rig.drain(); #expect(drained) }
        let inserts = rig.sent.compactMap { if case .insert(let s) = $0.op { s } else { nil } }
        #expect(inserts == ["ab cd"])
    }
}
