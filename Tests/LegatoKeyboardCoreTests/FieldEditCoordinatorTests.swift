import Testing
@testable import LegatoKeyboardCore

struct FieldEditCoordinatorTests {
    private let start = FieldEditCoordinator.Window(documentID: "field", before: "Original", after: "", endsDocument: true)

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

    @Test func sameTurnMoveEchoCannotAuthorizeADelete() throws {
        let original = "At the start " + String(repeating: "remaining text ", count: 50)
        let edit = ScopedEdit(instructionID: "i", documentID: "field", before: original, after: "", target: "At the beginning " + String(repeating: "remaining text ", count: 50))
        let plan = try ScopedEditPlanner.plan(edit, windowBefore: original, windowAfter: "", selected: nil).get()
        var queue = ScopedEditQueue(edit, plan: plan, windowBefore: original)
        let first = queue.step(reportedBefore: original, reportedAfter: "", hasSelection: false, elapsedMs: 0)
        guard case .send(let op) = first else { Issue.record("Expected a move"); return }
        guard case .move = op else { Issue.record("Expected a move, got \(op)"); return }
        let (moved, cursor) = ShadowEditPlanner.simulate(ops: [op], shadow: original, cursor: original.utf16.count)
        let units = Array(moved.utf16)
        let before = String(decoding: units[..<cursor], as: UTF16.self)
        let after = String(decoding: units[cursor...], as: UTF16.self)
        let value15 = queue.step(reportedBefore: before, reportedAfter: after, hasSelection: false, elapsedMs: 0)
        #expect(value15 == .wait)
        let value16 = queue.step(reportedBefore: original, reportedAfter: "", hasSelection: false, elapsedMs: 33)
        #expect(value16 == .wait)
    }
}
