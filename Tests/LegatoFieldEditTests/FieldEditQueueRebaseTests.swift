import Foundation
import Testing
import LegatoFieldEdit

@Suite struct FieldEditQueueRebaseTests {
    let v0 = FieldVersion(0)

    // MARK: Rebase table

    @Test func pendingEditAfterAForeignChangeShifts() throws {
        var field = "Send teh report now"
        var queue = macQueue(field)
        let fix = EditTransaction(origin: .agent, owner: "run", base: v0, steps: [replace(5, "teh", with: "the")])
        queue.submit(fix)
        queue.hostEdit(&field, to: "Oh, Send teh report now")
        let writes = queue.drain(&field)
        #expect(writes.map(\.steps) == [[replace(9, "teh", with: "the")]])
        #expect(field == "Oh, Send the report now")
        #expect(queue.takeEvents() == [.applied(fix.id, version: try #require(writes.first).version)])
    }

    @Test func pendingEditBeforeAForeignChangeIsUnchanged() {
        var field = "Send teh report now"
        var queue = macQueue(field)
        queue.submit(EditTransaction(origin: .agent, owner: "run", base: v0, steps: [replace(5, "teh", with: "the")]))
        queue.hostEdit(&field, to: "Send teh report now, please")
        let writes = queue.drain(&field)
        #expect(writes.map(\.steps) == [[replace(5, "teh", with: "the")]])
        #expect(field == "Send the report now, please")
    }

    @Test func pendingEditInsideAUserChangeConflictsWithANote() {
        var field = "Send teh report now"
        var queue = macQueue(field)
        let fix = EditTransaction(origin: .agent, owner: "run", base: v0, steps: [replace(5, "teh", with: "the")])
        queue.submit(fix)
        queue.hostEdit(&field, to: "Send tha report now")
        #expect(queue.drain(&field).isEmpty)
        let conflict = Conflict(.overlap, intervening: replace(6, "eh", with: "ha"), byUser: true)
        #expect(conflict.note == Conflict.userNote)
        #expect(queue.takeEvents() == [.conflict(fix.id, conflict)])
        #expect(field == "Send tha report now")
    }

    @Test func staleSubmissionIsMappedThroughWhatLandedSinceItsBase() {
        var field = "Send teh report now"
        var queue = macQueue(field)
        queue.hostEdit(&field, to: "Oh, Send teh report now")
        queue.submit(EditTransaction(origin: .agent, owner: "run", base: v0, steps: [replace(5, "teh", with: "the")]))
        #expect(queue.drain(&field).map(\.steps) == [[replace(9, "teh", with: "the")]])
    }

    // MARK: Bias, deleted ranges, guards

    @Test(arguments: [(EditOrigin.agent, 5), (.liveCleanup, 5), (.hold, 5), (.asr, 11)])
    func insertAtAForeignInsertKeepsItsOriginsBias(_ origin: EditOrigin, _ location: Int) {
        var field = "hello"
        var queue = macQueue(field)
        queue.submit(EditTransaction(origin: origin, owner: "run", base: v0, steps: [.insert("!", at: 5)]))
        queue.hostEdit(&field, to: "hello world")
        #expect(queue.drain(&field).map(\.steps) == [[.insert("!", at: location)]])
    }

    @Test func insertInsideADeletedRangeConflicts() {
        var field = "Send teh report"
        var queue = macQueue(field)
        let insert = EditTransaction(origin: .agent, owner: "run", base: v0, steps: [.insert("x", at: 7)])
        queue.submit(insert)
        queue.hostEdit(&field, to: "Send the report")
        #expect(queue.drain(&field).isEmpty)
        #expect(queue.takeEvents() == [.conflict(insert.id, Conflict(.overlap, intervening: replace(6, "eh", with: "he"), byUser: true))])
    }

    @Test func expectedTextIsAGuardNotASearch() {
        var field = "Send teh report, teh end"
        var queue = macQueue(field)
        let fix = EditTransaction(origin: .agent, owner: "run", base: v0, steps: [replace(0, "teh", with: "the")])
        queue.submit(fix)
        #expect(queue.drain(&field).isEmpty)
        #expect(queue.takeEvents() == [.conflict(fix.id, Conflict(.expectMismatch))])
        #expect(field == "Send teh report, teh end")
    }

    @Test func stepOutsideTheWindowIsNeverWritten() {
        var field = "short"
        var queue = macQueue(field)
        let far = EditTransaction(origin: .agent, base: v0, steps: [.insert("x", at: 40)])
        queue.submit(far)
        #expect(queue.drain(&field).isEmpty)
        #expect(queue.takeEvents() == [.conflict(far.id, Conflict(.outOfWindow))])
    }

    // MARK: Ownership

    @Test func userChangeInsideOwnedTextTaintsThatSubRange() throws {
        var field = ""
        var queue = macQueue(field)
        queue.submit(EditTransaction(origin: .asr, owner: "run", base: v0, steps: [.insert("teh report", at: 0)]))
        queue.drain(&field)
        queue.hostEdit(&field, to: "tex report", caret: 3)
        #expect(queue.document.tainted == [Span(location: 2, length: 1)])
        _ = queue.takeEvents()

        let base = queue.document.version
        let word = EditTransaction(origin: .agent, owner: "run", base: base, steps: [replace(0, "tex", with: "the")])
        let other = EditTransaction(origin: .agent, owner: "run", base: base, steps: [replace(4, "report", with: "Report")])
        queue.submit(word)
        queue.submit(other)
        let writes = queue.drain(&field)
        #expect(writes.map(\.id) == [other.id])
        #expect(field == "tex Report")
        let events = queue.takeEvents()
        #expect(events.first == .conflict(word.id, Conflict(.ownerTainted, byUser: true)))
        #expect(events.dropFirst() == [.applied(other.id, version: try #require(writes.first).version)])
    }

    @Test func typingAfterARunsEndDoesNotTaintIt() {
        var field = ""
        var queue = macQueue(field)
        queue.submit(EditTransaction(origin: .asr, owner: "run", base: v0, steps: [.insert("teh report", at: 0)]))
        queue.drain(&field)
        queue.hostEdit(&field, to: "teh report ok")
        #expect(queue.document.tainted.isEmpty)
        queue.submit(EditTransaction(origin: .agent, owner: "run", base: queue.document.version, steps: [replace(0, "teh", with: "the")]))
        #expect(queue.drain(&field).count == 1)
        #expect(field == "the report ok")
    }

    @Test func sameOwnerOverlapSupersedesWithoutANote() throws {
        var field = "hello wor"
        var queue = macQueue(field)
        let cleanup = EditTransaction(origin: .agent, owner: "run", base: v0, steps: [replace(6, "wor", with: "war")])
        let revision = EditTransaction(origin: .asr, owner: "run", base: v0, steps: [replace(6, "wor", with: "world")])
        queue.submit(cleanup)
        queue.submit(revision)
        let writes = queue.drain(&field)
        #expect(writes.map(\.id) == [revision.id])
        #expect(field == "hello world")
        #expect(queue.takeEvents() == [.superseded(cleanup.id, by: revision.id), .applied(revision.id, version: try #require(writes.first).version)])
    }

    @Test func otherOwnerOverlapConflictsWithoutANote() {
        var field = "hello wor"
        var queue = macQueue(field)
        let cleanup = EditTransaction(origin: .agent, owner: "agent", base: v0, steps: [replace(6, "wor", with: "war")])
        let revision = EditTransaction(origin: .asr, owner: "run", base: v0, steps: [replace(6, "wor", with: "world")])
        queue.submit(cleanup)
        queue.submit(revision)
        queue.drain(&field)
        let conflict = Conflict(.overlap, intervening: replace(6, "wor", with: "world"))
        #expect(conflict.note == nil)
        #expect(queue.takeEvents().first == .conflict(cleanup.id, conflict))
    }
}
