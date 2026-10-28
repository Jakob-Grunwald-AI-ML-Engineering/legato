import Foundation

enum SimulatedBackendError: Error, CaseIterable { case emptyResponse, contextTooLong, guardrail }
func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { print("FAIL: \(message)"); exit(1) }
}

@main struct BackendInvocationLedgerTests {
    static func main() async throws {
        for failure in SimulatedBackendError.allCases {
            let ledger = BackendInvocationLedger()
            do {
                _ = try await ledger.respond(runID: "mixed") { throw failure }
                require(false, "the backend error must propagate for raw fallback")
            } catch let error as SimulatedBackendError { require(error == failure, "the original error must propagate") }
            let reply = try await ledger.respond(runID: "mixed") { "Clean second chunk." }
            require(reply == "Clean second chunk.", "successful later chunk is still returned")
            let summary = ledger.summary(for: "mixed")
            require(summary.invocationCount == 2, "both actual backend operations must be counted")
            require(summary.successfulInvocationCount == 1 && summary.failedInvocationCount == 1, "mixed chunk counts preserve the earlier failure")
            require(!summary.allSucceeded, "\(failure) followed by success cannot erase raw chunk fallback")
            require(summary.voiceStatus(cancelled: false, timedOut: false, guardRejected: false, capped: false) == "rawOrUnavailable", "mixed cleanup cannot be marked completed")
            require(summary.guardAccepted(guardRejected: false) == nil, "mixed cleanup cannot claim guard acceptance")
        }
        for empty in ["", " \n\t"] {
            let ledger = BackendInvocationLedger()
            _ = try await ledger.respond(runID: "empty") { empty }
            _ = try await ledger.respond(runID: "empty") { "Clean second chunk." }
            let summary = ledger.summary(for: "empty")
            require(summary.invocationCount == 2 && summary.failedInvocationCount == 1, "empty returned chunk is a failed invocation")
            require(!summary.allSucceeded, "empty response followed by success cannot erase raw fallback")
            require(summary.voiceStatus(cancelled: false, timedOut: false, guardRejected: false, capped: false) == "rawOrUnavailable", "empty chunk cannot complete voice cleanup")
            require(summary.guardAccepted(guardRejected: false) == nil, "empty chunk cannot claim guard acceptance")
        }
        let ledger = BackendInvocationLedger()
        for reply in ["First cleaned chunk.", "Second cleaned chunk."] {
            _ = try await ledger.respond(runID: "all-success") { reply }
        }
        let success = ledger.summary(for: "all-success")
        require(success.invocationCount == 2 && success.successfulInvocationCount == 2 && success.failedInvocationCount == 0, "all successful invocations are counted")
        require(success.voiceStatus(cancelled: false, timedOut: false, guardRejected: false, capped: false) == "completed", "all successful chunks can complete")
        require(success.guardAccepted(guardRejected: false) == true, "all successful accepted chunks report acceptance")
        require(success.guardAccepted(guardRejected: true) == false, "pipeline guard rejection remains visible")
        let uninvoked = ledger.summary(for: "new-run")
        require(uninvoked.invocationCount == 0 && !uninvoked.allSucceeded, "an uninvoked run cannot borrow earlier success")
        require(uninvoked.guardAccepted(guardRejected: false) == nil, "uninvoked run has no guard result")
        _ = try await ledger.respond(runID: "failed-run") { "" }
        _ = try await ledger.respond(runID: "next-run") { "New cleanup." }
        let reset = ledger.summary(for: "next-run")
        require(reset.invocationCount == 1 && reset.successfulInvocationCount == 1 && reset.failedInvocationCount == 0, "new run resets invocation counts and previous failures")
        require(reset.allSucceeded, "a new successful run does not retain previous failure")
        print("PASS: actual tracked chunk calls preserve errors/empty responses across later success, all-success and run reset")
    }
}
