import Foundation
import Testing
@testable import LegatoKeyboardCore

@Suite struct RequestLedgerTests {
    @Test func aRequestIdIsAdmittedOnce() {
        let ledger = RequestLedger()
        #expect(ledger.admit(id: "req-1"))
        #expect(!ledger.admit(id: "req-1")) // the same id arriving by URL and by Darwin note
        #expect(ledger.admit(id: "req-2"))
        #expect(!ledger.admit(id: "req-2"))
    }

    @Test func aDuplicateRequestObjectIsDroppedToo() {
        let ledger = RequestLedger()
        let request = KeyboardRequest(id: "req-1", command: .start, at: t0)
        #expect(ledger.admit(request, now: t0.addingTimeInterval(0.1)))
        #expect(!ledger.admit(request, now: t0.addingTimeInterval(0.2)))
    }

    @Test func aURLIdAlreadyHandledBlocksTheMatchingInboxRequest() {
        let ledger = RequestLedger()
        #expect(ledger.admit(id: "req-1")) // `legato://keyboard?cmd=start&req=req-1`
        let request = KeyboardRequest(id: "req-1", command: .start, at: t0)
        #expect(!ledger.admit(request, now: t0.addingTimeInterval(0.3)))
    }

    @Test func aStaleRequestLeftInTheInboxIsIgnored() {
        let ledger = RequestLedger()
        let old = KeyboardRequest(id: "req-old", command: .start, at: t0)
        #expect(!ledger.admit(old, now: t0.addingTimeInterval(LinkChannel.requestMaxAge + 1)))
    }

    @Test func theLedgerForgetsTheOldestIdsBeyondItsCapacity() {
        let ledger = RequestLedger(capacity: 2)
        #expect(ledger.admit(id: "a"))
        #expect(ledger.admit(id: "b"))
        #expect(ledger.admit(id: "c")) // evicts "a"
        #expect(!ledger.admit(id: "b"))
        #expect(!ledger.admit(id: "c"))
        #expect(ledger.admit(id: "a"))
    }
}

extension RequestLedgerTests {
    @Test func containsReportsOnlyAdmittedIds() {
        let ledger = RequestLedger()
        #expect(!ledger.contains(id: "req-1"))
        _ = ledger.admit(id: "req-1")
        #expect(ledger.contains(id: "req-1"))
        #expect(!ledger.contains(id: "req-2"))
    }
}
