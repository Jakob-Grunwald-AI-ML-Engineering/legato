import Testing
@testable import LegatoKeyboardCore

struct FieldEditCoordinatorTests {
    private let start = FieldEditCoordinator.Window(documentID: "field", before: "Original", after: "", endsDocument: true)

    @Test func anIdleDictationPollBetweenReadAndApplyDoesNotInvalidateTheRead() throws {
        var owner = FieldEditCoordinator()
        let revision = owner.observe(start)
        let readValue = owner.begin(owner: .read, id: "read")
        let read = try #require(readValue)
        owner.confirm(read, window: start)
        owner.finish(read, settled: true)
        let idleValue = owner.begin(owner: .dictation, id: "idle-poll")
        let idle = try #require(idleValue)
        // An already settled run has no operation to issue, but the adapter still confirms its current position.
        owner.confirm(idle, window: start)
        owner.finish(idle, settled: true)
        #expect(owner.revision == revision)
        let apply = owner.begin(owner: .instruction, id: "apply", expectedRevision: revision)
        #expect(apply != nil)
    }

    @Test func aLateOwnEchoIsUncertainAndAnExternalChangeEndsItsCausalHistory() throws {
        var owner = FieldEditCoordinator()
        owner.observe(start)
        let value = owner.begin(owner: .instruction, id: "edit")
        let lease = try #require(value)
        let middle = FieldEditCoordinator.Window(documentID: "field", before: "Ori", after: "")
        let final = FieldEditCoordinator.Window(documentID: "field", before: "Rewrite", after: "")
        owner.issued(lease, predicted: middle)
        owner.issued(lease, predicted: final)
        owner.confirm(lease, window: final)
        owner.finish(lease, settled: true)
        let revision = owner.revision
        owner.observe(middle)
        #expect(owner.lastObservation == .staleOwnEcho)
        #expect(owner.revision == revision)
        #expect(owner.uncertain)
        let retry = owner.begin(owner: .instruction, id: "retry")
        #expect(retry == nil)
        owner.observe(.init(documentID: "field", before: "Their text", after: ""))
        #expect(owner.lastObservation == .external)
        #expect(owner.recentPredictions.isEmpty)
        owner.observe(middle)
        #expect(owner.lastObservation == .external, "Equal old text after an external edit is not proof of our echo")
    }

    @Test func staleAndDuplicateTransactionsCannotWrite() throws {
        var owner = FieldEditCoordinator()
        let revision = owner.observe(start)
        let value1 = owner.begin(owner: .instruction, id: "edit", expectedRevision: revision)
        let lease = try #require(value1)
        let value2 = owner.begin(owner: .dictation, id: "run")
        #expect(value2 == nil)
        let value3 = owner.issued(lease, predicted: start)
        #expect(value3)
        let value4 = owner.confirm(lease, window: start)
        #expect(value4)
        owner.finish(lease, settled: true)
        let value5 = owner.begin(owner: .instruction, id: "edit")
        #expect(value5 == nil)
        let value6 = owner.begin(owner: .instruction, id: "late", expectedRevision: revision)
        #expect(value6 == nil)
    }

    @Test func aClaimOfSuccessWithoutObservationRemainsUncertain() throws {
        var owner = FieldEditCoordinator()
        owner.observe(start)
        let value7 = owner.begin(owner: .instruction, id: "edit")
        let lease = try #require(value7)
        owner.issued(lease)
        owner.finish(lease, settled: true)
        #expect(owner.uncertain)
        let value8 = owner.begin(owner: .instruction, id: "retry")
        #expect(value8 == nil)
        let value9 = owner.begin(owner: .read, id: "read")
        let read = try #require(value9)
        owner.issued(read)
        owner.confirm(read, window: start)
        owner.finish(read, settled: true)
        #expect(!owner.uncertain)
    }

    @Test func preemptionInvalidatesLeaseAndPreservesUncertainty() throws {
        var owner = FieldEditCoordinator()
        owner.observe(start)
        let value10 = owner.begin(owner: .instruction, id: "edit")
        let lease = try #require(value10)
        owner.issued(lease, predicted: .init(documentID: "field", before: "Rewrite", after: ""))
        owner.preempt()
        #expect(!owner.owns(lease))
        let value11 = owner.issued(lease)
        #expect(!value11)
        #expect(owner.uncertain)
        #expect(owner.recentPredictions.isEmpty, "User preemption ends attribution of later text to old writes")
    }

    @Test func predictionCannotBeConfirmedInAnotherFieldOrWithDifferentText() throws {
        var owner = FieldEditCoordinator()
        owner.observe(start)
        let value12 = owner.begin(owner: .instruction, id: "edit")
        let lease = try #require(value12)
        owner.issued(lease, predicted: start)
        let value13 = owner.confirm(lease, window: .init(documentID: "other", before: "Original", after: ""))
        #expect(!value13)
        let value14 = owner.confirm(lease, window: .init(documentID: "field", before: "Changed", after: ""))
        #expect(!value14)
        owner.finish(lease, settled: true)
        #expect(owner.uncertain)
    }
}

@Suite struct SharedFieldOperationTests {
    @Test(arguments: [0.0, FieldQueue.moveSettleMs])
    func bothTransportsSerializeAndRequireConfirmedReadback(settle: Double) {
        var coordinator = FieldEditCoordinator.Operations()
        let result1 = coordinator.begin(.move, settleMs: settle, transitMs: 115)
        #expect(result1)
        coordinator.advance(36) // expensive planning before dispatch is not host settlement
        coordinator.dispatched()
        let result2 = !coordinator.begin(.edit)
        #expect(result2)
        let result3 = !coordinator.begin(.read)
        #expect(result3)
        let result4 = !coordinator.confirm(matches: false)
        #expect(result4)
        if settle > 0 {
            coordinator.advance(settle - 1)
            let result5 = !coordinator.confirm(matches: true)
            #expect(result5, "Optimistic proxy reports cannot confirm a move early")
            coordinator.advance(1)
        }
        let result6 = coordinator.confirm(matches: true)
        #expect(result6)
        let result7 = coordinator.begin(.read)
        #expect(result7)
        let result8 = !coordinator.begin(.edit)
        #expect(result8, "A reader owns the cursor, including its restoration")
        coordinator.finishRead()
        let result9 = coordinator.begin(.edit)
        #expect(result9)
    }

    @Test func anUncertainMutationDrainsBeforeAnyOtherOwnerCanMoveTheCursor() {
        var coordinator = FieldEditCoordinator.Operations()
        let result10 = coordinator.begin(.edit, transitMs: 115)
        #expect(result10)
        coordinator.dispatched()
        coordinator.advance(10)
        coordinator.invalidate()
        #expect(!coordinator.available)
        let result11 = !coordinator.begin(.read)
        #expect(result11)
        coordinator.advance(104)
        let result12 = !coordinator.begin(.edit)
        #expect(result12)
        coordinator.advance(1)
        let result13 = coordinator.begin(.read)
        #expect(result13)
        #expect(coordinator.revision == 0, "Timeout did not become a successful edit")
    }

    @Test func aRefusedOperationNeverConsumesTheHostTransitWindow() {
        var coordinator = FieldEditCoordinator.Operations()
        let result14 = coordinator.begin(.edit, transitMs: 1000)
        #expect(result14)
        coordinator.invalidate() // adapter refused; nothing was dispatched
        #expect(coordinator.available)
    }
}
