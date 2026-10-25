import Foundation
import Synchronization
@testable import LegatoCore

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
    private let configs = Mutex<[SessionConfig]>([])

    init(log: EventLog, supported: Set<AudioPolicy> = [.duckOthers, .mixWithOthers]) {
        self.log = log
        self.supportedPolicies = supported
    }
    func failActivation(with e: any Error) { activateError.withLock { $0 = e } }
    var activatedConfigs: [SessionConfig] { configs.withLock { $0 } }

    func activate(_ config: SessionConfig) throws {
        log.add("activate")
        if let e = activateError.withLock({ $0 }) { throw e }
        configs.withLock { $0.append(config) }
    }
    func deactivate() { log.add("deactivate") }
}

final class FakeSource: AudioSource {
    let log: EventLog
    private let continuation = Mutex<AsyncStream<AudioChunk>.Continuation?>(nil)
    private let startError = Mutex<(any Error)?>(nil)
    private let routeError = Mutex<(any Error)?>(nil)

    init(log: EventLog) { self.log = log }
    func failStart(with e: any Error) { startError.withLock { $0 = e } }
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
    }
    private let config = Mutex(Config())
    /// Results continuations in `transcribe` order, for `emit` / `failStream`.
    private let streams = Mutex<[AsyncThrowingStream<TranscriptEvent, Error>.Continuation]>([])

    init(log: EventLog) { self.log = log }

    func set(installed: Bool? = nil, prepareError: (any Error)? = nil, hangInPrepare: Bool? = nil,
             script: [TranscriptEvent]? = nil, streamError: (any Error)? = nil, finishError: (any Error)? = nil,
             holdStreamOpen: Bool? = nil) {
        config.withLock {
            if let installed { $0.installed = installed }
            if let prepareError { $0.prepareError = prepareError }
            if let hangInPrepare { $0.hangInPrepare = hangInPrepare }
            if let script { $0.script = script }
            if let streamError { $0.streamError = streamError }
            if let finishError { $0.finishError = finishError }
            if let holdStreamOpen { $0.holdStreamOpen = holdStreamOpen }
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
        let task = Task {
            for e in cfg.script { cont.yield(e) }
            if let err = cfg.streamError { cont.finish(throwing: err); return }
            for await _ in input {}
            if !cfg.holdStreamOpen { cont.finish() }
        }
        cont.onTermination = { _ in task.cancel() }
        return stream
    }

    func finish() async throws {
        log.add("engine.finish")
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

/// Manually driven sleep: each call to the returned closure waits for one `tick()`.
struct ManualClock: Sendable {
    let ticks: AsyncStream<Void>
    private let cont: AsyncStream<Void>.Continuation
    init() { (ticks, cont) = AsyncStream<Void>.makeStream() }
    func tick() { cont.yield(()) }
    var sleep: @Sendable (Duration) async throws -> Void {
        let ticks = self.ticks
        return { _ in
            var it = ticks.makeAsyncIterator()
            _ = await it.next()
            try Task.checkCancellation()
        }
    }
}

/// Polls until `condition` holds (max ~2 s).
func eventually(_ condition: @MainActor () -> Bool) async -> Bool {
    for _ in 0..<400 {
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
    /// Makes `request` throw (Live Activities refused).
    var requestError: (any Error)?
    /// Keeps `request` pending until cleared (polled, like `FakeEngine`'s prepare hold).
    var holdRequest = false

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
        while holdRequest { try? await Task.sleep(for: .milliseconds(5)) }
        if let requestError { throw requestError }
    }
    func update(_ content: DictationActivityContent, staleDate: Date?) async {
        log.add("activity.update:\(content.phase.rawValue)")
        calls.append(.update(content, staleDate: staleDate))
    }
    func end(_ content: DictationActivityContent) async {
        log.add("activity.end:\(content.phase.rawValue)")
        calls.append(.end(content))
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
