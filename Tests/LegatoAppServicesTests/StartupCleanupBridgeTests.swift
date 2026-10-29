import Foundation
import LegatoCore
import LegatoCoreML
import LegatoModels
import LegatoPostProcessing
import Synchronization
import Testing
@testable import LegatoAppServices

private actor BridgeBackend: LLMBackend, ModelResourceLifecycle {
    nonisolated let id: String
    nonisolated let maxPromptCharacters: Int? = nil
    var preparations = 0
    var replies = 0
    var ready = false
    var fails: Bool
    var responseFails = false
    let eligible: Bool
    var gate: BridgeSignal?
    let entered = BridgeSignal()
    init(_ id: String, fails: Bool = false, eligible: Bool = true) {
        self.id = id; self.fails = fails; self.eligible = eligible
    }
    var availability: LLMAvailability { eligible && (id == "foundation" || ready) ? .available : .unavailable(reason: "Not ready") }
    func block(_ gate: BridgeSignal) { self.gate = gate }
    func allowRetry() { fails = false }
    func failResponses() { responseFails = true }
    func prewarmResources() async throws {
        preparations += 1
        await entered.signal()
        if let gate { await gate.wait() }
        try Task.checkCancellation()
        guard eligible else { throw LLMError.unavailable(reason: "Apple Intelligence unavailable") }
        if fails { throw LLMError.failed("Native load failed") }
        ready = true
    }
    func releaseWarmResources() { ready = false }
    func respond(instructions: String, prompt: String) async throws -> String {
        replies += 1
        if responseFails { throw LLMError.failed("Generation failed") }
        return "<text>Hello.</text>"
    }
}
private actor BridgeSignal {
    private var signalled = false
    private var waiters: [AsyncStream<Void>.Continuation] = []
    func wait() async {
        if signalled { return }
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        waiters.append(continuation)
        var iterator = stream.makeAsyncIterator()
        _ = await iterator.next()
    }
    func signal() {
        signalled = true
        for waiter in waiters { waiter.yield(()); waiter.finish() }
        waiters = []
    }
}
private struct BridgeInstaller: ModelInstaller {
    func installFolder(root: URL) -> URL { root.appending(path: "installed") }
    func isInstalled(root: URL) async -> Bool { true }
    func install(root: URL, progress: @escaping @Sendable (Double) -> Void) async throws { Issue.record("No automatic downloads") }
    func warm(root: URL) async throws { Issue.record("No installer warmup") }
}
private final class BridgeEngine: DictationEngine {
    let id: String
    private let preparationCount = Mutex(0)
    init(id: String = "selected-speech") { self.id = id }
    var preparations: Int { preparationCount.withLock { $0 } }
    private let stream = Mutex<AsyncThrowingStream<TranscriptEvent, any Error>.Continuation?>(nil)
    private let final = Mutex<String?>(nil)
    func installAssets(locale: Locale?) -> AsyncStream<Double> { AsyncStream { $0.finish() } }
    func captureFormat(locale: Locale?) async throws -> AudioFormatSpec { .init(sampleRate: 16_000, channelCount: 1) }
    func prepare(locale: Locale?) async throws -> AudioFormatSpec {
        preparationCount.withLock { $0 += 1 }
        return .init(sampleRate: 16_000, channelCount: 1)
    }
    func transcribe(_ input: AsyncStream<AudioChunk>) -> AsyncThrowingStream<TranscriptEvent, any Error> {
        let (events, continuation) = AsyncThrowingStream<TranscriptEvent, any Error>.makeStream()
        stream.withLock { $0 = continuation }; return events
    }
    func emit(_ text: String) { stream.withLock { $0 }?.yield(.init(text: text, isFinal: true)) }
    func finalText(_ text: String) { final.withLock { $0 = text } }
    func finish() async throws {
        if let text = final.withLock({ $0 }) { emit(text) }
        stream.withLock { $0 }?.finish()
    }
}
private actor BridgeSource: AudioSource {
    var starts = 0
    func start(format: AudioFormatSpec) async throws -> AsyncStream<AudioChunk> { starts += 1; return AsyncStream { _ in } }
    func route() async throws -> AsyncStream<AudioChunk> { AsyncStream { _ in } }
    func detach() async {}
    func stop() async {}
}
private struct BridgeControl: AudioSessionControlling {
    let supportedPolicies: Set<AudioPolicy> = [.duckOthers]
    func activate(_ config: SessionConfig) throws {}
    func deactivate() {}
}
private actor BridgeHistory: HistoryStore {
    var entries: [DictationEntry] = []
    func append(_ entry: DictationEntry) { entries.append(entry) }
    func recent(limit: Int) -> [DictationEntry] { Array(entries.suffix(limit)) }
    func delete(id: UUID) { entries.removeAll { $0.id == id } }
}
private actor BridgeReports {
    var reports: [CleanupRunReport] = []
    let first = BridgeSignal()
    func record(_ report: CleanupRunReport) async { reports.append(report); await first.signal() }
}
@MainActor private final class BridgeReadiness: Readiness {
    var recognitionReady = false
    func check() async -> ReadinessIssue? { recognitionReady ? nil : .assetsMissing }
    func checkMicrophone() async -> ReadinessIssue? { nil }
}
@MainActor private final class BridgeActivity: ActivityClient {
    func request(_ content: DictationActivityContent) async throws {}
    func update(_ content: DictationActivityContent, staleDate: Date?) async {}
    func end(_ content: DictationActivityContent) async {}
    func dismiss() async {}
}
@MainActor private final class BridgeClipboard: Clipboard {
    func write(_ text: String) -> Bool { true }
}
private actor BridgeSpeechPreparation {
    let entered = BridgeSignal(), gate = BridgeSignal()
    var preparations = 0
    func prepare() async { preparations += 1; await entered.signal(); await gate.wait() }
}
@MainActor @Suite(.timeLimit(.minutes(1))) struct StartupCleanupBridgeTests {
    @Test(arguments: [false, true])
    func systemEventsRespectOwnershipDuringColdMicrophonePreparation(currentEvent: Bool) async {
        let admission = ModelAdmission(), preparation = BridgeSpeechPreparation()
        let source = BridgeSource(), engine = BridgeEngine(id: "selected-speech")
        let history = BridgeHistory()
        let coordinator = DictationCoordinator(activity: BridgeActivity(), clipboard: BridgeClipboard(),
            readiness: BridgeReadiness(), history: history, makeSession: { policy, linger in
                DictationSession(engine: engine, source: source, sessionControl: BridgeControl(),
                    history: history, policy: policy, linger: linger)
            })
        let oldEvent = coordinator.captureSystemEvent()
        var cancelled = false
        let arming = Task {
            do {
                let outcome = try await admission.admit(isIdle: { coordinator.isIdle },
                    onAdmitted: { coordinator.microphonePreparationBegan() },
                    prepare: { await preparation.prepare() },
                    operation: { await coordinator.arm(keepAlive: .indefinite) })
                #expect(outcome == .armed)
            } catch is CancellationError { cancelled = true }
            catch { Issue.record("Unexpected admission failure: \(error)") }
        }
        await preparation.entered.wait()
        let current = coordinator.captureSystemEvent()
        var rejectedAdmissions = 0
        do {
            try await admission.admit(isIdle: { coordinator.isIdle }, onAdmitted: {
                rejectedAdmissions += 1
                coordinator.microphonePreparationBegan()
            }, prepare: {}, operation: {})
            Issue.record("Concurrent preparation was accepted")
        } catch ModelAdmission.AdmissionError.busy {}
        catch { Issue.record("Unexpected duplicate failure: \(error)") }
        #expect(rejectedAdmissions == 0)
        #expect(coordinator.isCurrent(current))

        let event = currentEvent ? current : oldEvent
        if coordinator.isCurrent(event) {
            admission.cancel() // AppController.endKeepAlive cancels preparation before releasing its mic.
            await coordinator.endKeepAlive()
        }
        await preparation.gate.signal()
        await arming.value
        #expect(cancelled == currentEvent)
        #expect(await source.starts == (currentEvent ? 0 : 1))
        #expect(coordinator.holdsLease == !currentEvent)
        await coordinator.endKeepAlive()
    }

    private func rig(local: BridgeBackend, foundation: BridgeBackend = BridgeBackend("foundation"), installed: Bool = true,
                     speech: SelectedModelWarmup.Resource? = nil, speechID: String? = nil)
        throws -> (ModelServices, CleanupSettingsStore) {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let root = URL.temporaryDirectory.appending(path: UUID().uuidString)
        let id = CoreMLModels.qwen3_1_7bID
        if installed { try InstallMarker.write(in: BridgeInstaller().installFolder(root: root), id: id, stage: .installed) }
        let resources = ModelServiceResources(speech: speech ?? .init(key: "speech:test", prewarm: {}, release: {}),
            foundation: foundation, coreML: { _, _ in local })
        let models = ModelServices(root: root, defaults: defaults, platform: .macOS,
            installers: [id: BridgeInstaller()], resources: resources)
        SelectionStore(defaults: defaults).set(id, for: .cleanup)
        if let speechID { SelectionStore(defaults: defaults).set(speechID, for: .liveDictation) }
        let settings = CleanupSettingsStore(defaults: defaults)
        settings.enabled = true; settings.backend = .coreML
        return (models, settings)
    }

    @Test func coldOwnerReconciliationArmsRealCoordinatorBeforeSpeechAndCleanupThenStartsSelectedRecognition() async throws {
        let local = BridgeBackend("local"), localGate = BridgeSignal(), speech = BridgeSpeechPreparation()
        await local.block(localGate)
        let selectedSpeech = "nemotron-latin-1120"
        let (models, settings) = try rig(local: local, speech: .init(key: "speech:" + selectedSpeech,
            prewarm: { await speech.prepare() }, release: {}), speechID: selectedSpeech)
        let source = BridgeSource(), engine = BridgeEngine(id: selectedSpeech), readiness = BridgeReadiness()
        let history = BridgeHistory(), admission = ModelAdmission()
        let processor = CleanupProcessor(registry: models.cleanup, settings: settings,
            acquireRun: { try await models.acquireDictationCleanup(options: settings.options, inBackground: true) }, report: { _ in })
        let coordinator = DictationCoordinator(activity: BridgeActivity(), clipboard: BridgeClipboard(),
            readiness: readiness, startEnvironment: UnrestrictedStartEnvironment(), history: history,
            makeSession: { policy, linger in
                DictationSession(engine: engine, source: source, sessionControl: BridgeControl(),
                    history: history, postProcessor: processor, policy: policy, linger: linger)
            })
        let armed = try await admission.admit(isIdle: { coordinator.isIdle }, prepare: {
            await models.reconcileSelectedModels(options: settings.options, inBackground: false)
        }, operation: { await coordinator.arm(keepAlive: .indefinite) })
        await speech.entered.wait(); await local.entered.wait()
        #expect(armed == .armed)
        #expect(await source.starts == 1)
        #expect(engine.preparations == 0)
        #expect(!readiness.recognitionReady)
        #expect(!(await models.selectedModelsAreWarm(options: settings.options)))
        let preparingRun = BridgeSignal()
        let start = Task {
            try await admission.admit(isIdle: { coordinator.isIdle }, prepare: {
                await preparingRun.signal()
                try await models.prepareSelectedModels(options: settings.options, inBackground: true)
                readiness.recognitionReady = true
            }, operation: { await coordinator.startIfIdle(.init(keepAlive: .off, target: .keyboard)) })
        }
        await preparingRun.wait()
        #expect(engine.preparations == 0)
        #expect(!readiness.recognitionReady)
        await speech.gate.signal()
        #expect(try await start.value == .started)
        #expect(engine.preparations == 1)
        #expect(await local.ready == false)
        #expect(models.selected(.liveDictation) == selectedSpeech)
        #expect(models.selected(.cleanup) == CoreMLModels.qwen3_1_7bID)
        #expect(settings.backend == .coreML)
        _ = await coordinator.stopIfRunning()
        // Losing the mic lease never relinquishes the retained selected weights.
        let rearmed = try await admission.admit(isIdle: { coordinator.isIdle }, prepare: {
            await models.reconcileSelectedModels(options: settings.options, inBackground: false)
        }, operation: { await coordinator.arm(keepAlive: .indefinite) })
        #expect(rearmed == .armed)
        #expect(await speech.preparations == 1)
        #expect(engine.preparations == 1)
        await coordinator.endKeepAlive()
        await localGate.signal()
        await models.releaseSelectedModels()
    }

    @Test func microphoneExpiryAndRearmPreserveSelectedSpeechPreparation() async throws {
        let local = BridgeBackend("local"), speech = BridgeSpeechPreparation()
        await speech.gate.signal()
        let (models, settings) = try rig(local: local, speech: .init(key: "speech:selected",
            prewarm: { await speech.prepare() }, release: {}))
        try await models.prepareSelectedModels(options: settings.options, inBackground: false)
        let timerEntered = BridgeSignal(), expire = BridgeSignal(), expired = BridgeSignal()
        let engine = BridgeEngine(), source = BridgeSource()
        let session = DictationSession(engine: engine, source: source, sessionControl: BridgeControl(), history: BridgeHistory(),
            linger: .seconds(60), sleep: { _ in
                await timerEntered.signal(); await expire.wait(); try Task.checkCancellation()
            })
        session.onLeaseExpired = { Task { await expired.signal() } }
        try await session.armLease()
        await timerEntered.wait(); await expire.signal(); await expired.wait()
        #expect(session.leaseState == .idle)
        #expect(await models.selectedModelsAreWarm(options: settings.options))
        session.adoptLinger(.indefinite)
        await models.reconcileSelectedModels(options: settings.options, inBackground: false)
        try await session.armLease()
        #expect(session.leaseState == .armed)
        #expect(await speech.preparations == 1)
        #expect(engine.preparations == 0)
        #expect(await source.starts == 2)
        await session.endLease()
        await models.releaseSelectedModels()
    }

    @Test func actualLocalPreparationFailureAdmitsFoundationWithoutChangingSelection() async throws {
        let local = BridgeBackend("local", fails: true), foundation = BridgeBackend("foundation")
        let (models, settings) = try rig(local: local, foundation: foundation)
        do { try await models.prepareSelectedModels(options: settings.options, inBackground: false) }
        catch { Issue.record("Foundation Models should keep activation usable after local load failure: \(error)") }
        #expect(await foundation.preparations == 1)
        #expect(models.selected(.cleanup) == CoreMLModels.qwen3_1_7bID)
        #expect(settings.backend == .coreML)
        await #expect(throws: LLMError.failed("Native load failed")) {
            _ = try await models.acquireRefine(options: settings.options, inBackground: true)
        }
        #expect(models.cleanupPreparation.state == .failed)
        #expect(models.cleanupPreparationNotice != nil)
        try await models.prepareSelectedModels(options: settings.options, inBackground: false)
        #expect(await local.preparations == 1, "Ordinary activation must not retry a genuine failure")
        await local.allowRetry()
        await models.retryCleanupPreparation(inBackground: false)
        let retry = try await models.acquireRefine(options: settings.options, inBackground: false)
        await retry.release()
        #expect(await local.preparations == 2)
        #expect(models.cleanupPreparation.state == .ready)
        #expect(models.cleanupPreparationNotice == nil)
        await models.releaseSelectedModels()
    }

    @Test func captureAndWholeLiveRunUseFoundationUntilNextKeptSessionRun() async throws {
        let local = BridgeBackend("local"), foundation = BridgeBackend("foundation"), gate = BridgeSignal()
        await local.block(gate)
        let (models, settings) = try rig(local: local, foundation: foundation)
        settings.delivery = .live
        let reports = BridgeReports(), source = BridgeSource(), engine = BridgeEngine()
        let processor = CleanupProcessor(registry: models.cleanup, settings: settings,
            acquireRun: { try await models.acquireDictationCleanup(options: settings.options, inBackground: true) },
            report: { await reports.record($0) })
        let session = DictationSession(engine: engine, source: source, sessionControl: BridgeControl(),
            history: BridgeHistory(), postProcessor: processor, linger: .indefinite)
        let admission = ModelAdmission()
        let armed = try await admission.admit(isIdle: { session.runState == .idle }, prepare: {
            try await models.prepareSelectedModels(options: settings.options, inBackground: false)
        }, operation: {
            do { try await session.armLease(); return true }
            catch { Issue.record("Microphone activation failed: \(error)"); return false }
        })
        #expect(armed)
        await local.entered.wait()
        #expect(await source.starts == 1, "Microphone activates while the selected local load is blocked")
        #expect(await local.ready == false)
        #expect(models.cleanupPreparation.state == .preparing)
        #expect(models.cleanupPreparationNotice == nil)
        #expect(await models.selectedModelsAreWarm(options: settings.options))
        try await session.start(locale: Locale(identifier: "en"))
        engine.emit("hello")
        await reports.first.wait()
        await gate.signal()
        let localReady = try await models.acquireRefine(options: settings.options, inBackground: true)
        await localReady.release()
        #expect(models.cleanupPreparation.state == .ready)
        engine.finalText("hello world")
        _ = try await session.stop()
        #expect(await foundation.replies == 2, "Rolling and final passes keep the admitted FM backend")
        #expect(await local.replies == 0)
        #expect(await reports.reports.map(\.backend) == ["Apple Foundation Models", "Apple Foundation Models"])
        try await session.start(locale: Locale(identifier: "en"))
        engine.finalText("hello")
        _ = try await session.stop()
        #expect(await local.replies == 1, "The next run of the kept session admits newly ready Core ML")
        #expect(await source.starts == 1)
        #expect(await reports.reports.last?.backend == "Qwen3 1.7B (Core ML)")
        #expect(models.selected(.cleanup) == CoreMLModels.qwen3_1_7bID)
        #expect(settings.backend == .coreML)
        await session.endLease()
        await models.releaseSelectedModels()
    }

    @Test func unavailableFoundationWaitsForSelectedLocalPreparation() async throws {
        let local = BridgeBackend("local"), foundation = BridgeBackend("foundation", eligible: false), gate = BridgeSignal()
        await local.block(gate)
        let (models, settings) = try rig(local: local, foundation: foundation)
        let preparing = Task { try await models.prepareSelectedModels(options: settings.options, inBackground: false) }
        await local.entered.wait()
        #expect(await models.selectedModelsAreWarm(options: settings.options) == false)
        #expect(await local.ready == false)
        await gate.signal()
        try await preparing.value
        let run = try #require(try await models.acquireDictationCleanup(options: settings.options, inBackground: true))
        #expect(run.resolution.choice == .coreML(modelID: CoreMLModels.qwen3_1_7bID))
        await run.release()
        await models.releaseSelectedModels()
    }

    @Test func missingSelectedWeightsNeverDownloadOrBecomeReady() async throws {
        let local = BridgeBackend("local")
        let (models, settings) = try rig(local: local, installed: false)
        await #expect(throws: LLMError.self) { try await models.prepareSelectedModels(options: settings.options, inBackground: false) }
        #expect(await local.preparations == 0)
        #expect(models.cleanupPreparation.state == .missing)
        #expect(await models.selectedModelsAreWarm(options: settings.options) == false)
        #expect(await models.manager.state(of: CoreMLModels.qwen3_1_7bID) == .notInstalled)
        await models.releaseSelectedModels()
    }

    @Test func disabledCleanupAdmitsOnlySpeechWhileRefineStillPreparesIndependently() async throws {
        let local = BridgeBackend("local"), gate = BridgeSignal()
        await local.block(gate)
        let (models, settings) = try rig(local: local)
        settings.enabled = false
        try await models.prepareSelectedModels(options: settings.options, inBackground: false)
        #expect(await models.selectedModelsAreWarm(options: settings.options))
        #expect(try await models.acquireDictationCleanup(options: settings.options, inBackground: true) == nil)
        #expect(await local.ready == false)
        await gate.signal()
        await models.releaseSelectedModels()
    }

    @Test func coldBackgroundAdmissionCannotStartEitherNativeResource() async throws {
        let local = BridgeBackend("local"), foundation = BridgeBackend("foundation")
        let (models, settings) = try rig(local: local, foundation: foundation)
        await #expect(throws: SelectedModelWarmup.PreparationError.needsForeground) {
            try await models.prepareSelectedModels(options: settings.options, inBackground: true)
        }
        #expect(await local.preparations == 0)
        #expect(await foundation.preparations == 0)
        #expect(await models.selectedModelsAreWarm(options: settings.options) == false)
        await models.releaseSelectedModels()
    }

    @Test func selectionChangeCannotReplaceBackendOfAdmittedNonLiveRun() async throws {
        let local = BridgeBackend("local"), foundation = BridgeBackend("foundation"), gate = BridgeSignal()
        await local.block(gate)
        let (models, settings) = try rig(local: local, foundation: foundation)
        let reports = BridgeReports()
        try await models.prepareSelectedModels(options: settings.options, inBackground: false)
        let processor = CleanupProcessor(registry: models.cleanup, settings: settings,
            acquireRun: { try await models.acquireDictationCleanup(options: settings.options, inBackground: true) },
            report: { await reports.record($0) })
        try await processor.runStarts()
        models.clearPick(.cleanup)
        await #expect(throws: LLMError.self) { try await models.prepareSelectedModels(options: settings.options, inBackground: false) }
        _ = try await processor.process("hello", locale: Locale(identifier: "en"))
        #expect(await foundation.replies == 1)
        #expect(await reports.reports.last?.backend == "Apple Foundation Models")
        #expect(await local.replies == 0)
        await processor.runEnds()
        await gate.signal()
        await models.releaseSelectedModels()
    }

    @Test func pressureRevokesBridgeReadinessAndOldPreparationCannotPublishReady() async throws {
        let local = BridgeBackend("local"), foundation = BridgeBackend("foundation"), gate = BridgeSignal()
        await local.block(gate)
        let (models, settings) = try rig(local: local, foundation: foundation)
        try await models.prepareSelectedModels(options: settings.options, inBackground: false)
        await local.entered.wait()
        await models.releaseSelectedModels()
        #expect(models.cleanupPreparation.state == .idle)
        #expect(await models.selectedModelsAreWarm(options: settings.options) == false)
        await gate.signal()
        #expect(await local.ready == false)
        await #expect(throws: SelectedModelWarmup.PreparationError.needsForeground) {
            try await models.prepareSelectedModels(options: settings.options, inBackground: true)
        }
        #expect(await foundation.preparations == 1, "Background reads cannot restart resources after pressure")
        await models.releaseSelectedModels()
    }

    @Test func cancelledSpeechAdmissionCannotArmWhenSharedPreparationFinishesLater() async throws {
        let local = BridgeBackend("local"), entered = BridgeSignal(), gate = BridgeSignal()
        let speech = SelectedModelWarmup.Resource(key: "speech:test", prewarm: {
            await entered.signal(); await gate.wait(); try Task.checkCancellation()
        }, release: {})
        let (models, settings) = try rig(local: local, speech: speech)
        let source = BridgeSource()
        let session = DictationSession(engine: BridgeEngine(), source: source, sessionControl: BridgeControl(), history: BridgeHistory())
        let admission = ModelAdmission()
        let starting = Task {
            try await admission.admit(isIdle: { session.runState == .idle }, prepare: {
                try await models.prepareSelectedModels(options: settings.options, inBackground: false)
            }, operation: {
                do { try await session.armLease() } catch { Issue.record("Unexpected arm: \(error)") }
            })
        }
        await entered.wait()
        await admission.stop(operation: {})
        await #expect(throws: CancellationError.self) { try await starting.value }
        #expect(await source.starts == 0)
        await gate.signal()
        try await models.prepareSelectedModels(options: settings.options, inBackground: false)
        #expect(await source.starts == 0, "Shared native completion cannot resurrect the cancelled admission")
        await models.releaseSelectedModels()
    }

    @Test func generationFailureKeepsSelectedBackendAndNeverRetriesWithFoundation() async throws {
        let local = BridgeBackend("local"), foundation = BridgeBackend("foundation")
        let (models, settings) = try rig(local: local, foundation: foundation)
        try await models.prepareSelectedModels(options: settings.options, inBackground: false)
        let ready = try await models.acquireRefine(options: settings.options, inBackground: false)
        await ready.release()
        await local.failResponses()
        let reports = BridgeReports()
        let processor = CleanupProcessor(registry: models.cleanup, settings: settings,
            acquireRun: { try await models.acquireDictationCleanup(options: settings.options, inBackground: true) },
            report: { await reports.record($0) })
        try await processor.runStarts()
        #expect(try await processor.process("hello", locale: Locale(identifier: "en")) == "hello")
        #expect(await local.replies == 1)
        #expect(await foundation.replies == 0)
        #expect(await reports.reports.last?.backend == "Qwen3 1.7B (Core ML)")
        #expect(await reports.reports.last?.outcome == "rawOrUnavailable")
        await processor.runEnds()
        await models.releaseSelectedModels()
    }

    @Test func explicitUnavailableFoundationStillAdmitsSpeechAndReportsRawCleanup() async throws {
        let local = BridgeBackend("local"), foundation = BridgeBackend("foundation", eligible: false)
        let (models, settings) = try rig(local: local, foundation: foundation)
        settings.backend = .foundationModels
        let reports = BridgeReports()
        let processor = CleanupProcessor(registry: models.cleanup, settings: settings,
            acquireRun: { try await models.acquireDictationCleanup(options: settings.options, inBackground: true) },
            report: { await reports.record($0) })
        do {
            try await models.prepareSelectedModels(options: settings.options, inBackground: false)
            try await processor.runStarts()
            #expect(try await processor.process("hello", locale: Locale(identifier: "en")) == "hello")
            #expect(await reports.reports.last?.backend == "None (no language model)")
            #expect(await reports.reports.last?.outcome == "rawOrUnavailable")
            #expect(await reports.reports.last?.skipped == ["Apple Foundation Models unavailable: Not ready"])
        } catch { Issue.record("Unavailable explicit Foundation Models must retain usable speech/raw dictation: \(error)") }
        #expect(await local.preparations == 0)
        #expect(await foundation.replies == 0)
        await processor.runEnds()
        await models.releaseSelectedModels()
    }
}
