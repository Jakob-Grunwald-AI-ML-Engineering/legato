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

    /// A recorded Mac take: a partial last word was heard again as a whole word and every later snapshot stayed
    /// unplaceable, so 22 s of continuous speech waited for a pause. New speech must reach the field with the next
    /// snapshot that carries it.
    @Test(arguments: [
        // The last word heard again as another: it stays as typed, the words after it go on.
        ("we sailed past the harbour wall and tied up at the ke", "we sailed past the harbour wall and tied up at the quay", " before noon"),
        // More than the last few words heard again: no place for the delivered end, the revision goes out at once.
        ("we sailed past the harbour wall and tied up at the ke", "we sailed past the harbour wall and tide upset a key", " before noon")
    ])
    func newSpeechAfterARevisedTailIsNeverHeldForAPause(first: String, revised: String, more: String) {
        var target = FieldSpeechScheduling.Target()
        _ = target.update(Array(first), speaking: true)
        _ = target.update(Array(revised), speaking: true)
        let delivered = String(target.update(Array(revised + more), speaking: true))
        #expect(delivered.hasSuffix(more), "the words said after the revision are delivered while speech goes on")
        #expect(String(target.update(target.authoritative, speaking: false)) == revised + more)
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

    @Test func keyboardAppendsWhileSpeakingThenAppliesOnlyTheChangedLetterDuringAPause() {
        var rig = QueueRig(FakeField(""), config: .init(prioritizeSpeech: true))
        rig.queue.enqueue(snap(1, "we saw a boat"))
        do { let drained = rig.drain(); #expect(drained) }
        let start = rig.sent.count
        rig.queue.enqueue(snap(2, "We saw a boat today"))
        do { let drained = rig.drain(); #expect(drained) }
        #expect(rig.field.string == "we saw a boat today")
        #expect(rig.sent[start...].map(\.op) == [.insert(" today")])
        #expect(!rig.events.contains { $0.event == .liveApplied(runID: "r", version: 2, complete: false) })
        let paused = rig.sent.count
        rig.queue.setSpeaking(false, runID: "r")
        do { let drained = rig.drain(); #expect(drained) }
        #expect(rig.field.string == "We saw a boat today")
        #expect(rig.sent[paused...].map(\.op) == [.move(-18), .deleteBackward(1), .insert("W"), .move(18)])
        #expect(rig.events.contains { $0.event == .liveApplied(runID: "r", version: 2, complete: false) })
    }

    @Test func keyboardDefersARevisionFarFromTheCaretUntilTheStop() {
        var rig = QueueRig(FakeField(""), config: .init(prioritizeSpeech: true))
        let rest = " and the wind came up from the west so we reefed the main and ran"
        rig.queue.enqueue(snap(1, "we saw a boat" + rest))
        do { let drained = rig.drain(); #expect(drained) }
        let start = rig.sent.count
        rig.queue.enqueue(snap(2, "We saw a boat" + rest + " home"))
        do { let drained = rig.drain(); #expect(drained) }
        #expect(rig.field.string == "we saw a boat" + rest + " home")
        #expect(rig.sent[start...].map(\.op) == [.insert(" home")])
        #expect(!rig.events.contains { $0.event == .liveApplied(runID: "r", version: 2, complete: false) })
        rig.queue.takeStopped("r")
        rig.queue.enqueue(snap(3, "We saw a boat" + rest + " home.", complete: true))
        do { let drained = rig.drain(); #expect(drained) }
        #expect(rig.field.string == "We saw a boat" + rest + " home.")
    }

    @Test func backgroundMagicWaitsWithoutDroppingWhileSpeechHasAPause() {
        var rig = QueueRig(FakeField("Header old. "), config: .init(prioritizeSpeech: true))
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
        var rig = QueueRig(FakeField(""), config: .init(prioritizeSpeech: true))
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
        #expect(!recovery.hasAmbiguity(request, text: "Keep boat Stay"))
        #expect(recovery.hasAmbiguity(request, text: "Keep boat Stay Keep boat Stay"))
        #expect(!recovery.canResolve(request, text: "Keep boat Stay Keep boat Stay"))
        #expect(!recovery.canResolve(request, text: "Keep ship Stay"))
    }
}
