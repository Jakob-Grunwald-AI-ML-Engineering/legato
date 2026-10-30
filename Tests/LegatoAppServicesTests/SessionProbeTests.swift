import Foundation
import LegatoCore
import LegatoClaude
import LegatoMeetings
import Synchronization
import Testing
@testable import LegatoAppServices

@Suite(.timeLimit(.minutes(1))) struct SessionProbeTests {
    @Test @MainActor func coordinatorReservesBeforeSpawnAndTerminalFollowsCleanup() async throws {
        let coordinator = SessionProbeCoordinator(measurements: .init(sleep: { _ in }))
        let backend = ProbeBackend(), gate = ProbeSignal()
        var order: [String] = [], events: [SessionProbeEvent] = []
        let hooks = SessionProbeCoordinator.Hooks(reserve: { _ in order.append("reserve"); await gate.wait() },
            releaseAppModels: { _ in order.append("release-models") },
            prepare: { _ in [.init(id: "fake", backend: backend, measuresKickstart: false, release: { await backend.releaseWarmResources() })] },
            cleanup: { _ in order.append("cleanup") }, restoreAppModels: { _ in order.append("restore") },
            releaseReservations: { _ in order.append("unreserve") }, emit: { event in events.append(event); if event.kind == .completed { order.append("terminal") } })
        let id = try #require(try coordinator.start(mode: .foreground, hooks: hooks))
        #expect(coordinator.isRunning)
        #expect(try coordinator.start(mode: .foreground, hooks: hooks) == nil)
        coordinator.cancel(id: UUID())
        gate.open()
        await coordinator.waitUntilFinished()
        #expect(events.filter { $0.kind == .completed }.map(\.outcome) == [.ok])
        #expect(order == ["reserve", "release-models", "cleanup", "restore", "unreserve", "terminal"])
        #expect(events.last?.id == id)
        #expect(!coordinator.isRunning)
        #expect(await backend.openSessions == 0)
        #expect(await backend.releases == 1)
    }

    @Test @MainActor func noBackendAndBackgroundTransitionFailureCannotReportSuccess() async throws {
        let coordinator = SessionProbeCoordinator(measurements: .init(sleep: { _ in }))
        var terminal: [SessionProbeOutcome?] = []
        var hooks = SessionProbeCoordinator.Hooks(prepare: { _ in [] }, emit: { if $0.kind == .completed { terminal.append($0.outcome) } })
        _ = try #require(try coordinator.start(mode: .foreground, hooks: hooks))
        await coordinator.waitUntilFinished()
        #expect(terminal == [.unavailable])
        let backend = ProbeBackend()
        hooks.supportedModes = [.background]
        hooks.prepare = { _ in [.init(id: "fake", backend: backend, measuresKickstart: false)] }
        _ = try #require(try coordinator.start(mode: .background, hooks: hooks))
        await coordinator.waitUntilFinished()
        #expect(terminal == [.unavailable, .backgroundTransitionFailed])
        #expect(await backend.created == 0)
        #expect(throws: SessionProbeError.unsupportedMode) { try coordinator.start(mode: .backgroundAudio, hooks: hooks) }
    }

    @Test @MainActor func ownedCancellationAndExpiryJoinCleanupBeforeCompletion() async throws {
        for expired in [false, true] {
            let coordinator = SessionProbeCoordinator(), entered = ProbeSignal(), release = ProbeSignal()
            var order: [String] = [], terminal: SessionProbeOutcome?
            let hooks = SessionProbeCoordinator.Hooks(reserve: { _ in entered.open(); await release.wait(); try Task.checkCancellation() },
                prepare: { _ in Issue.record("Cancelled preparation must not start"); return [] },
                cleanup: { _ in order.append("cleanup") }, releaseReservations: { _ in order.append("unreserve") },
                emit: { if $0.kind == .completed { terminal = $0.outcome; order.append("terminal") } })
            let id = try #require(try coordinator.start(mode: .foreground, hooks: hooks))
            await entered.wait()
            coordinator.cancel(id: id, expired: expired)
            release.open()
            await coordinator.waitUntilFinished()
            #expect(terminal == (expired ? .expired : .cancelled))
            #expect(order == ["cleanup", "unreserve", "terminal"])
        }
    }

    @Test @MainActor func cancellationRestoresModelsInAnUncancelledJoinedTask() async throws {
        let coordinator = SessionProbeCoordinator(), entered = ProbeSignal(), release = ProbeSignal()
        let backend = ProbeBackend()
        var order: [String] = [], terminal: SessionProbeOutcome?
        let hooks = SessionProbeCoordinator.Hooks(releaseAppModels: { _ in order.append("release") },
            prepare: { _ in entered.open(); await release.wait(); return [.init(id: "fake", backend: backend, measuresKickstart: false, release: { await backend.releaseWarmResources() })] },
            cleanup: { _ in order.append("cleanup") },
            restoreAppModels: { _ in try Task.checkCancellation(); order.append("restored") },
            releaseReservations: { _ in order.append("unreserve") },
            emit: { if $0.kind == .completed { terminal = $0.outcome; order.append("terminal") } })
        let id = try #require(try coordinator.start(mode: .foreground, hooks: hooks))
        await entered.wait()
        coordinator.cancel(id: id)
        release.open()
        await coordinator.waitUntilFinished()
        #expect(order == ["release", "cleanup", "restored", "unreserve", "terminal"])
        #expect(terminal == .cancelled)
        #expect(await backend.releases == 1)
    }

    @Test @MainActor func failedPartialReservationReleasesOwnershipWithoutRestoringUntouchedModels() async throws {
        let coordinator = SessionProbeCoordinator()
        var order: [String] = []
        let hooks = SessionProbeCoordinator.Hooks(reserve: { _ in order.append("reserve"); throw SessionProbeError.busy },
            prepare: { _ in Issue.record("Busy probe must not prepare"); return [] },
            restoreAppModels: { _ in Issue.record("Models were not released") },
            releaseReservations: { _ in order.append("unreserve") }, emit: { if $0.kind == .completed { order.append("terminal") } })
        _ = try #require(try coordinator.start(mode: .foreground, hooks: hooks))
        await coordinator.waitUntilFinished()
        #expect(order == ["reserve", "unreserve", "terminal"])
        #expect(!coordinator.isRunning)
    }

    @Test @MainActor func runningSchedulerJobMakesProbeBusyAndIsNotCancelled() async throws {
        let entered = ProbeSignal(), release = ProbeSignal(), cancelled = Mutex(false)
        let scheduler = ProcessingScheduler(clock: { 0 }, sample: { .idle }, isRecording: { false }, pollInterval: nil,
            work: { _ in await entered.open(); await release.wait(); cancelled.withLock { $0 = Task.isCancelled }; return true })
        await scheduler.enqueue(UUID())
        let running = Task { await scheduler.tick() }
        await entered.wait()
        await #expect(throws: SessionProbeError.busy) { try await scheduler.reserveForProbe(UUID()) }
        release.open()
        await running.value
        #expect(!cancelled.withLock { $0 })
    }

    @Test @MainActor func cancellationDuringRestorationIsReportedAfterRestorationSettles() async throws {
        let coordinator = SessionProbeCoordinator(), entered = ProbeSignal(), release = ProbeSignal()
        var terminal: SessionProbeOutcome?, restoreWasCancelled = true
        let hooks = SessionProbeCoordinator.Hooks(prepare: { _ in [] }, restoreAppModels: { _ in
            entered.open(); await release.wait(); restoreWasCancelled = Task.isCancelled
        }, emit: { if $0.kind == .completed { terminal = $0.outcome } })
        let id = try #require(try coordinator.start(mode: .foreground, hooks: hooks))
        await entered.wait()
        coordinator.cancel(id: id)
        #expect(terminal == nil)
        release.open()
        await coordinator.waitUntilFinished()
        #expect(!restoreWasCancelled)
        #expect(terminal == .cancelled)
    }

    @Test @MainActor func leavingBackgroundDuringMeasurementsIsAnInterruption() async throws {
        let coordinator = SessionProbeCoordinator(measurements: .init(sleep: { _ in })), backend = ProbeBackend()
        var state = "background", events: [SessionProbeEvent] = []
        let hooks = SessionProbeCoordinator.Hooks(supportedModes: [.background],
            prepare: { _ in [.init(id: "fake", backend: backend, measuresKickstart: false)] },
            waitForBackground: { true }, snapshot: { .init(appState: state) },
            emit: { event in
                events.append(event)
                if event.measurement?.turn == "1" { state = "active" }
            })
        _ = try #require(try coordinator.start(mode: .background, hooks: hooks))
        await coordinator.waitUntilFinished()
        #expect(events.last?.outcome == .backgroundTransitionFailed)
        #expect(events.last?.snapshot.appState == "active")
        #expect(await backend.openSessions == 0)
    }

    @Test @MainActor func meetingReservationBlocksAudioAndManualWorkAndRollsBackBusy() async throws {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let root = URL.temporaryDirectory.appending(path: "legato-harness-task4a-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let models = ModelServices(root: root, defaults: defaults, platform: .macOS, installers: [:])
        let services = MeetingServices(models: models, store: MeetingStore(root: root.appending(path: "meetings")),
            settings: MeetingSettings(defaults: defaults), keyStore: InMemoryAPIKeyStore(), pollInterval: nil)
        let owner = UUID()
        services.setRecording(true)
        await #expect(throws: SessionProbeError.busy) { try await services.reserveForProbe(owner) }
        #expect(!services.isProbeReserved)
        services.setRecording(false)
        try await services.reserveForProbe(owner)
        #expect(services.isProbeReserved)
        await #expect(throws: SessionProbeError.busy) { try await services.processAfterStop(UUID()) }
        await #expect(throws: SessionProbeError.busy) { try await services.improveTranscript(meetingID: UUID()) }
        await services.releaseProbeReservation(UUID())
        #expect(services.isProbeReserved)
        await services.releaseProbeReservation(owner)
        #expect(!services.isProbeReserved)
    }

    @Test func warmupReservationBlocksNormalAdmissionAndSurvivesInvalidate() async throws {
        let warmup = SelectedModelWarmup(), owner = UUID()
        let resource = SelectedModelWarmup.Resource(key: "speech", prewarm: {}, release: {})
        try await warmup.prepare([resource], inBackground: false)
        try await warmup.reserveForProbe(owner)
        await #expect(throws: SessionProbeError.busy) { try await warmup.acquire(keys: ["speech"], inBackground: true) }
        await warmup.invalidate()
        await #expect(throws: SessionProbeError.busy) { try await warmup.prepare([resource], inBackground: false) }
        await warmup.releaseProbeReservation(UUID())
        await #expect(throws: SessionProbeError.busy) { try await warmup.prepare([resource], inBackground: false) }
        await warmup.releaseProbeReservation(owner)
        try await warmup.prepare([resource], inBackground: false)
        await warmup.invalidate()
    }

    @Test func activeLeaseMakesProbeBusyWithoutCancellingItsOwner() async throws {
        let warmup = SelectedModelWarmup()
        let resource = SelectedModelWarmup.Resource(key: "refine", prewarm: {}, release: {})
        try await warmup.prepare([resource], inBackground: false)
        let lease = try await warmup.acquire(keys: ["refine"], inBackground: true)
        await #expect(throws: SessionProbeError.busy) { try await warmup.reserveForProbe(UUID()) }
        #expect(await warmup.isReady(for: ["refine"]))
        await lease.release()
        await warmup.invalidate()
    }

    @Test func idleSchedulerReservationKeepsDeferredJobsQueued() async throws {
        let runs = Mutex<[UUID]>([]), id = UUID(), owner = UUID()
        let scheduler = ProcessingScheduler(clock: { 0 }, sample: { .idle }, isRecording: { false }, pollInterval: nil,
            work: { id in runs.withLock { $0.append(id) }; return true })
        await scheduler.enqueue(id)
        try await scheduler.reserveForProbe(owner)
        await scheduler.tick()
        #expect(runs.withLock { $0 } == [])
        #expect(await scheduler.queued == [id])
        await #expect(throws: SessionProbeError.busy) { try await scheduler.perform(for: UUID()) { 1 } }
        await scheduler.releaseProbeReservation(owner)
        await scheduler.tick()
        #expect(runs.withLock { $0 } == [id])
    }
}

@MainActor final class ProbeSignal {
    private var opened = false
    private var waiters: [AsyncStream<Void>.Continuation] = []
    func wait() async {
        guard !opened, !Task.isCancelled else { return }
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        waiters.append(continuation)
        for await _ in stream { return }
    }
    func open() { opened = true; let pending = waiters; waiters = []; for waiter in pending { waiter.yield(()); waiter.finish() } }
}

actor ProbeBackend: LLMBackend, ModelResourceLifecycle {
    nonisolated let id = "probe-fake"
    nonisolated let maxPromptCharacters: Int? = nil
    var availability: LLMAvailability { .available }
    private(set) var created = 0
    private(set) var openSessions = 0
    private(set) var releases = 0
    var failTurn = false
    var failPrepare = false
    func setFailTurn() { failTurn = true }
    func setFailPrepare() { failPrepare = true }
    func prewarmResources() async throws { if failPrepare { throw LLMError.failed("preparation") } }
    func releaseWarmResources() { releases += 1 }
    func respond(instructions: String, prompt: String) async throws -> String { "stateless" }
    func makeSession() async throws -> any LLMSession {
        created += 1; openSessions += 1
        return ProbeSession(owner: self, fail: failTurn)
    }
    func didClose() { openSessions -= 1 }
}
private actor ProbeSession: LLMSessionMetrics {
    nonisolated let tokenBudget = 4000
    let owner: ProbeBackend
    let fail: Bool
    private var closed = false
    init(owner: ProbeBackend, fail: Bool) { self.owner = owner; self.fail = fail }
    func usage() async throws -> LLMTokenUsage { .init(head: 1, history: 2) }
    func append(_ chunk: LLMSessionChunk) async throws { try Task.checkCancellation() }
    func warm() async throws { try Task.checkCancellation() }
    func respond(to request: String) async throws -> String { if fail { throw LLMError.failed("fake") }; try Task.checkCancellation(); return "timber" }
    func respondStructured<Output: LLMStructuredOutput>(_ type: Output.Type, to request: String) async throws -> Output { throw LLMError.failed("unused") }
    func trim(keepingSuffix tokens: Int) async throws {}
    func close() async { if !closed { closed = true; await owner.didClose() } }
    func lastTurnMetrics() async -> LLMTurnMetrics? { .init(promptTokens: 40, prefilledTokens: 3, prefillSeconds: 0.002) }
    func lastWarmMetrics() async -> LLMTurnMetrics? { .init(promptTokens: 80, prefilledTokens: 80, prefillSeconds: 0.004) }
}
