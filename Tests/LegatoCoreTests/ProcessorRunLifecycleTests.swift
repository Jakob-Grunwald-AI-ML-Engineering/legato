import Foundation
import Synchronization
import Testing
@testable import LegatoCore

private final class RunProcessor: TranscriptPostProcessor {
    let id = "run-lifecycle"
    let log: EventLog
    let failStart: Bool
    let gate: RunSignal?
    let entered = RunSignal()
    let ended = RunSignal()
    init(log: EventLog, failStart: Bool = false, gate: RunSignal? = nil) {
        self.log = log; self.failStart = failStart; self.gate = gate
    }
    func runStarts() async throws {
        log.add("cleanup.start")
        await entered.signal()
        await gate?.wait()
        if failStart { throw TestError(tag: "cleanup-start") }
    }
    func runEnds() async { log.add("cleanup.end"); await ended.signal() }
    func process(_ text: String, locale: Locale) async throws -> String { text }
}
private actor RunSignal {
    private var signalled = false
    private var waiters: [AsyncStream<Void>.Continuation] = []
    func wait() async {
        if signalled { return }
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        waiters.append(continuation)
        var iterator = stream.makeAsyncIterator(); _ = await iterator.next()
    }
    func signal() {
        signalled = true
        for waiter in waiters { waiter.yield(()); waiter.finish() }
        waiters = []
    }
}

@MainActor @Suite(.timeLimit(.minutes(1))) struct ProcessorRunLifecycleTests {
    @Test func nonLiveRunStartsBeforeCaptureAndEndsBeforeKeptSessionReuse() async throws {
        let log = EventLog(), engine = FakeEngine(log: EventLog())
        engine.set(script: [])
        let session = DictationSession(engine: engine, source: FakeSource(log: log),
            sessionControl: FakeSessionControl(log: log), history: MemoryHistory(),
            postProcessor: RunProcessor(log: log), linger: .indefinite)
        try await session.start()
        #expect(log.events.prefix(3) == ["cleanup.start", "activate", "source.start"])
        _ = try await session.stop()
        #expect(log.count("cleanup.end") == 1)
        try await session.start()
        _ = try await session.stop()
        #expect(log.count("cleanup.start") == 2)
        #expect(log.count("cleanup.end") == 2)
        await session.endLease()
    }

    @Test func failedRunPreparationNeverCapturesAndEndsProcessorOwnership() async throws {
        let log = EventLog(), engine = FakeEngine(log: EventLog())
        let session = DictationSession(engine: engine, source: FakeSource(log: log),
            sessionControl: FakeSessionControl(log: log), history: MemoryHistory(),
            postProcessor: RunProcessor(log: log, failStart: true))
        await #expect(throws: TestError(tag: "cleanup-start")) { try await session.start() }
        #expect(log.count("activate") == 0)
        #expect(log.count("source.start") == 0)
        #expect(log.count("cleanup.end") == 1)
    }

    @Test func cancellationWhileProcessorAcquiresCannotActivateCaptureAfterItReturns() async throws {
        let log = EventLog(), gate = RunSignal(), engine = FakeEngine(log: EventLog())
        let processor = RunProcessor(log: log, gate: gate)
        let session = DictationSession(engine: engine, source: FakeSource(log: log),
            sessionControl: FakeSessionControl(log: log), history: MemoryHistory(), postProcessor: processor)
        let starting = Task { try await session.start() }
        await processor.entered.wait()
        _ = try await session.stop()
        await #expect(throws: DictationError.cancelled) { try await starting.value }
        #expect(log.count("activate") == 0)
        #expect(log.count("source.start") == 0)
        #expect(log.count("cleanup.end") == 1)
        #expect(session.runState == .idle)
    }

    @Test func captureFailureEndsAcquiredProcessorRun() async throws {
        let log = EventLog(), engine = FakeEngine(log: EventLog()), source = FakeSource(log: log)
        source.failStart(with: TestError(tag: "capture"))
        let session = DictationSession(engine: engine, source: source,
            sessionControl: FakeSessionControl(log: log), history: MemoryHistory(), postProcessor: RunProcessor(log: log))
        await #expect(throws: TestError(tag: "capture")) { try await session.start() }
        #expect(log.count("cleanup.start") == 1)
        #expect(log.count("cleanup.end") == 1)
        #expect(session.runState == .idle)
    }

    @Test func streamAbortEndsProcessorOwnershipBeforeSessionCanBeReused() async throws {
        let log = EventLog(), engine = FakeEngine(log: EventLog()), processor = RunProcessor(log: log)
        engine.set(script: [], streamError: TestError(tag: "stream"))
        let session = DictationSession(engine: engine, source: FakeSource(log: log),
            sessionControl: FakeSessionControl(log: log), history: MemoryHistory(), postProcessor: processor)
        try await session.start()
        await processor.ended.wait()
        await session.settled()
        #expect(log.count("cleanup.start") == 1)
        #expect(log.count("cleanup.end") == 1)
        #expect(session.runState == .idle)
    }
}
