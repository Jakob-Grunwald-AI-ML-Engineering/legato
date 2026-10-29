import Foundation
import Testing
@testable import LegatoKeyboardCore

/// Where the applied cursor goes when a host-text write through the field edit queue fails.
struct HostWriteLedgerTests {
    func cursor(_ committed: Int, run: String = "run") -> AppliedCursor {
        var cursor = AppliedCursor(runID: run, documentID: "doc")
        cursor.committedCount = committed
        return cursor
    }

    @Test func failedChunkRewindsTheCursorSoItIsRetypedExactlyOnce() {
        var ledger = HostWriteLedger()
        let a = UUID()
        ledger.record(a, previous: cursor(3), planned: cursor(7))
        #expect(ledger.failed(a, cursor: cursor(7)) == HostWriteLedger.Failure(cursor: cursor(3), withdraw: []))
        #expect(ledger.failed(a, cursor: cursor(3)) == nil)  // handed back once only
    }

    @Test func failedChunkWithTheNextTickWaitingRewindsPastBothAndWithdrawsTheTick() {
        var ledger = HostWriteLedger()
        let a = UUID(), b = UUID()
        ledger.record(a, previous: cursor(3), planned: cursor(7))
        ledger.record(b, previous: cursor(7), planned: cursor(11))
        // The tick was planned on top of the failed chunk: both are typed again, together.
        #expect(ledger.failed(a, cursor: cursor(11)) == HostWriteLedger.Failure(cursor: cursor(3), withdraw: [b]))
        #expect(ledger.failed(b, cursor: cursor(3)) == nil)
    }

    @Test func refusedAtOnceLeavesTheCursorWhereItWas() {
        var ledger = HostWriteLedger()
        let a = UUID()
        ledger.record(a, previous: cursor(3), planned: cursor(7))
        // The plan's cursor was never taken.
        #expect(ledger.failed(a, cursor: cursor(3)) == HostWriteLedger.Failure(cursor: cursor(3), withdraw: []))
    }

    @Test func failedRevisionIsMarkedSkippedNotRetried() {
        var ledger = HostWriteLedger()
        let a = UUID()
        let previous = cursor(9)
        var planned = previous
        planned.revisionHandled = 1
        planned.shownRevision = 1
        planned.revisedEnd = 9
        planned.revisedText = "the cat"
        ledger.record(a, previous: previous, planned: planned)
        var expected = previous
        expected.revisionHandled = 1
        expected.revisionSkipped = true
        #expect(ledger.failed(a, cursor: planned) == HostWriteLedger.Failure(cursor: expected, withdraw: []))
    }

    @Test func failedFinalSwapIsMarkedNotReplaced() {
        var ledger = HostWriteLedger()
        let a = UUID()
        var previous = cursor(9)
        previous.finalApplied = true
        var planned = previous
        planned.finalReplaced = true
        ledger.record(a, previous: previous, planned: planned)
        var expected = previous
        expected.finalReplaced = false
        expected.finalApplied = false
        #expect(ledger.failed(a, cursor: planned) == HostWriteLedger.Failure(cursor: expected, withdraw: []))
    }

    @Test func landedWriteIsNeverRewound() {
        var ledger = HostWriteLedger()
        let a = UUID()
        ledger.record(a, previous: cursor(3), planned: cursor(7))
        ledger.landed(a)
        #expect(ledger.failed(a, cursor: cursor(7)) == nil)
        #expect(ledger.isEmpty)
    }

    /// The tentative text taken out before a key (`prepareForTyping`): the volatile part goes, the separator
    /// is due, the final text is not confirmed.
    func prepared(_ cursor: AppliedCursor) -> AppliedCursor {
        var prepared = cursor
        prepared.volatile = ""
        prepared.needsSeparator = true
        prepared.finalApplied = false
        return prepared
    }

    func chunk(_ committed: Int, volatile: String) -> AppliedCursor {
        var c = cursor(committed)
        c.volatile = volatile
        c.finalApplied = true
        return c
    }

    /// A chunk awaits its read; the user-lane write taking out the tentative text runs on top of it. The chunk
    /// fails first, then the prepare write lands: the cursor rewinds the chunk and keeps what the prepare did.
    @Test func prepareWriteLandingAfterTheChunkUnderItFailedKeepsItsChange() {
        var ledger = HostWriteLedger()
        let a = UUID(), p = UUID()
        let before = chunk(3, volatile: " fo"), planned = chunk(7, volatile: " ba")
        ledger.record(a, previous: before, planned: planned)
        ledger.record(p, previous: planned, planned: prepared(planned))
        let failure = ledger.failed(a, cursor: prepared(planned))
        #expect(failure?.cursor == before)
        #expect(ledger.landed(p, cursor: before) == prepared(before))
        #expect(ledger.isEmpty)
    }

    /// The prepare write lands first, then the chunk under it fails: the rewind keeps what the prepare did.
    @Test func chunkFailingUnderALandedPrepareWriteRewindsOnlyTheChunk() {
        var ledger = HostWriteLedger()
        let a = UUID(), p = UUID()
        let before = chunk(3, volatile: " fo"), planned = chunk(7, volatile: " ba")
        ledger.record(a, previous: before, planned: planned)
        ledger.record(p, previous: planned, planned: prepared(planned))
        #expect(ledger.landed(p, cursor: prepared(planned)) == nil)  // nothing to change yet
        #expect(ledger.failed(a, cursor: prepared(planned)) == HostWriteLedger.Failure(cursor: prepared(before), withdraw: []))
        #expect(ledger.isEmpty)
    }

    /// A write on top of a failed one that fails itself, or is withdrawn, changes nothing more.
    @Test func writeOnTopOfAFailedOneThatFailsTooLeavesTheRewind() {
        var ledger = HostWriteLedger()
        let a = UUID(), p = UUID()
        let before = chunk(3, volatile: " fo"), planned = chunk(7, volatile: " ba")
        ledger.record(a, previous: before, planned: planned)
        ledger.record(p, previous: planned, planned: prepared(planned))
        #expect(ledger.failed(a, cursor: prepared(planned))?.cursor == before)
        #expect(ledger.failed(p, cursor: before) == nil)
        #expect(ledger.isEmpty)
    }

    @Test func cursorMovedOnByAnotherRunKeepsItsProgress() {
        var ledger = HostWriteLedger()
        let a = UUID()
        ledger.record(a, previous: cursor(3), planned: cursor(7))
        let other = cursor(2, run: "next")
        #expect(ledger.failed(a, cursor: other) == HostWriteLedger.Failure(cursor: other, withdraw: []))
    }
}
