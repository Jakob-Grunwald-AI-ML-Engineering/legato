import Testing
@testable import LegatoKeyboardCore

@Suite struct FieldSpeechSchedulingTests {
    @Test func newTailAdvancesWhileAnEarlierRevisionWaitsForStop() {
        var target = FieldSpeechScheduling.Target()
        #expect(String(target.update(Array("we saw a boat"), speaking: true)) == "we saw a boat")
        #expect(String(target.update(Array("We saw a boat today"), speaking: true)) == "we saw a boat today")
        #expect(target.hasDeferredRevision)
        #expect(String(target.update(Array("We saw a boat today at noon"), speaking: true)) == "we saw a boat today at noon")
        #expect(String(target.update(target.authoritative, speaking: false)) == "We saw a boat today at noon")
        #expect(!target.hasDeferredRevision)
    }

    @Test func contractingSpeculationDoesNotDeleteHeardWordsUntilStop() {
        var target = FieldSpeechScheduling.Target()
        _ = target.update(Array("bring the blue boat"), speaking: true)
        #expect(String(target.update(Array("bring"), speaking: true)) == "bring the blue boat")
        #expect(String(target.update(Array("bring the blue boat"), speaking: true)) == "bring the blue boat")
        _ = target.update(Array("bring"), speaking: true)
        #expect(String(target.update(Array("bring the green boat"), speaking: true)) == "bring the blue boat")
        #expect(String(target.update(Array("bring the green boat today"), speaking: true)) == "bring the blue boat today")
        #expect(String(target.update(Array("bring the green boat"), speaking: false)) == "bring the green boat")
    }

    @Test func longRevisedSnapshotsUseAnUnchangedTailWithoutAWholeTakeDiff() {
        let original = "first " + String(repeating: "many repeated spoken words ", count: 1_000) + "unique harbor ending"
        var target = FieldSpeechScheduling.Target()
        _ = target.update(Array(original), speaking: true)
        let revised = "First " + String(original.dropFirst(6)) + " today"
        #expect(String(target.update(Array(revised), speaking: true)) == original + " today")
        #expect(String(target.authoritative) == revised)
    }

    @Test func keyboardDeliversNewSpeechWithoutJumpingToDeferredCorrections() {
        var rig = QueueRig(FakeField(""), config: .init(animated: false, prioritizeSpeech: true))
        rig.queue.enqueue(snap(1, "we saw a boat"))
        do { let drained = rig.drain(); #expect(drained) }
        let start = rig.sent.count
        rig.queue.enqueue(snap(2, "We saw a boat today"))
        do { let drained = rig.drain(); #expect(drained) }
        #expect(rig.field.string == "we saw a boat today")
        #expect(!rig.sent[start...].contains { if case .move = $0.op { true } else { false } })
        #expect(!rig.events.contains { $0.event == .liveApplied(runID: "r", version: 2, complete: false) })
        rig.queue.takeStopped("r")
        do { let drained = rig.drain(); #expect(drained) }
        #expect(rig.field.string == "We saw a boat today")
    }

    @Test func backgroundMagicWaitsWithoutDroppingWhileSpeechHasAPause() {
        var rig = QueueRig(FakeField("Header old. "), config: .init(animated: false, prioritizeSpeech: true))
        rig.queue.enqueue(.init(id: "magic", kind: .magic, before: "Header old. ", target: "Header new. ", cursorAtEnd: false))
        rig.queue.enqueue(snap(1, "fresh words"))
        do { let drained = rig.drain(); #expect(drained) }
        rig.run(ms: 5_000)
        #expect(rig.field.string == "Header old. fresh words")
        #expect(rig.drops.isEmpty)
        rig.queue.takeStopped("r")
        do { let drained = rig.drain(); #expect(drained) }
        #expect(rig.field.string == "Header new. fresh words")
        #expect(rig.applied == ["magic"])
    }

    @Test func aJoinedCleanupKeepsRawNewSegmentsAndCoalescesToItsFinalTarget() {
        var rig = QueueRig(FakeField(""), config: .init(animated: false, prioritizeSpeech: true))
        rig.queue.enqueue(snap(1, "we saw a boat"))
        do { let drained = rig.drain(); #expect(drained) }
        let segments: [LiveSegment] = [
            .init(id: 0, text: "We saw a boat and sailed.", cleaned: true, final: true, unit: 0, raw: "we saw a boat"),
            .init(id: 1, text: "", cleaned: true, final: true, unit: 0, raw: "and sailed")
        ]
        rig.queue.enqueue(.init(runID: "r", version: 2, segments: segments))
        do { let drained = rig.drain(); #expect(drained) }
        #expect(rig.field.string == "we saw a boat and sailed")
        rig.queue.enqueue(.init(runID: "r", version: 3, segments: segments, complete: true))
        do { let drained = rig.drain(); #expect(drained) }
        #expect(rig.field.string == "We saw a boat and sailed.")
    }

    @Test func nearbyRecoveryRetainsTheSameUniqueAnchoredMatchingRule() {
        var recovery = FieldRecovery()
        let request = recovery.begin(generation: "field", revision: 1,
                                     targets: [.init(id: "edit", expected: "boat", before: "Keep ", after: " Stay")])!
        #expect(FieldRecovery.nearbyLimit(for: request) < FieldRecovery.lookAroundChars)
        #expect(recovery.canResolve(request, text: "Keep boat Stay"))
        #expect(!recovery.canResolve(request, text: "Keep boat Stay Keep boat Stay"))
        #expect(!recovery.canResolve(request, text: "Keep ship Stay"))
    }
}
