import Foundation
import Testing
@testable import LegatoKeyboardCore

/// A failed stream chunk is typed again at most once, never while the field shows its text, and never into a
/// field that was cleared (a send, or a read that shows nothing): the "hi there there there there" repeat.
struct HostWriteLedgerRetypeTests {
    func cursor(_ committed: Int, run: String = "run") -> AppliedCursor {
        var cursor = AppliedCursor(runID: run, documentID: "doc")
        cursor.committedCount = committed
        return cursor
    }

    /// "hi" then " there" fails (an empty read past both waits): rewound once; its retype fails the same way:
    /// not rewound again, the progress stays.
    @Test func aChunkIsRewoundOnceNeverForItsRetype() {
        var ledger = HostWriteLedger()
        let first = UUID(), retype = UUID()
        ledger.record(first, previous: cursor(2), planned: cursor(8), expected: "hi there")
        #expect(ledger.failed(first, cursor: cursor(8), contextBefore: "hi") == .init(cursor: cursor(2), withdraw: []))
        ledger.record(retype, previous: cursor(2), planned: cursor(8), expected: "hi there")
        let again = ledger.failed(retype, cursor: cursor(8), contextBefore: "hi")
        #expect(again?.cursor == cursor(8))
        #expect(again?.kept == .retypedOnce)
        #expect(ledger.isEmpty)
    }

    /// The failed chunk's text is in the field after all (the host showed it late): it is not typed again.
    @Test func aChunkWhoseTextTheFieldShowsIsNotRewound() {
        var ledger = HostWriteLedger()
        let a = UUID()
        ledger.record(a, previous: cursor(2), planned: cursor(8), expected: "hi there")
        let failure = ledger.failed(a, cursor: cursor(8), contextBefore: "well, hi there")
        #expect(failure?.cursor == cursor(8))
        #expect(failure?.kept == .shown)
        #expect(ledger.isEmpty)
    }

    /// Only the whole text the write leaves counts: "hi" ending in the chunk's own text is not "hi there".
    @Test func aFieldEndingInTheChunkAloneIsNotItsText() {
        var ledger = HostWriteLedger()
        let a = UUID()
        ledger.record(a, previous: cursor(8), planned: cursor(14), expected: "hi there there")
        #expect(ledger.failed(a, cursor: cursor(14), contextBefore: "hi there") == .init(cursor: cursor(8), withdraw: []))
    }

    /// A cleared field (sent, or a read that shows nothing) is a run boundary, not a failed write: nothing is typed
    /// again into it, and the later writes planned on top are not withdrawn for a retype.
    @Test func aClearedFieldIsABoundaryNotAFailedWrite() {
        var ledger = HostWriteLedger()
        let a = UUID(), b = UUID()
        ledger.record(a, previous: cursor(2), planned: cursor(8), expected: "hi there")
        ledger.record(b, previous: cursor(8), planned: cursor(12), expected: "hi there you")
        let failure = ledger.failed(a, cursor: cursor(12), contextBefore: "", fieldEmpty: true)
        #expect(failure?.cursor == cursor(12))
        #expect(failure?.withdraw == [])
        #expect(failure?.kept == .cleared)
        // The write on top fails the same way (the queue reset): nothing moves.
        #expect(ledger.failed(b, cursor: cursor(12), contextBefore: "", fieldEmpty: true)?.cursor == cursor(12))
        #expect(ledger.isEmpty)
    }

    /// Another chunk failing later (a different point of the run) is rewound as usual.
    @Test func aLaterChunkFailingIsRewoundAsUsual() {
        var ledger = HostWriteLedger()
        let a = UUID(), b = UUID()
        ledger.record(a, previous: cursor(2), planned: cursor(8), expected: "hi there")
        #expect(ledger.failed(a, cursor: cursor(8), contextBefore: "hi")?.cursor == cursor(2))
        ledger.record(b, previous: cursor(8), planned: cursor(12), expected: "hi there you")
        #expect(ledger.failed(b, cursor: cursor(12), contextBefore: "hi there") == .init(cursor: cursor(8), withdraw: []))
    }

    /// The run's first chunk into an empty field is dropped by the host: the field reads empty because the write
    /// never landed, not because it was cleared. It is rewound and typed again (no " world" without "Hello").
    @Test func anEmptyFieldThatHeldNoTextBeforeTheWriteIsAFailedWrite() {
        var ledger = HostWriteLedger()
        let hello = UUID(), world = UUID()
        ledger.record(hello, previous: cursor(0), planned: cursor(5), expected: "Hello", fieldHadText: false)
        ledger.record(world, previous: cursor(5), planned: cursor(11), expected: "Hello world", fieldHadText: false)
        let failure = ledger.failed(hello, cursor: cursor(11), contextBefore: "", fieldEmpty: true)
        #expect(failure?.cursor == cursor(0))
        #expect(failure?.kept == nil)
        #expect(failure?.withdraw == [world])
    }

    /// ClearWatch saw the host empty the field (a send): then an empty read is the clear, also for a write that
    /// went into an empty field.
    @Test func aClearSeenByClearWatchKeepsAWriteIntoAnEmptyField() {
        var ledger = HostWriteLedger()
        let hello = UUID()
        ledger.record(hello, previous: cursor(0), planned: cursor(5), expected: "Hello", fieldHadText: false)
        ledger.fieldCleared()
        let failure = ledger.failed(hello, cursor: cursor(5), contextBefore: "", fieldEmpty: true)
        #expect(failure?.cursor == cursor(5))
        #expect(failure?.kept == .cleared)
    }
}
