import Foundation
import Synchronization

/// Tracks every backend call in a serialized run, including errors swallowed by cleanup fallback.
public final class BackendInvocationLedger: Sendable {
    public struct Summary: Sendable {
        public var runID = ""
        public var invocationCount = 0
        public var successfulInvocationCount = 0
        public var failedInvocationCount = 0
        public var allSucceeded: Bool {
            invocationCount > 0 && failedInvocationCount == 0 && successfulInvocationCount == invocationCount
        }
        public func voiceStatus(cancelled: Bool, timedOut: Bool, guardRejected: Bool, capped: Bool) -> String {
            VoiceOutcome.classify(cancelled: cancelled, timedOut: timedOut, guardRejected: guardRejected,
                                  backendSucceeded: allSucceeded, capped: capped)
        }
        public func guardAccepted(guardRejected: Bool) -> Bool? { allSucceeded ? !guardRejected : nil }
    }
    private let state = Mutex(Summary())
    public init() {}

    public func summary(for runID: String) -> Summary {
        state.withLock { $0.runID == runID ? $0 : Summary(runID: runID) }
    }

    public func respond(runID: String, operation: @Sendable () async throws -> String) async throws -> String {
        state.withLock { value in
            if value.runID != runID { value = Summary(runID: runID) }
            value.invocationCount += 1
        }
        do {
            let reply = try await operation()
            state.withLock { value in
                let succeeded = !reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                if succeeded { value.successfulInvocationCount += 1 } else { value.failedInvocationCount += 1 }
            }
            return reply
        } catch {
            state.withLock { $0.failedInvocationCount += 1 }
            throw error
        }
    }
}
