import Testing
@testable import LegatoKeyboardCore

@Suite struct FieldQueueVerifiedRevisionTests {
    @Test func partialHeadWordsKeepGrowingAfterAnEarlierRevision() {
        var rig = QueueRig(FakeField(""), config: .init(prioritizeSpeech: true))
        rig.queue.enqueue(snap(1, "We found the green boat. Als"))
        let firstPartialDelivered = rig.drain()
        #expect(firstPartialDelivered)
        rig.queue.enqueue(snap(2, "We found the grey boat. Also, som"))
        let firstWordCompleted = rig.drain()
        #expect(firstWordCompleted)
        #expect(rig.field.string == "We found the green boat. Also, som")
        rig.queue.enqueue(snap(3, "We found the grey boat. Also, sometimes it rains."))
        let secondWordCompleted = rig.drain()
        #expect(secondWordCompleted)
        #expect(rig.field.string == "We found the green boat. Also, sometimes it rains.")
        rig.queue.enqueue(snap(4, "We found the grey boat. Also, sometimes it rains.", complete: true))
        let finalTextSettled = rig.drain()
        #expect(finalTextSettled)
        #expect(rig.field.string == "We found the grey boat. Also, sometimes it rains.")
    }

    @Test func farRevisionWaitsForTheRoutePauseThenChangesOnlyItsOwnLetters() {
        var rig = QueueRig(FakeField(""), config: .init(prioritizeSpeech: true))
        let tail = " while the rest of the unchanged sentence continues all the way to the harbour"
        rig.queue.enqueue(snap(1, "the cat waits" + tail)); do { let drained = rig.drain(); #expect(drained) }
        rig.queue.enqueue(snap(2, "the dog waits" + tail)); do { let drained = rig.drain(); #expect(drained) }
        #expect(rig.field.string == "the cat waits" + tail)
        let from = rig.sent.count
        rig.queue.setSpeaking(false, runID: "r")
        do { let drained = rig.drain(); #expect(drained) }
        #expect(rig.field.string == "the dog waits" + tail)
        // One chunk: a hop to "cat", one delete run, one insert, the hop back.
        let edits = rig.sent[from...].map(\.op)
        #expect(edits.filter { if case .deleteBackward = $0 { true } else { false } } == [.deleteBackward(3)])
        #expect(edits.filter { if case .insert = $0 { true } else { false } } == [.insert("dog")])
    }

    @Test func typingAfterTheTakeDoesNotFreezeUnchangedWords() {
        var rig = QueueRig(FakeField(""), config: .init(prioritizeSpeech: true))
        rig.queue.enqueue(snap(1, "the cat waits")); do { let drained = rig.drain(); #expect(drained) }
        rig.queue.enqueue(.insert("!")); do { let drained = rig.drain(); #expect(drained) }
        rig.queue.enqueue(snap(2, "the dog waits", complete: true)); do { let drained = rig.drain(); #expect(drained) }
        #expect(rig.field.string == "the dog waits!")
    }

    @Test func theUsersChangedWordWinsWhileAnotherWordIsCorrected() {
        var rig = QueueRig(FakeField(""), config: .init(prioritizeSpeech: true))
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
        var rig = QueueRig(field, config: .init(prioritizeSpeech: true))
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
        #expect((key?.ms ?? .infinity) - start < FieldEditCoordinator.inputResponseTargetMs)
        rig.queue.setSpeaking(false, runID: "r"); do { let drained = rig.drain(); #expect(drained) }
        #expect(rig.field.string.filter { $0 == "!" }.count == 1)
        #expect(rig.field.string.contains("the unchanged words keep going"))
    }

    @Test(arguments: [false, true], [false, true])
    func quietRawSpeechTailPreemptsPacedCleanupWithoutLosingTheUsersSpace(cleanupAlreadyEditing: Bool, completeTail: Bool) throws {
        let prefix = "Protected note. "
        let spoken = Array(repeating: "the old boat waits near the harbour", count: 3).joined(separator: " ")
        var field = FakeField(prefix); field.hostDelays = true
        field.rng = SeededGenerator(seed: 7)
        var rig = QueueRig(field, config: .init(prioritizeSpeech: true))
        rig.tickMs = 8
        rig.queue.enqueue(snap(1, spoken))
        let initial = rig.drain(); #expect(initial)
        rig.queue.enqueue(.insert(" "))
        let keyed = rig.drain(); #expect(keyed)
        let cleanup = FieldQueue.Edit(id: "pause-cleanup", kind: .magic, before: spoken,
                                      target: spoken.capitalized, cursorAtEnd: false)
        func isDelete(_ op: ShadowOp) -> Bool { if case .deleteBackward = op { true } else { false } }
        func isTail(_ op: ShadowOp) -> Bool { if case .insert(let s) = op { s.contains("corrected") } else { false } }
        let speechAt: Double
        if cleanupAlreadyEditing {
            rig.queue.setSpeaking(false, runID: "r")
            rig.queue.enqueue(cleanup)
            let start = rig.sent.count
            while !rig.sent.dropFirst(start).contains(where: { isDelete($0.op) }), rig.clockMs < 20_000 { rig.tick() }
            try #require(rig.sent.dropFirst(start).contains { isDelete($0.op) })
            speechAt = rig.clockMs
            rig.queue.enqueue(snap(2, spoken + " corrected.", complete: completeTail))
        } else {
            speechAt = rig.clockMs
            rig.queue.enqueue(snap(2, spoken + " corrected.", complete: completeTail))
            let start = rig.sent.count
            while !rig.sent.dropFirst(start).contains(where: { isTail($0.op) }), rig.clockMs < 20_000 { rig.tick() }
            try #require(rig.sent.dropFirst(start).contains { isTail($0.op) })
            rig.queue.setSpeaking(false, runID: "r")
            rig.queue.enqueue(cleanup)
        }
        // The speech goes in behind the running chunk only: within the input budget, whole.
        var visibleAt: Double?
        while rig.clockMs - speechAt < FieldEditCoordinator.inputResponseTargetMs + FieldQueue.checkDeadlineMs {
            if rig.field.string.hasSuffix(" corrected.") { visibleAt = rig.clockMs; break }
            rig.tick()
        }
        let tail = rig.sent.first { $0.ms >= speechAt && isTail($0.op) }
        #expect(tail != nil)
        #expect((tail?.ms ?? .infinity) - speechAt < FieldEditCoordinator.inputResponseTargetMs)
        #expect((visibleAt ?? .infinity) - speechAt < FieldEditCoordinator.inputResponseTargetMs)
        let finished = rig.drain(); #expect(finished)
        #expect(rig.field.string == prefix + spoken.capitalized + " corrected.")
        #expect(String(zip(rig.field.text, rig.field.origin).filter { $0.1 == .user }.map(\.0)) == " ")
        #expect(!rig.field.deletions.contains { $0.origin == .initial && $0.by != .outside })
        #expect(rig.field.caret == rig.field.userCaret)
        // The complete take can retain the existing notice that the user's Space changed its field context.
        #expect(rig.drops.allSatisfy { $0.runID == "r" && $0.reason == .userEdited })
    }

    @Test func newRawWordsPreemptAPartialRevisionWithoutReplayingItsDeletedLetters() throws {
        var field = FakeField(""); field.hostDelays = true
        field.rng = SeededGenerator(seed: 7)
        var rig = QueueRig(field, config: .init(prioritizeSpeech: true))
        rig.tickMs = 8
        let old = "the red boat waits at the harbour"
        let revised = "the blue boat waits at the harbour"
        rig.queue.enqueue(snap(1, old)); let initial = rig.drain(); #expect(initial)
        rig.queue.enqueue(snap(2, revised)); rig.queue.setSpeaking(false, runID: "r")
        let edits = rig.sent.count
        func isDelete(_ op: ShadowOp) -> Bool { if case .deleteBackward = op { true } else { false } }
        while !rig.sent.dropFirst(edits).contains(where: { isDelete($0.op) }), rig.clockMs < 10_000 { rig.tick() }
        try #require(rig.sent.dropFirst(edits).contains { isDelete($0.op) })
        let requested = rig.clockMs
        rig.queue.enqueue(snap(3, revised + " now"))
        rig.run(ms: FieldEditCoordinator.inputResponseTargetMs)
        let word = rig.sent.first { if $0.ms >= requested, case .insert(let s) = $0.op { s.contains("now") } else { false } }
        #expect(word != nil)
        #expect((word?.ms ?? .infinity) - requested < FieldEditCoordinator.inputResponseTargetMs)
        #expect(rig.field.string.hasSuffix(" now"))
        let finished = rig.drain(); #expect(finished)
        #expect(rig.field.string == revised + " now")
        #expect(rig.field.caret == rig.field.userCaret)
        #expect(rig.drops.isEmpty)
    }

    @Test func identicalOpaqueSelectionWindowsNeverTriggerAnAutomaticMove() {
        var queue = FieldQueue(config: .init())
        let old = FieldQueue.Report(before: "a complete selected draft")
        _ = queue.step(report: old, elapsedMs: 200)
        queue.observe(old, callback: .selection)
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

    /// A report that differs from the one the hold was set on shows where the caret is: the observer takes it.
    @Test func anIndependentlyChangedWindowResolvesOpaqueCaretEvidence() {
        var queue = FieldQueue()
        let end = FieldQueue.Report(before: "alpha beta")
        _ = queue.step(report: end, elapsedMs: 200)
        queue.observe(end, callback: .selection)
        #expect(queue.hasUnverifiedSelection)
        _ = queue.step(report: end, elapsedMs: 50)
        #expect(queue.hasUnverifiedSelection)
        let middle = FieldQueue.Report(before: "alpha", after: " beta")
        _ = queue.step(report: middle, elapsedMs: 33)
        #expect(!queue.hasUnverifiedSelection)
    }
    @Test func staleExternalTextRemainsUnknownUntilAnIntentionalKeyHasFreshReadback() {
        var queue = FieldQueue()
        let stale = FieldQueue.Report(before: "Le")
        _ = queue.step(report: stale, elapsedMs: 200)
        queue.observe(stale, callback: .text)
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
        var rig = QueueRig(FakeField("um"), config: .init())
        rig.queue.enqueue(FieldQueue.Edit(kind: .magic, before: "um", target: "", cursorAtEnd: false))
        while !rig.field.string.isEmpty, rig.clockMs < 5_000 { rig.tick() }
        #expect(rig.field.string.isEmpty)
        #expect(rig.queue.ownsEmptyReport)
        rig.run(ms: FieldQueue.checkDeadlineMs + 100)
        #expect(!rig.queue.ownsEmptyReport)
    }

    @Test func aDeliberateUserClearIsNotAnAutomaticEmptyReport() {
        var rig = QueueRig(FakeField("a"))
        rig.queue.enqueue(.deleteBackward)
        do { let drained = rig.drain(); #expect(drained) }
        #expect(rig.field.string.isEmpty)
        #expect(!rig.queue.ownsEmptyReport)
    }

    @Test(arguments: [false, true])
    func aConfirmedEmptyNativeFieldAdmitsSpeechWithoutAPrimingKey(selection: Bool) {
        var rig = QueueRig(FakeField(""), config: .init(prioritizeSpeech: true))
        let empty = FieldQueue.Report(before: "")
        _ = rig.queue.step(report: empty, elapsedMs: 200)
        if selection { rig.queue.observe(empty, callback: .selection, hasText: false) }
        else { rig.queue.observe(empty, callback: .text, hasText: false) }
        #expect(!rig.queue.hasUnverifiedInput)
        rig.queue.enqueue(snap(1, "first words", complete: true))
        let drained = rig.drain()
        #expect(drained)
        #expect(rig.field.string == "first words")
    }

    @Test(arguments: [false, true])
    func emptyWindowsWithoutNativeEmptyEvidenceStayUnknown(selection: Bool) {
        let observations: [Bool?] = [nil, true]
        for hasText in observations {
            var queue = FieldQueue()
            let empty = FieldQueue.Report(before: "")
            _ = queue.step(report: empty, elapsedMs: 200)
            if selection { queue.observe(empty, callback: .selection, hasText: hasText) }
            else { queue.observe(empty, callback: .text, hasText: hasText) }
            #expect(queue.hasUnverifiedInput)
        }
        var queue = FieldQueue()
        let nonempty = FieldQueue.Report(before: "a complete selected draft")
        _ = queue.step(report: nonempty, elapsedMs: 200)
        if selection { queue.observe(nonempty, callback: .selection, hasText: false) }
        else { queue.observe(nonempty, callback: .text, hasText: false) }
        #expect(queue.hasUnverifiedInput)
    }

    @Test(arguments: [false, true])
    func aLaterEmptyCallbackDoesNotReleaseAnOlderHeldTake(selection: Bool) {
        var queue = FieldQueue()
        let empty = FieldQueue.Report(before: "")
        _ = queue.step(report: empty, elapsedMs: 200)
        queue.observe(empty, callback: .text)
        queue.enqueue(snap(1, "an older held take", complete: true))
        if selection { queue.observe(empty, callback: .selection, hasText: false) }
        else { queue.observe(empty, callback: .text, hasText: false) }
        #expect(queue.hasUnverifiedInput)
        // The take's words still go in at the caret (plain inserts only); a report that never changes lifts nothing.
        var sent: [ShadowOp] = []
        for _ in 0..<20 {
            guard case .send(let op) = queue.step(report: empty, elapsedMs: 100) else { continue }
            sent.append(op); queue.operationDispatched()
        }
        #expect(sent.first == .insert("an older held take"))
        #expect(sent.allSatisfy { if case .insert = $0 { true } else { false } })
        #expect(queue.hasUnverifiedInput)
    }

    private func justConfirmedMove() -> (FieldQueue, FieldQueue.Report) {
        var queue = FieldQueue()
        let start = FieldQueue.Report(before: "alpha beta")
        _ = queue.step(report: start, elapsedMs: 200)
        queue.enqueue(.move(-4))
        #expect(queue.step(report: start, elapsedMs: 0) == .send(.move(-4)))
        queue.operationDispatched()
        let moved = FieldQueue.Report(before: "alpha ", after: "beta")
        _ = queue.step(report: moved, elapsedMs: 0)
        #expect(!queue.hasOpInFlight)
        #expect(queue.hasRecentOwnOperation)
        return (queue, moved)
    }

    @Test(arguments: [false, true])
    func anIdleWallGapExpiresOwnMoveProvenanceBeforeExternalCallbacks(selection: Bool) {
        var (queue, report) = justConfirmedMove()
        // No step while idle: the in-queue clock is deliberately still at the move.
        #expect(!queue.hasRecentOwnOperation(elapsedMs: 2_000))
        if selection { queue.observe(report, callback: .selection, elapsedSinceLastStepMs: 2_000) }
        else { queue.observe(report, callback: .text, elapsedSinceLastStepMs: 2_000) }
        #expect(queue.hasUnverifiedInput)
        #expect(queue.hasUnverifiedSelection == selection)
        #expect(queue.hasUnverifiedContext == !selection)
    }

    @Test(arguments: [false, true])
    func aCallbackInsideTheDeadlineStillBelongsToTheOwnOperation(selection: Bool) {
        var (queue, report) = justConfirmedMove()
        let withinTransit = FieldQueue.checkDeadlineMs - 1
        #expect(queue.hasRecentOwnOperation(elapsedMs: withinTransit))
        if selection { queue.observe(report, callback: .selection, elapsedSinceLastStepMs: withinTransit) }
        else { queue.observe(report, callback: .text, elapsedSinceLastStepMs: withinTransit) }
        #expect(!queue.hasUnverifiedInput)
        #expect(queue.hasRecentOwnOperation(elapsedMs: -2_000))
    }

    @Test func elapsedWallTimeNeverOverridesAnOutstandingOperationOrReadLease() {
        var queue = FieldQueue()
        let start = FieldQueue.Report(before: "alpha beta")
        _ = queue.step(report: start, elapsedMs: 200)
        queue.enqueue(.move(-4))
        #expect(queue.step(report: start, elapsedMs: 0) == .send(.move(-4)))
        #expect(queue.hasRecentOwnOperation(elapsedMs: 2_000))
        queue.observe(start, callback: .selection, elapsedSinceLastStepMs: 2_000)
        #expect(!queue.hasUnverifiedInput)
        let moved = FieldQueue.Report(before: "alpha ", after: "beta")
        _ = queue.step(report: moved, elapsedMs: 0)
        let acquired = queue.acquireRead()
        #expect(acquired)
        #expect(queue.hasRecentOwnOperation(elapsedMs: 2_000))
        queue.observe(moved, callback: .text, elapsedSinceLastStepMs: 2_000)
        #expect(!queue.hasUnverifiedInput)
    }

}
