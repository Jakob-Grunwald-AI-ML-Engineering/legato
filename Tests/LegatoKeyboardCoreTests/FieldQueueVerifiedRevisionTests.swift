import Testing
@testable import LegatoKeyboardCore

@Suite struct FieldQueueVerifiedRevisionTests {
    @Test func farRevisionWaitsForTheRoutePauseThenChangesOnlyItsOwnLetters() {
        var rig = QueueRig(FakeField(""), config: .init(animated: true, prioritizeSpeech: true))
        let tail = " while the rest of the unchanged sentence continues all the way to the harbour"
        rig.queue.enqueue(snap(1, "the cat waits" + tail)); do { let drained = rig.drain(); #expect(drained) }
        rig.queue.enqueue(snap(2, "the dog waits" + tail)); do { let drained = rig.drain(); #expect(drained) }
        #expect(rig.field.string == "the cat waits" + tail)
        let from = rig.sent.count
        rig.queue.setSpeaking(false, runID: "r")
        do { let drained = rig.drain(); #expect(drained) }
        #expect(rig.field.string == "the dog waits" + tail)
        let edits = rig.sent[from...].map(\.op)
        #expect(edits.filter { if case .deleteBackward = $0 { true } else { false } }.count == 3)
        #expect(edits.filter { if case .insert = $0 { true } else { false } } == [.insert("d"), .insert("o"), .insert("g")])
    }

    @Test func typingAfterTheTakeDoesNotFreezeUnchangedWords() {
        var rig = QueueRig(FakeField(""), config: .init(animated: true, prioritizeSpeech: true))
        rig.queue.enqueue(snap(1, "the cat waits")); do { let drained = rig.drain(); #expect(drained) }
        rig.queue.enqueue(.insert("!")); do { let drained = rig.drain(); #expect(drained) }
        rig.queue.enqueue(snap(2, "the dog waits", complete: true)); do { let drained = rig.drain(); #expect(drained) }
        #expect(rig.field.string == "the dog waits!")
    }

    @Test func theUsersChangedWordWinsWhileAnotherWordIsCorrected() {
        var rig = QueueRig(FakeField(""), config: .init(animated: true, prioritizeSpeech: true))
        rig.queue.enqueue(snap(1, "the cat waits near the boat")); do { let drained = rig.drain(); #expect(drained) }
        rig.queue.enqueue(.move(-15)); do { let drained = rig.drain(); #expect(drained) }
        rig.queue.enqueue(.insert("X")); do { let drained = rig.drain(); #expect(drained) }
        let current = rig.field.string
        #expect(current.contains("X"))
        rig.queue.enqueue(snap(2, "the dog waits near the ship", complete: true)); do { let drained = rig.drain(); #expect(drained) }
        #expect(rig.field.string.contains("X"))
        #expect(rig.field.string.hasPrefix("the dog"))
        #expect(rig.field.string.hasSuffix("the ship"))
    }

    @Test func resumedSpeechYieldsTheRevisionBeforeAnotherHunk() {
        var field = FakeField(""); field.hostDelays = true
        var rig = QueueRig(field, config: .init(animated: true, prioritizeSpeech: true))
        let tail = " while the unchanged words keep going towards the boat in the harbour"
        rig.queue.enqueue(snap(1, "the cat waits" + tail)); do { let drained = rig.drain(); #expect(drained) }
        rig.queue.enqueue(snap(2, "the dog waits" + tail)); rig.queue.setSpeaking(false, runID: "r")
        while !rig.sent.contains(where: { $0.op == .deleteBackward(1) }), rig.clockMs < 20_000 { rig.tick() }
        rig.queue.setSpeaking(true, runID: "r")
        let start = rig.clockMs
        rig.queue.enqueue(.insert("!"))
        rig.run(ms: 500)
        let key = rig.sent.first { $0.ms >= start && $0.op == .insert("!") }
        #expect(key != nil)
        #expect((key?.ms ?? .infinity) - start < FieldQueue.responsivenessTargetMs)
        rig.queue.setSpeaking(false, runID: "r"); do { let drained = rig.drain(); #expect(drained) }
        #expect(rig.field.string.filter { $0 == "!" }.count == 1)
        #expect(rig.field.string.contains("the unchanged words keep going"))
    }

    @Test func identicalOpaqueSelectionWindowsNeverTriggerAnAutomaticMove() {
        var queue = FieldQueue(config: .init(animated: true))
        let old = FieldQueue.Report(before: "a complete selected draft")
        _ = queue.step(report: old, elapsedMs: 200)
        queue.externalSelectionChanged(report: old)
        queue.enqueue(FieldQueue.Edit(kind: .magic, before: old.before, target: "A complete selected draft"))
        for _ in 0..<20 { #expect(queue.step(report: old, elapsedMs: 33) == .idle) }
        #expect(queue.hasUnverifiedSelection)
        queue.enqueue(.insert("x"))
        #expect(queue.step(report: old, elapsedMs: 33) == .send(.insert("x")))
        // The native key intentionally replaces Select All. Fresh readback, never replay, owns this new draft.
        _ = queue.step(report: .init(before: "x"), elapsedMs: 120)
        _ = queue.step(report: .init(before: "x"), elapsedMs: 50)
        #expect(queue.modelText == "x")
        #expect(!queue.hasUnverifiedSelection)
    }

    @Test func independentlyChangedStableWindowsResolveOpaqueCaretEvidence() {
        var queue = FieldQueue()
        let end = FieldQueue.Report(before: "alpha beta")
        _ = queue.step(report: end, elapsedMs: 200)
        queue.externalSelectionChanged(report: end)
        let middle = FieldQueue.Report(before: "alpha", after: " beta")
        _ = queue.step(report: middle, elapsedMs: 33)
        #expect(queue.hasUnverifiedSelection)
        _ = queue.step(report: middle, elapsedMs: 50)
        #expect(!queue.hasUnverifiedSelection)
    }
    @Test func staleExternalTextRemainsUnknownUntilAnIntentionalKeyHasFreshReadback() {
        var queue = FieldQueue()
        let stale = FieldQueue.Report(before: "Le")
        _ = queue.step(report: stale, elapsedMs: 200)
        queue.externalContextChanged(report: stale)
        queue.enqueue(FieldQueue.Edit(kind: .magic, before: "Le", target: "LE"))
        for _ in 0..<20 { #expect(queue.step(report: stale, elapsedMs: 100) == .idle) }
        #expect(queue.hasUnverifiedContext && queue.hasUnverifiedInput)
        #expect(!queue.hasUnverifiedSelection)
        queue.enqueue(.insert("."))
        #expect(queue.step(report: stale, elapsedMs: 33) == .send(.insert(".")))
        let fresh = FieldQueue.Report(before: "Legato external synthetic text.")
        _ = queue.step(report: fresh, elapsedMs: 120)
        _ = queue.step(report: fresh, elapsedMs: 50)
        #expect(queue.modelText == fresh.before)
        #expect(!queue.hasUnverifiedInput)
    }

    @Test func anAutomaticClearKeepsItsOriginThroughTheHostTransit() {
        var rig = QueueRig(FakeField("um"), config: .init(animated: true))
        rig.queue.enqueue(FieldQueue.Edit(kind: .magic, before: "um", target: "", cursorAtEnd: false, paced: true))
        while !rig.field.string.isEmpty, rig.clockMs < 5_000 { rig.tick() }
        #expect(rig.field.string.isEmpty)
        #expect(rig.queue.ownsEmptyReport)
        rig.run(ms: FieldQueue.transitMs + 100)
        #expect(!rig.queue.ownsEmptyReport)
    }

    @Test func aDeliberateUserClearIsNotAnAutomaticEmptyReport() {
        var rig = QueueRig(FakeField("a"))
        rig.queue.enqueue(.deleteBackward)
        do { let drained = rig.drain(); #expect(drained) }
        #expect(rig.field.string.isEmpty)
        #expect(!rig.queue.ownsEmptyReport)
    }

}
