import Testing
@testable import LegatoKeyboardCore

@Suite struct CleanupStallTests {
    @Test(arguments: [UInt64(7), 19, 42])
    func automaticCleanupLandsWithDelayedOptimisticHostReports(seed: UInt64) {
        var field = FakeField("")
        field.hostDelays = true
        field.rng = SeededGenerator(seed: seed)
        var rig = QueueRig(field, config: .init())
        rig.queue.enqueue(snap(1, "Check the memo, um, Signal message?"))
        let rawLanded = rig.drain()
        #expect(rawLanded)
        let before = rig.sent.count
        rig.queue.enqueue(snap(2, "Check the memo, Signal message?", complete: true))
        let cleanupLanded = rig.drain()
        #expect(cleanupLanded)
        #expect(rig.field.string == "Check the memo, Signal message?")
        #expect(rig.field.reorders == 0)
        // Only the filler changes, in one chunk: a hop to it, one delete run, the hop back.
        #expect(rig.sent[before...].map(\.op) == [.move(-15), .deleteBackward(4), .move(15)])
    }

    private func interruptedCleanup(seed: UInt64) throws -> QueueRig {
        let prefix = "Keep this note. "
        let raw = "the meeting starts soon"
        var field = FakeField(prefix)
        field.hostDelays = true
        field.rng = SeededGenerator(seed: seed)
        var rig = QueueRig(field, config: .init())
        rig.queue.enqueue(snap(1, raw))
        let rawLanded = rig.drain()
        #expect(rawLanded)
        // This correction requires an insertion, so the tap races a real minimal edit already on its way.
        rig.queue.enqueue(snap(2, "the meeting starts very soon", complete: true))
        var sawIssuedInsert = false
        for _ in 0..<500 {
            let count = rig.sent.count
            rig.tick()
            if rig.sent.dropFirst(count).contains(where: { if case .insert = $0.op { true } else { false } }) {
                sawIssuedInsert = true
                break
            }
        }
        try #require(sawIssuedInsert)
        rig.field.tap(at: 9)
        rig.queue.paused = true
        rig.run(ms: 400)
        // A bounded recovery read may restore BEFORE the stray character, as in native Safari.
        rig.field.tap(at: 9)
        rig.run(ms: 250)
        rig.queue.paused = false
        return rig
    }

    @Test(arguments: [UInt64(7), 19, 42])
    func aTapAndRecoveryReadOnTheOtherSideOfAnIssuedInsertPreserveTheUnrelatedPrefix(seed: UInt64) throws {
        var rig = try interruptedCleanup(seed: seed)
        let finished = rig.drain()
        #expect(finished)
        // The in-flight letter may land at the tap. Neither the unrelated prefix nor the already-spoken letters
        // can be deleted during recovery; the source words must still occur once.
        let original = zip(rig.field.text, rig.field.origin).filter { $0.1 == .initial || $0.1 == .live }.map(\.0)
        #expect(String(original) == "Keep this note. the meeting starts soon")
        #expect(rig.field.string.hasPrefix("Keep this"))
        #expect(rig.field.string.components(separatedBy: "the meeting starts").count == 2)
        #expect(rig.field.string.components(separatedBy: "soon").count == 2)
        #expect(rig.field.string.hasSuffix("the meeting starts very soon") || rig.drops.contains { $0.runID == "r" })
        #expect(!rig.field.deletions.contains { $0.origin == .initial && $0.by != .outside })
    }

    @Test func missingOwnershipWindowsReleaseWaitingTypingWithAnExplicitUnresolvedFailure() throws {
        var rig = try interruptedCleanup(seed: 7)
        rig.field.window = 0
        let requested = rig.clockMs
        rig.queue.enqueue(.insert("Q"))
        rig.run(ms: 3_000)
        let key = rig.sent.first { $0.ms >= requested && $0.op == .insert("Q") }
        #expect(key != nil)
        #expect((key?.ms ?? .infinity) - requested <= FieldQueue.checkDeadlineMs + rig.tickMs)
        #expect(rig.drops.contains { $0.id.hasPrefix("stray:") && $0.reason == .unplaceable })
        #expect(!rig.field.deletions.contains { $0.origin == .initial && $0.by != .outside })
        // The key and stray failure are already released. The remaining minimal correction is behind a seam: explored,
        // found again or dropped; it must also terminate without ownership evidence.
        let finished = rig.drain(limitMs: 2 * FieldRecovery.budgetMs + FieldQueue.checkDeadlineMs + rig.tickMs)
        #expect(finished)
        let original = zip(rig.field.text, rig.field.origin).filter { $0.1 == .initial || $0.1 == .live }.map(\.0)
        #expect(String(original) == "Keep this note. the meeting starts soon")
        #expect(rig.queue.isIdle, "\(rig.queue.debugState) \(rig.field.string.debugDescription) \(rig.events.suffix(40).map { "\($0.event)" })")
    }

    private func waitingQueue() -> FieldQueue {
        var queue = FieldQueue(config: .init(canReadAround: true))
        _ = queue.step(report: .init(before: "Another paragraph. "), elapsedMs: 0)
        queue.enqueue(.init(id: "rewrite", kind: .magic, before: "Keep intro. Meet at three pm. Keep closing.",
                            target: "Keep intro. Meet at four pm. Keep closing.", cursorAtEnd: false))
        for _ in 0..<20 { _ = queue.step(report: .init(before: "Another paragraph. "), elapsedMs: 33) }
        return queue
    }

    @Test func anOrphanedRecoveryTerminatesWithAFailureInsteadOfHoldingTheWriterForever() throws {
        var queue = waitingQueue()
        _ = try #require(queue.recoveryRequest)
        #expect(!queue.hasOpInFlight && queue.isHome)
        _ = queue.drainEvents()
        for _ in 0..<200 { _ = queue.step(report: .init(before: "Another paragraph. "), elapsedMs: 33) }
        #expect(queue.recoveryRequest == nil)
        #expect(queue.isIdle)
        let events = queue.drainEvents()
        #expect(events.contains(.resync(.recoveryRefused)))
        #expect(events.contains { if case .dropped(let drop) = $0 { drop.id == "rewrite" && drop.reason == .unplaceable } else { false } })
        queue.enqueue(.insert("X"))
        #expect(queue.step(report: .init(before: "Another paragraph. "), elapsedMs: 33) == .send(.insert("X")))
    }

    @Test func aSupersededRecoveryReplyCannotFinishTheReplacementAndItStillHasABound() throws {
        var queue = waitingQueue()
        let first = try #require(queue.recoveryRequest)
        queue.deferRecovery(first)
        for _ in 0..<30 { _ = queue.step(report: .init(before: "Another paragraph. "), elapsedMs: 33) }
        let replacement = try #require(queue.recoveryRequest)
        #expect(replacement.id != first.id)
        queue.completeRecovery(first, report: .init(before: "old read"), restored: true)
        #expect(queue.recoveryRequest == replacement)
        for _ in 0..<200 { _ = queue.step(report: .init(before: "Another paragraph. "), elapsedMs: 33) }
        #expect(queue.recoveryRequest == nil && queue.isIdle)
    }
}
