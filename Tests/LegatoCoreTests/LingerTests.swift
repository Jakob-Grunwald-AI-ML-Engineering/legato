import Foundation
import Synchronization
import Testing
@testable import LegatoCore

@Suite struct LingerTests {
    @Test func zeroOrNegativeSecondsMeanOff() {
        #expect(Linger.seconds(0) == .off)
        #expect(Linger.seconds(-5) == .off)
        #expect(Linger.zero == .off)
        #expect(!Linger.off.holdsLease)
    }

    @Test func aDurationHoldsTheLeaseWithATimeout() {
        #expect(Linger.seconds(30).holdsLease)
        #expect(Linger.seconds(30).timeout == .seconds(30))
    }

    @Test func indefiniteHoldsTheLeaseWithoutATimeout() {
        #expect(Linger.indefinite.holdsLease)
        #expect(Linger.indefinite.timeout == nil)
        #expect(Linger.off.timeout == nil)
    }
}

@Suite struct KeepAliveChoiceTests {
    @Test func theChoicesAreOffThenMinutesThenAnHourThenIndefinitely() {
        #expect(KeepAliveChoice.allCases.map(\.rawValue) == [0, 60, 300, 600, 1800, 3600, -1])
    }

    @Test func eachChoiceMapsToItsLinger() {
        #expect(KeepAliveChoice.allCases.map(\.linger) == [
            .off, .seconds(60), .seconds(300), .seconds(600), .seconds(1800), .seconds(3600), .indefinite,
        ])
    }

    @Test(arguments: [(30, KeepAliveChoice.minute1), (120, .minutes5)])
    func theRetiredChoicesMigrateUp(stored: Int, expected: KeepAliveChoice) {
        #expect(KeepAliveChoice(migratingStoredSeconds: stored) == expected)
    }

    @Test(arguments: KeepAliveChoice.allCases)
    func aCurrentChoiceStaysAsItIs(choice: KeepAliveChoice) {
        #expect(KeepAliveChoice(migratingStoredSeconds: choice.rawValue) == choice)
    }

    @Test func zeroIsOffAndAnyNegativeIsIndefinitely() {
        #expect(KeepAliveChoice(migratingStoredSeconds: 0) == .off)
        #expect(KeepAliveChoice(migratingStoredSeconds: -1) == .indefinitely)
        #expect(KeepAliveChoice(migratingStoredSeconds: -999) == .indefinitely)
    }

    @Test(arguments: [(1, KeepAliveChoice.minute1), (45, .minute1), (400, .minutes5), (450, .minutes10),
                      (1000, .minutes10), (1300, .minutes30), (5000, .hour1)])
    func anUnknownPositiveValueGoesToTheNearestChoiceAndTiesGoLonger(stored: Int, expected: KeepAliveChoice) {
        #expect(KeepAliveChoice(migratingStoredSeconds: stored) == expected)
    }
}

/// Virtual time for sleeps: `advance(by:)` wakes the sleepers whose deadline has come. A cancelled
/// sleeper throws.
final class VirtualClock: Sendable {
    private struct State {
        var now = Duration.zero
        var nextID = 0
        var waiters: [Int: (deadline: Duration, continuation: CheckedContinuation<Void, any Error>)] = [:]
        var requested: [Duration] = []
    }
    private let state = Mutex(State())

    /// The durations every sleep asked for, in order.
    var requested: [Duration] { state.withLock { $0.requested } }
    var now: Duration { state.withLock { $0.now } }

    func advance(by d: Duration) {
        let due = state.withLock { s -> [CheckedContinuation<Void, any Error>] in
            s.now += d
            let ids = s.waiters.filter { $0.value.deadline <= s.now }.keys
            return ids.compactMap { s.waiters.removeValue(forKey: $0)?.continuation }
        }
        for c in due { c.resume() }
    }

    var sleep: @Sendable (Duration) async throws -> Void {
        { [self] d in
            let id = state.withLock { s -> Int in
                s.nextID += 1
                s.requested.append(d)
                return s.nextID
            }
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, any Error>) in
                    let cancelled = state.withLock { s -> Bool in
                        if Task.isCancelled { return true }
                        s.waiters[id] = (s.now + d, c)
                        return false
                    }
                    if cancelled { c.resume(throwing: CancellationError()) }
                }
            } onCancel: {
                let c = state.withLock { $0.waiters.removeValue(forKey: id)?.continuation }
                c?.resume(throwing: CancellationError())
            }
        }
    }
}
