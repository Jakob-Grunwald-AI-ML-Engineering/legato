import Synchronization
import Testing

/// Deterministic clock: time moves only when a test calls `advance(by:)`. Sleepers are resumed in
/// deadline order; a cancelled sleeper is removed at once, so `sleeperCount` is an exact signal that
/// production code has (or has not) armed a wait.
final class VirtualClock: Clock, Sendable {
    struct Instant: InstantProtocol {
        var offset: Duration
        func advanced(by duration: Duration) -> Instant { .init(offset: offset + duration) }
        func duration(to other: Instant) -> Duration { other.offset - offset }
        static func < (a: Instant, b: Instant) -> Bool { a.offset < b.offset }
    }
    private struct Sleeper { let deadline: Instant; let continuation: CheckedContinuation<Void, any Error> }
    private struct State { var now = Instant(offset: .zero); var nextID = 0; var sleepers: [Int: Sleeper] = [:] }
    private let state = Mutex(State())
    var now: Instant { state.withLock { $0.now } }
    var minimumResolution: Duration { .zero }
    var sleeperCount: Int { state.withLock { $0.sleepers.count } }
    /// Total waits ever armed; a rise proves the runner processed an event that re-arms its timer.
    var armCount: Int { state.withLock { $0.nextID } }
    var deadlines: [Instant] { state.withLock { $0.sleepers.values.map(\.deadline).sorted() } }

    func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        let id = state.withLock { s -> Int in s.nextID += 1; return s.nextID }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, any Error>) in
                enum Next { case resume, cancel, wait }
                let next = state.withLock { s -> Next in
                    if Task.isCancelled { return .cancel }
                    if deadline <= s.now { return .resume }
                    s.sleepers[id] = Sleeper(deadline: deadline, continuation: c); return .wait
                }
                switch next {
                case .resume: c.resume()
                case .cancel: c.resume(throwing: CancellationError())
                case .wait: break
                }
            }
        } onCancel: {
            let sleeper = state.withLock { $0.sleepers.removeValue(forKey: id) }
            sleeper?.continuation.resume(throwing: CancellationError())
        }
    }

    /// Moves time forward and resumes every sleeper whose deadline has been reached, earliest first.
    func advance(by duration: Duration) {
        let due = state.withLock { s -> [Sleeper] in
            s.now = s.now.advanced(by: duration)
            let ids = s.sleepers.filter { $0.value.deadline <= s.now }.sorted { $0.value.deadline < $1.value.deadline }.map(\.key)
            return ids.compactMap { s.sleepers.removeValue(forKey: $0) }
        }
        for sleeper in due { sleeper.continuation.resume() }
    }
}

/// Polls until `condition` holds. The bound only guards against a hung test; it never decides the outcome.
func eventually(_ what: String, timeout: Duration = .seconds(60), sourceLocation: SourceLocation = #_sourceLocation,
                _ condition: () async -> Bool) async {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return }
        try? await Task.sleep(for: .milliseconds(2))
    }
    Issue.record("Timed out waiting for \(what)", sourceLocation: sourceLocation)
}
