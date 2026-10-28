import Foundation
import Synchronization
@testable import LegatoCore

/// A held fake operation waits for an explicit release, even if its caller is cancelled.
final class HeldOperation: Sendable {
    private struct State {
        var held = false
        var waiters: [CheckedContinuation<Void, Never>] = []
    }
    private let state = Mutex(State())
    init(held: Bool = false) { state.withLock { $0.held = held } }
    func hold(_ held: Bool) {
        let waiters = state.withLock { s -> [CheckedContinuation<Void, Never>] in
            s.held = held
            guard !held else { return [] }
            let waiters = s.waiters
            s.waiters = []
            return waiters
        }
        for waiter in waiters { waiter.resume() }
    }
    func wait() async {
        await withCheckedContinuation { continuation in
            let waiting = state.withLock { s in
                guard s.held else { return false }
                s.waiters.append(continuation)
                return true
            }
            if !waiting { continuation.resume() }
        }
    }
}

struct TestError: Error, Equatable { var tag = "boom" }

/// Ordered, thread-safe event log shared by the fakes.
final class EventLog: Sendable {
    private let store = Mutex<[String]>([])
    func add(_ e: String) { store.withLock { $0.append(e) } }
    var events: [String] { store.withLock { $0 } }
    func count(_ e: String) -> Int { events.filter { $0 == e }.count }
}

let testFormat = AudioFormatSpec(sampleRate: 16_000, channelCount: 1)

final class FakeSessionControl: AudioSessionControlling {
    let log: EventLog
    let supportedPolicies: Set<AudioPolicy>
    private let activateError = Mutex<(any Error)?>(nil)
    /// Activation fails only for these configs; nil = for every config.
    private let failingConfigs = Mutex<[SessionConfig]?>(nil)
    private let configs = Mutex<[SessionConfig]>([])

    init(log: EventLog, supported: Set<AudioPolicy> = [.duckOthers, .mixWithOthers]) {
        self.log = log
        self.supportedPolicies = supported
    }
    func failActivation(with e: any Error, only policies: [AudioPolicy]? = nil) {
        activateError.withLock { $0 = e }
        failingConfigs.withLock { $0 = policies?.map(\.sessionConfig) }
    }
    func clearActivationFailure() { activateError.withLock { $0 = nil } }
    var activatedConfigs: [SessionConfig] { configs.withLock { $0 } }

    /// Models iOS: while the session is active (and this is on), activating it again fails with the error,
    /// the way a background `setCategory` on an active session fails with '!int'.
    private let refusalWhileActive = Mutex<(any Error)?>(nil)
    private let active = Mutex(false)
    func refuseActivationWhileActive(with e: (any Error)?) { refusalWhileActive.withLock { $0 = e } }
    var isActive: Bool { active.withLock { $0 } }

    func activate(_ config: SessionConfig) throws {
        log.add("activate")
        if let e = activateError.withLock({ $0 }),
           failingConfigs.withLock({ $0 })?.contains(config) ?? true { throw e }
        if let e = refusalWhileActive.withLock({ $0 }), isActive { throw e }
        active.withLock { $0 = true }
        configs.withLock { $0.append(config) }
    }
    func deactivate() {
        log.add("deactivate")
        active.withLock { $0 = false }
    }
}

final class FakeSource: AudioSource {
    let log: EventLog
    private let continuation = Mutex<AsyncStream<AudioChunk>.Continuation?>(nil)
    private let startError = Mutex<(any Error)?>(nil)
    /// `start` fails this many more times, then works.
    private let startFailuresLeft = Mutex<(error: (any Error)?, count: Int)>((nil, 0))
    private let routeError = Mutex<(any Error)?>(nil)
    private let stopHold = HeldOperation()

    init(log: EventLog) { self.log = log }
    /// Keeps `stop` pending (after it logged) until released: a teardown a test can interleave with.
    func holdStop(_ on: Bool) { stopHold.hold(on) }
    func failStart(with e: any Error) { startError.withLock { $0 = e } }
    func clearStartFailure() { startError.withLock { $0 = nil } }
    func failNextStarts(_ count: Int, with e: any Error) { startFailuresLeft.withLock { $0 = (e, count) } }
    func failRoute(with e: any Error) { routeError.withLock { $0 = e } }

    private func makeStream() -> AsyncStream<AudioChunk> {
        let (stream, cont) = AsyncStream<AudioChunk>.makeStream()
        continuation.withLock { old in
            old?.finish()
            old = cont
        }
        return stream
    }

    func start(format: AudioFormatSpec) async throws -> AsyncStream<AudioChunk> {
        log.add("source.start")
        if let e = startError.withLock({ $0 }) { throw e }
        let transient = startFailuresLeft.withLock { s -> (any Error)? in
            guard s.count > 0 else { return nil }
            s.count -= 1
            return s.error
        }
        if let transient { throw transient }
        return makeStream()
    }
    func route() async throws -> AsyncStream<AudioChunk> {
        log.add("source.route")
        if let e = routeError.withLock({ $0 }) { throw e }
        return makeStream()
    }
    func detach() async {
        log.add("source.detach")
        continuation.withLock { $0?.finish(); $0 = nil }
    }
    func stop() async {
        log.add("source.stop")
        await stopHold.wait()
        continuation.withLock { $0?.finish(); $0 = nil }
    }
}

final class FakeEngine: DictationEngine {
    let id = "fake"
    let log: EventLog
    private struct Config {
        var installed = true
        var prepareError: (any Error)?
        var hangInPrepare = false
        var script: [TranscriptEvent] = []
        var streamError: (any Error)?
        var finishError: (any Error)?
        /// Leave the results stream open after the input ends (a stream that outlives `finish()`).
        var holdStreamOpen = false
        /// Keeps `finish()` pending until cleared (polled), so a test can sit inside a stop.
        var holdFinish = false
    }
    private let config = Mutex(Config())
    /// Results continuations in `transcribe` order, for `emit` / `failStream`.
    private let streams = Mutex<[AsyncThrowingStream<TranscriptEvent, Error>.Continuation]>([])

    init(log: EventLog) { self.log = log }

    func set(installed: Bool? = nil, prepareError: (any Error)? = nil, hangInPrepare: Bool? = nil,
             script: [TranscriptEvent]? = nil, streamError: (any Error)? = nil, finishError: (any Error)? = nil,
             holdStreamOpen: Bool? = nil, holdFinish: Bool? = nil) {
        config.withLock {
            if let installed { $0.installed = installed }
            if let prepareError { $0.prepareError = prepareError }
            if let hangInPrepare { $0.hangInPrepare = hangInPrepare }
            if let script { $0.script = script }
            if let streamError { $0.streamError = streamError }
            if let finishError { $0.finishError = finishError }
            if let holdStreamOpen { $0.holdStreamOpen = holdStreamOpen }
            if let holdFinish { $0.holdFinish = holdFinish }
        }
    }

    func clearFinishError() { config.withLock { $0.finishError = nil } }
    func clearPrepareError() { config.withLock { $0.prepareError = nil } }
    func clearStreamError() { config.withLock { $0.streamError = nil } }

    /// Pushes `event` into the results stream of the `run`-th `transcribe` call (0-based), if still open.
    func emit(_ event: TranscriptEvent, run: Int) {
        let c = streams.withLock { run < $0.count ? $0[run] : nil }
        c?.yield(event)
    }

    /// Fails the results stream of the `run`-th `transcribe` call, if still open.
    func failStream(with error: any Error, run: Int) {
        let c = streams.withLock { run < $0.count ? $0[run] : nil }
        c?.finish(throwing: error)
    }

    func installAssets(locale: Locale?) -> AsyncStream<Double> {
        AsyncStream { c in
            for p in [0.0, 0.5, 1.0] { c.yield(p) }
            c.finish()
        }
    }

    func prepare(locale: Locale?) async throws -> AudioFormatSpec {
        log.add("engine.prepare")
        // Polled so a test can release a held prepare (and so cancellation ends the hold).
        while config.withLock({ $0.hangInPrepare }) { try await Task.sleep(for: .milliseconds(5)) }
        let cfg = config.withLock { $0 }
        if let e = cfg.prepareError { throw e }
        if !cfg.installed { throw DictationError.assetsNotInstalled }
        return testFormat
    }

    func transcribe(_ input: AsyncStream<AudioChunk>) -> AsyncThrowingStream<TranscriptEvent, Error> {
        log.add("engine.transcribe")
        let cfg = config.withLock { $0 }
        let (stream, cont) = AsyncThrowingStream<TranscriptEvent, Error>.makeStream()
        streams.withLock { $0.append(cont) }
        if let err = cfg.streamError {
            // Buffered before `transcribe` returns, so the failure is already waiting for the consumer.
            for e in cfg.script { cont.yield(e) }
            cont.finish(throwing: err)
            return stream
        }
        let task = Task {
            for e in cfg.script { cont.yield(e) }
            for await _ in input {}
            if !cfg.holdStreamOpen { cont.finish() }
        }
        cont.onTermination = { _ in task.cancel() }
        return stream
    }

    func finish() async throws {
        log.add("engine.finish")
        while config.withLock({ $0.holdFinish }) { try await Task.sleep(for: .milliseconds(5)) }
        if let e = config.withLock({ $0.finishError }) { throw e }
    }
}

/// In-memory history for session tests.
actor MemoryHistory: HistoryStore {
    private(set) var entries: [DictationEntry] = []
    func append(_ entry: DictationEntry) async throws { entries.append(entry) }
    func recent(limit: Int) async throws -> [DictationEntry] { Array(entries.reversed().prefix(limit)) }
    func delete(id: UUID) async throws { entries.removeAll { $0.id == id } }
}

/// Manually driven sleep: each call to the returned closure waits for one `tick()` (a tick sent before
/// anyone waits is kept for the next sleeper). A cancelled sleeper throws and consumes nothing, and
/// the clock stays usable afterwards (an `AsyncStream`-based clock would end for good once a
/// cancelled task had been iterating it, so a second run's sleep would return at once).
struct ManualClock: Sendable {
    private final class Source: Sendable {
        private struct State {
            var pending = 0
            var nextID = 0
            var registered = 0
            var cancelled = 0
            var waiters: [Int: CheckedContinuation<Void, any Error>] = [:]
        }
        private let state = Mutex(State())
        var pendingCount: Int { state.withLock { $0.waiters.count } }
        var registeredCount: Int { state.withLock { $0.registered } }
        var cancelledCount: Int { state.withLock { $0.cancelled } }

        func tick() {
            let waiter = state.withLock { s -> CheckedContinuation<Void, any Error>? in
                if let id = s.waiters.keys.min() { return s.waiters.removeValue(forKey: id) }
                s.pending += 1
                return nil
            }
            waiter?.resume()
        }

        func wait() async throws {
            let id = state.withLock { s -> Int in s.nextID += 1; return s.nextID }
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, any Error>) in
                    enum Next { case resume, cancel, wait }
                    let next = state.withLock { s -> Next in
                        if Task.isCancelled { return .cancel }
                        if s.pending > 0 { s.pending -= 1; return .resume }
                        s.waiters[id] = c
                        s.registered += 1
                        return .wait
                    }
                    switch next {
                    case .resume: c.resume()
                    case .cancel: c.resume(throwing: CancellationError())
                    case .wait: break
                    }
                }
            } onCancel: {
                let waiter = state.withLock { s in
                    let waiter = s.waiters.removeValue(forKey: id)
                    if waiter != nil { s.cancelled += 1 }
                    return waiter
                }
                waiter?.resume(throwing: CancellationError())
            }
        }
    }

    private let source = Source()
    func tick() { source.tick() }
    var pendingCount: Int { source.pendingCount }
    var registeredCount: Int { source.registeredCount }
    var cancelledCount: Int { source.cancelledCount }
    var sleep: @Sendable (Duration) async throws -> Void {
        let source = self.source
        return { _ in try await source.wait() }
    }
}

/// Polls until `condition` holds or a generous 30 s deadline passes (a hang guard, not a speed bound).
func eventually(_ condition: @MainActor () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + .seconds(30)
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return await condition()
}

// MARK: coordinator ports

/// Records every Live Activity call, and into the shared log (`activity.<call>:<phase>`).
@MainActor
final class FakeActivity: ActivityClient {
    enum Call: Equatable {
        case request(DictationActivityContent)
        case update(DictationActivityContent, staleDate: Date?)
        case end(DictationActivityContent)

        var content: DictationActivityContent {
            switch self {
            case .request(let c), .update(let c, _), .end(let c): c
            }
        }
    }

    let log: EventLog
    private(set) var calls: [Call] = []
    /// How often `dismiss` was called (the run never began; the activity was removed at once).
    private(set) var dismissals = 0
    /// Makes `request` throw (Live Activities refused).
    var requestError: (any Error)?
    /// Keeps `request` pending until cleared.
    private let requestHold = HeldOperation()
    var holdRequest = false { didSet { requestHold.hold(holdRequest) } }
    /// Keeps `dismiss` pending after it logged, until cleared.
    private let dismissHold = HeldOperation()
    var holdDismiss = false { didSet { dismissHold.hold(holdDismiss) } }
    /// Keeps `update` pending after it logged, until cleared.
    private let updateHold = HeldOperation()
    var holdUpdate = false { didSet { updateHold.hold(holdUpdate) } }

    init(log: EventLog) { self.log = log }

    var phases: [DictationPhase] { calls.map(\.content.phase) }
    var updates: [(content: DictationActivityContent, staleDate: Date?)] {
        calls.compactMap { if case .update(let c, let s) = $0 { (c, s) } else { nil } }
    }
    var ends: [DictationActivityContent] {
        calls.compactMap { if case .end(let c) = $0 { c } else { nil } }
    }

    func request(_ content: DictationActivityContent) async throws {
        log.add("activity.request:\(content.phase.rawValue)")
        calls.append(.request(content))
        await requestHold.wait()
        if let requestError { throw requestError }
    }
    func update(_ content: DictationActivityContent, staleDate: Date?) async {
        log.add("activity.update:\(content.phase.rawValue)")
        calls.append(.update(content, staleDate: staleDate))
        await updateHold.wait()
    }
    func end(_ content: DictationActivityContent) async {
        log.add("activity.end:\(content.phase.rawValue)")
        calls.append(.end(content))
    }
    func dismiss() async {
        log.add("activity.dismiss")
        dismissals += 1
        await dismissHold.wait()
    }
}

@MainActor
final class FakeClipboard: Clipboard {
    let log: EventLog
    private(set) var written: [String] = []
    /// What `write` reports: whether the pasteboard's change count moved.
    var changes = true

    init(log: EventLog) { self.log = log }

    func write(_ text: String) -> Bool {
        log.add("clipboard.write")
        written.append(text)
        return changes
    }
}

@MainActor
final class FakeReadiness: Readiness {
    var issue: ReadinessIssue?
    func check() async -> ReadinessIssue? { issue }
}

@MainActor
final class FakeStartEnvironment: StartEnvironment {
    var context = StartContext.unrestricted
    /// `TestError.tag` values that count as "the system refused a background start".
    var refusalTags: Set<String> = ["refused"]
    /// `TestError.tag` values that mean "the mic had no input yet". Also a refusal in the background,
    /// like the app's `invalidInputFormat`.
    var notReadyTags: Set<String> = ["notReady"]
    func current() -> StartContext { context }
    func isBackgroundRefusal(_ error: any Error) -> Bool {
        (error as? TestError).map { refusalTags.contains($0.tag) || notReadyTags.contains($0.tag) } ?? false
    }
    func isInputNotReady(_ error: any Error) -> Bool {
        (error as? TestError).map { notReadyTags.contains($0.tag) } ?? false
    }
}

/// Records what the coordinator tells its sink, and into the shared log (`sink.<call>`).
@MainActor
final class FakeSink: TranscriptSink {
    let log: EventLog
    private(set) var started: [DictationRun] = []
    private(set) var updates: [(committed: String, volatile: String)] = []
    private(set) var ended: [(run: DictationRun, committed: String, text: String?)] = []
    /// `leaseChanged` calls in order: the lease end, or nil when it ended.
    private(set) var leases: [Date?] = []
    /// What `runEnded` reports: the final text landed in the field.
    var finalApplied = false
    /// Live cleanup's revisions, in order (not logged, so the sink trails other tests compare stay as they were).
    private(set) var revisions: [TranscriptRevision] = []

    init(log: EventLog) { self.log = log }

    func runStarted(_ run: DictationRun) {
        log.add("sink.runStarted:\(run.target)")
        started.append(run)
    }
    func update(committed: String, volatile: String) {
        log.add("sink.update")
        updates.append((committed, volatile))
    }
    /// Logged outside the `sink.` prefix, so the sink trails other tests compare stay as they were.
    func runFinishing(_ run: DictationRun) {
        log.add("finishing:sink")
    }
    /// Runs inside `runEnded`, as a keyboard's late report would arrive while the sink waits for its confirmation.
    var onRunEnded: (@MainActor () -> Void)?
    func runEnded(_ run: DictationRun, committed: String, text: String?) async -> Bool {
        log.add("sink.runEnded")
        ended.append((run, committed, text))
        onRunEnded?()
        return finalApplied
    }
    func revised(_ revision: TranscriptRevision) {
        revisions.append(revision)
    }
    /// Live cleanup's trace, in order (not logged either).
    private(set) var liveTrace: [LiveTraceEvent] = []
    func liveTraced(_ event: LiveTraceEvent) {
        liveTrace.append(event)
    }
    func leaseChanged(until: Date?) {
        log.add(until == nil ? "sink.lease:nil" : "sink.lease:set")
        leases.append(until)
    }
    /// What `sentTentative` answers: the tentative text the keyboard's field showed when it was cleared.
    var tentative = ""
    func sentTentative(runID: String, boundary: Int) -> String { tentative }
}
