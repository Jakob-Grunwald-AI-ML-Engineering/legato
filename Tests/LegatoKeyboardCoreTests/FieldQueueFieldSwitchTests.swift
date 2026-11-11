import Testing
@testable import LegatoKeyboardCore

/// Safari gives every field of a page the same identity, so the keyboard cannot tell a field switch from a tap: the
/// queue is not told. A run's edits belong to the field they were typed into and never land in another one (UAT F2).
@Suite struct FieldQueueFieldSwitchTests {
    /// The user moves to another field: the queue sees only its reports from now on.
    private func switchField(_ rig: inout QueueRig, to text: String, safari: Bool) -> FakeField {
        let old = rig.field
        var field = FakeField(text)
        field.hostDelays = safari
        field.nowMs = rig.clockMs
        rig.field = field
        rig.fieldSwitched()
        return old
    }

    private func keyboardOps(_ rig: QueueRig, from: Int) -> [ShadowOp] {
        rig.events[from...].compactMap { if case .sent(let op, let lane) = $0.event, lane != .user { op } else { nil } }
    }

    private static func cleaned(_ text: String, run: String, version: Int) -> LiveDictationSnapshot {
        LiveDictationSnapshot(runID: run, version: version, segments: [.init(id: 0, text: text, cleaned: true, final: true)], complete: true)
    }

    /// The cleanup for field A's take arrives while the user is in an empty field (its report pins the start of any
    /// text): nothing jumps, nothing is typed there.
    @Test(arguments: [false, true])
    func aCleanupForTheLastFieldNeverJumpsIntoAnEmptyOne(safari: Bool) {
        var field = FakeField("Notes\n- ")
        field.hostDelays = safari
        var rig = QueueRig(field, config: .init(animated: true))
        rig.queue.enqueue(snap(1, "one two three four five six seven eight nine ten eleven twelve", run: "a"))
        rig.drain()
        let fieldA = switchField(&rig, to: "", safari: safari)
        rig.run(ms: 600)
        let from = rig.events.count
        rig.queue.enqueue(Self.cleaned("One two three four five six seven eight nine ten eleven twelve.", run: "a", version: 2))
        let drained1 = rig.drain()
        #expect(drained1)
        #expect(rig.field.string == "")
        #expect(keyboardOps(rig, from: from).allSatisfy { $0 == .move(0) })
        for key in ["-", " "] { rig.queue.enqueue(.insert(key)); rig.run(ms: 66) }
        rig.queue.enqueue(snap(1, "buy some milk", run: "c"))
        let drained2 = rig.drain()
        #expect(drained2)
        #expect(rig.field.string == "- buy some milk")
        #expect(fieldA.string == "Notes\n- one two three four five six seven eight nine ten eleven twelve")
    }

    /// The UAT's case: the other field holds a copy of a line of the first, so its report pins a place in the first
    /// field's text (a tap there, as far as the queue can tell). The cleanup's jump to the take goes nowhere in this
    /// field: it drops (the take is in History) and is never tried again; this field's text is untouched, and the next
    /// field gets only what is typed into it.
    @Test(arguments: [false, true])
    func aJumpThatGoesNowhereDropsItsWorkAndIsNeverRetried(safari: Bool) {
        var field = FakeField("- the meeting is at three\n- bring the laptop\n- ")
        field.hostDelays = safari
        var rig = QueueRig(field, config: .init(animated: true))
        rig.queue.enqueue(snap(1, "one two three four five six", run: "long"))
        rig.drain()
        _ = switchField(&rig, to: "- the meeting is at three", safari: safari)
        rig.run(ms: 600)
        let from = rig.events.count
        rig.queue.enqueue(Self.cleaned("One two three four five six.", run: "long", version: 2))
        let drained3 = rig.drain()
        #expect(drained3)
        #expect(rig.field.string == "- the meeting is at three")
        #expect(rig.field.caret == rig.field.text.count)
        #expect(rig.drops.contains { $0.runID == "long" && $0.reason == .unplaceable })
        let moves = keyboardOps(rig, from: from).filter { if case .move(let n) = $0 { n != 0 } else { false } }
        #expect(moves.count <= 1)
        #expect(!keyboardOps(rig, from: from).contains { if case .move = $0 { false } else { true } })
        // A later version of the old take is ignored in the next field, which gets only its own text.
        let fieldB = switchField(&rig, to: "", safari: safari)
        for key in ["-", " "] { rig.queue.enqueue(.insert(key)); rig.run(ms: 66) }
        rig.queue.enqueue(Self.cleaned("One, two, three, four, five, six.", run: "long", version: 3))
        rig.queue.enqueue(snap(1, "buy some milk", run: "next"))
        let drained4 = rig.drain()
        #expect(drained4)
        #expect(rig.field.string == "- buy some milk")
        #expect(fieldB.string == "- the meeting is at three")
        #expect(rig.field.deletions.isEmpty)
    }
}
