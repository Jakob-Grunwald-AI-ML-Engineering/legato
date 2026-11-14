import Testing
@testable import LegatoKeyboardCore

@Suite struct CleanupStallTests {
    @Test(arguments: [UInt64(7), 19, 42])
    func automaticCleanupLandsWithDelayedOptimisticHostReports(seed: UInt64) {
        var field = FakeField("")
        field.hostDelays = true
        field.rng = SeededGenerator(seed: seed)
        var rig = QueueRig(field, config: .init(animated: true, deleteConfirmationMs: FieldQueue.transitMs))
        rig.queue.enqueue(snap(1, "Check the memo, um, Signal message?"))
        let rawLanded = rig.drain()
        #expect(rawLanded)
        let before = rig.sent.count
        rig.queue.enqueue(snap(2, "Check the memo, Signal message?", complete: true))
        let cleanupLanded = rig.drain()
        #expect(cleanupLanded)
        #expect(rig.field.string == "Check the memo, Signal message?")
        #expect(rig.field.reorders == 0)
        let deleted = rig.sent[before...].reduce(0) { count, sent in
            if case .deleteBackward(let n) = sent.op { count + n } else { count }
        }
        // Four filler characters and at most the existing final-caret reveal. The suffix stays untouched.
        #expect(deleted <= 5)
    }

    private func waitingQueue() -> FieldQueue {
        var queue = FieldQueue(config: .init(animated: false, canReadAround: true))
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

    @Test func anOptimisticAutomaticDeleteDoesNotReleaseTheNextEditBeforeHostSettlement() throws {
        var queue = FieldQueue(config: .init(animated: false, deleteConfirmationMs: FieldQueue.transitMs))
        var report = FieldQueue.Report(before: "The red cat sat")
        _ = queue.step(report: report, elapsedMs: 0)
        queue.enqueue(.init(kind: .magic, before: report.before, target: "The cat sat", cursorAtEnd: false))
        var deleted = false
        for _ in 0..<100 {
            let action = queue.step(report: report, elapsedMs: 33)
            if case .send(let op) = action {
                let result = ShadowEditPlanner.simulate(ops: [op], shadow: report.before + report.after, cursor: report.before.utf16.count)
                report = .init(before: String(result.text.prefix(result.cursor)), after: String(result.text.dropFirst(result.cursor)))
                queue.operationDispatched()
                if case .deleteBackward = op { deleted = true; break }
            }
        }
        #expect(deleted)
        _ = queue.drainEvents()
        #expect(queue.step(report: report, elapsedMs: 8) == .wait)
        #expect(queue.hasOpInFlight)
        #expect(!queue.drainEvents().contains { if case .confirmed = $0 { true } else { false } })
        _ = queue.step(report: report, elapsedMs: FieldQueue.transitMs)
        #expect(queue.drainEvents().contains { if case .confirmed = $0 { true } else { false } })
    }
}
