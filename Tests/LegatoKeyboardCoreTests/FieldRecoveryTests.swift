import Testing
@testable import LegatoKeyboardCore

@Suite struct FieldRecoveryTests {
    @Test func uniqueUnchangedTargetReplansAndEachRevisionHasOneBoundedAttempt() throws {
        var recovery = FieldRecovery()
        let target = FieldRecovery.Target(id: "owned", expected: "three", before: "Meet at ", after: " pm. Keep")
        let pending = recovery.begin(generation: "field", revision: 7, targets: [target])
        let request = try #require(pending)
        let decisions = recovery.resolve(request, text: "New prefix. Meet at three pm. Keep this closing.",
                                         generation: "field", revision: 7, restored: true)
        guard case .replan(let placement)? = decisions.first else { Issue.record("unchanged target was not recovered"); return }
        #expect(placement.text == "three")
        #expect(placement.range == 20..<25)
        let again = recovery.begin(generation: "field", revision: 7, targets: [target])
        #expect(again == nil)
        let afterInput = recovery.begin(generation: "field", revision: 8, targets: [target])
        #expect(afterInput != nil)
    }

    @Test(arguments: ["Meet at THREE pm. Keep", "Meet at three pm. Keep and Meet at three pm. Keep"])
    func changedAndAmbiguousTargetsStayUntouched(text: String) throws {
        var recovery = FieldRecovery()
        let pending = recovery.begin(generation: "f", revision: 0, targets: [.init(id: "t", expected: "three", before: "Meet at ", after: " pm. Keep")])
        let request = try #require(pending)
        let decisions = recovery.resolve(request, text: text, generation: "f", revision: 0, restored: true)
        #expect(decisions.allSatisfy { if case .stop = $0 { true } else { false } })
    }

    @Test func cancelledOrUnrestoredEvidenceNeverReplans() throws {
        var recovery = FieldRecovery()
        let pending = recovery.begin(generation: "f", revision: 9, targets: [.init(id: "t", expected: "three", before: "Meet at ", after: " pm. Keep")])
        let request = try #require(pending)
        for (generation, revision, restored) in [("other", UInt64(9), true), ("f", UInt64(10), true), ("f", UInt64(9), false)] {
            let decision = recovery.resolve(request, text: "Meet at three pm. Keep", generation: generation, revision: revision, restored: restored)
            #expect(decision.allSatisfy { if case .stop = $0 { true } else { false } })
        }
    }

    @Test func aUniqueWordInAPartialWindowIsNotProofWithoutSurroundingEvidence() throws {
        var recovery = FieldRecovery()
        let pending = recovery.begin(generation: "f", revision: 0, targets: [.init(id: "t", expected: "three")])
        let request = try #require(pending)
        let partial = recovery.resolve(request, text: "three", generation: "f", revision: 0, restored: true)
        #expect(partial == [.stop(id: "t", .uncorroborated)])
        let whole = recovery.resolve(request, text: "three", generation: "f", revision: 0, restored: true, completeDocument: true)
        #expect(whole.contains { if case .replan = $0 { true } else { false } })
    }

    @Test func aLateOperationResultCountsOnlyWhenFreshEvidenceShowsTheWholeResultAndAnchors() throws {
        var recovery = FieldRecovery()
        let pending = recovery.begin(generation: "f", revision: 0, targets: [.init(id: "t", expected: "three", landed: "four", before: "Meet at ", after: " pm. Keep")])
        let request = try #require(pending)
        let decisions = recovery.resolve(request, text: "Meet at four pm. Keep", generation: "f", revision: 0, restored: true)
        guard case .replan(let placement)? = decisions.first else { Issue.record("observed late result was not recovered"); return }
        #expect(placement.text == "four")
        let uncertain = recovery.resolve(request, text: "Meet at fou pm. Keep", generation: "f", revision: 0, restored: true)
        #expect(uncertain == [.stop(id: "t", .changed)])
    }
}

@Suite struct ProxyRecoveryIntegrationTests {
    private func waitingQueue() -> FieldQueue {
        var queue = FieldQueue(config: .init(animated: false, canReadAround: true))
        _ = queue.step(report: .init(before: "At another paragraph. "), elapsedMs: 0)
        queue.enqueue(.init(id: "magic", kind: .magic, before: "Keep intro. Meet at three pm. Keep closing.",
                            target: "Keep intro. Meet at four pm. Keep closing.", cursorAtEnd: false))
        for _ in 0..<20 { _ = queue.step(report: .init(before: "At another paragraph. "), elapsedMs: 33) }
        return queue
    }

    @Test func anUnplaceableProxyEditRequestsEvidenceAndThenReplansItsExactScope() throws {
        var queue = waitingQueue()
        let request = try #require(queue.recoveryRequest)
        #expect(queue.drainEvents().contains(.resync(.recoveryRequested)))
        let prefix = "Keep intro. Meet at three pm. Keep closing.\nAt another paragraph. "
        queue.completeRecovery(request, report: .init(before: prefix), restored: true, completeDocument: true)
        #expect(queue.recoveryRequest == nil)
        #expect(queue.drainEvents().contains(.resync(.recoveryReplanned)))
        var text = prefix, caret = text.utf16.count
        for _ in 0..<300 {
            let before = String(decoding: Array(text.utf16.prefix(caret)), as: UTF16.self)
            let after = String(decoding: Array(text.utf16.dropFirst(caret)), as: UTF16.self)
            let action = queue.step(report: .init(before: before, after: after), elapsedMs: 33)
            if case .send(let op) = action {
                let result = ShadowEditPlanner.simulate(ops: [op], shadow: text, cursor: caret)
                text = result.text; caret = result.cursor
            }
            if queue.isIdle { break }
        }
        #expect(text == "Keep intro. Meet at four pm. Keep closing.\nAt another paragraph. ")
        #expect(caret == text.utf16.count, "Recovery and the exact edit return to the user's cursor")
    }

    @Test func userInputAndFieldResetInvalidateDelayedRecoveryEvidence() throws {
        var queue = waitingQueue()
        let request = try #require(queue.recoveryRequest)
        queue.enqueue(.insert("X"))
        let before = queue.text
        queue.completeRecovery(request, report: .init(before: "Keep intro. Meet at three pm. Keep closing."), restored: true, completeDocument: true)
        #expect(queue.text == before)
        queue.reset()
        queue.completeRecovery(request, report: .init(before: "old field"), restored: true, completeDocument: true)
        #expect(!queue.seeded)
    }
}
