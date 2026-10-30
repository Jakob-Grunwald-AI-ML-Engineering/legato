import Foundation
import LegatoCore
import LegatoCoreML
import LegatoModels
import Synchronization
import Testing
@testable import LegatoAppServices

@Suite(.timeLimit(.minutes(1))) @MainActor struct SessionProbeBackendTests {
    @Test func harbourMeasurementsCloseEverySessionAndKeepEventsTextFree() async throws {
        let backend = ProbeBackend()
        var measurements: [SessionProbeMeasurement] = [], gaps: [Duration] = []
        let runner = SessionProbeMeasurements(now: { 1 }, sleep: { gaps.append($0) })
        try await runner.run(.init(id: "fake", backend: backend, measuresKickstart: true)) { measurements.append($0) }
        #expect(measurements.map(\.turn) == ["1", "2", "2.fresh", "kickstart.head", "kickstart.warm", "kickstart.warmPrefix", "kickstart.cold"])
        let replay = try #require(measurements.first { $0.turn == "2.fresh" })
        #expect(replay.replyEqual == true)
        #expect(measurements.first?.promptTokens == 40)
        #expect(measurements.first?.prefilledTokens == 3)
        #expect(measurements.first?.prefillMs == 2)
        #expect(gaps == [.seconds(2), .seconds(2), .seconds(2)])
        #expect(await backend.created == 5)
        #expect(await backend.openSessions == 0)
        let encoded = try String(decoding: JSONEncoder().encode(measurements), as: UTF8.self)
        #expect(!encoded.contains("timber"))
        #expect(!encoded.contains("harbour master"))
    }
    @Test func failedMeasurementStillClosesNativeSession() async throws {
        let backend = ProbeBackend(); await backend.setFailTurn()
        await #expect(throws: LLMError.self) {
            try await SessionProbeMeasurements(sleep: { _ in }).run(.init(id: "fake", backend: backend, measuresKickstart: false)) { _ in }
        }
        #expect(await backend.created == 1)
        #expect(await backend.openSessions == 0)
    }
    @Test func cancellationDuringKickstartClosesItsSessionBeforeReturning() async throws {
        let entered = ProbeSignal(), release = ProbeSignal(), backend = ProbeBackend()
        let runner = SessionProbeMeasurements(sleep: { _ in entered.open(); await release.wait(); try Task.checkCancellation() })
        let work = Task { try await runner.run(.init(id: "fake", backend: backend, measuresKickstart: true)) { _ in } }
        await entered.wait()
        work.cancel(); release.open()
        switch await work.result {
        case .success: Issue.record("Cancelled kickstart must fail")
        case .failure(let error): #expect(error is CancellationError)
        }
        #expect(await backend.created == 3)
        #expect(await backend.openSessions == 0)
    }
    @Test func partialPreparationFailureReleasesBothTheFailedAndEarlierBackend() async throws {
        let root = URL.temporaryDirectory.appending(path: "legato-harness-task4a-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let defaults = UserDefaults(suiteName: UUID().uuidString)!, backend = ProbeBackend(), foundation = ProbeBackend()
        await backend.setFailPrepare()
        let id = CoreMLModels.qwen3_1_7bID, owner = UUID()
        try InstallMarker.write(in: ProbeInstaller().installFolder(root: root), id: id, stage: .installed)
        let models = ModelServices(root: root, defaults: defaults, platform: .macOS, installers: [id: ProbeInstaller()],
            resources: .init(speech: .init(key: "speech:fake", prewarm: {}, release: {}), foundation: foundation, coreML: { _, _ in backend }))
        SelectionStore(defaults: defaults).set(id, for: .cleanup)
        try await models.reserveForProbe(owner)
        await #expect(throws: LLMError.self) { try await models.prepareProbeBackends(owner: owner) }
        #expect(await foundation.releases == 1)
        #expect(await backend.releases == 1)
        #expect(models.isProbeReserved)
        await models.releaseProbeReservation(owner)
    }
    @Test func absentWeightsNeverInvokeNativeFactoryOrInstaller() async throws {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!, backend = ProbeBackend()
        let calls = Mutex(0), owner = UUID(), id = CoreMLModels.qwen3_1_7bID
        let models = ModelServices(root: URL.temporaryDirectory.appending(path: "legato-harness-task4a-\(UUID())"),
            defaults: defaults, platform: .macOS, installers: [id: ProbeInstaller()],
            resources: .init(speech: .init(key: "speech:fake", prewarm: {}, release: {}), foundation: backend,
                coreML: { _, _ in calls.withLock { $0 += 1 }; return backend }))
        SelectionStore(defaults: defaults).set(id, for: .cleanup)
        try await models.reserveForProbe(owner)
        let prepared = try await models.prepareProbeBackends(owner: owner)
        #expect(prepared.map(\.id) == ["foundation-models"])
        #expect(calls.withLock { $0 } == 0)
        for descriptor in prepared { await descriptor.release() }
        await models.releaseProbeReservation(owner)
    }
    @Test func activeRefineLeaseMakesModelReservationBusyThenOwnerCanRestore() async throws {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!, backend = ProbeBackend(), owner = UUID()
        let models = ModelServices(root: .temporaryDirectory.appending(path: "legato-harness-task4a-\(UUID())"),
            defaults: defaults, platform: .macOS, installers: [:], resources: .init(
                speech: .init(key: "speech:fake", prewarm: {}, release: {}), foundation: backend, coreML: { _, _ in backend }))
        let settings = CleanupSettingsStore(defaults: defaults)
        settings.backend = .foundationModels
        let lease = try await models.acquireRefine(options: settings.options, inBackground: false)
        await #expect(throws: SessionProbeError.busy) { try await models.reserveForProbe(owner) }
        #expect(!models.isProbeReserved)
        await lease.release()
        try await models.reserveForProbe(owner)
        await models.releaseSelectedModels()
        await #expect(throws: SessionProbeError.busy) { try await models.prepareSelectedModels(options: settings.options, inBackground: false) }
        try await models.restoreProbeResources(owner: owner, options: settings.options, inBackground: false)
        #expect(models.isProbeReserved)
        #expect(await models.selectedModelsAreWarm(options: settings.options))
        await #expect(throws: SessionProbeError.busy) { try await models.acquireRefine(options: settings.options, inBackground: false) }
        var pickError: SessionProbeError?
        models.pick(CoreMLModels.qwen3_1_7bID, role: .cleanup) { pickError = $0 as? SessionProbeError }
        #expect(pickError == .busy)
        await models.releaseProbeReservation(owner)
        #expect(!models.isProbeReserved)
        await models.releaseSelectedModels()
    }
    @Test func instanceModelRootAndOverrideFactoryPrepareOnlyInstalledSelection() async throws {
        let root = URL.temporaryDirectory.appending(path: "legato-harness-task4a-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let id = CoreMLModels.qwen3_1_7bID, backend = ProbeBackend(), foundation = ProbeBackend()
        let observed = Mutex<[URL]>([])
        try InstallMarker.write(in: ProbeInstaller().installFolder(root: root), id: id, stage: .installed)
        let models = ModelServices(root: root, defaults: defaults, platform: .macOS, installers: [id: ProbeInstaller()],
            resources: .init(speech: .init(key: "speech:fake", prewarm: {}, release: {}), foundation: foundation,
                coreML: { _, root in observed.withLock { $0.append(root) }; return backend }))
        SelectionStore(defaults: defaults).set(id, for: .cleanup)
        let owner = UUID()
        try await models.reserveForProbe(owner)
        #expect(models.isProbeReserved)
        let descriptors = try await models.prepareProbeBackends(owner: owner)
        #expect(descriptors.map(\.id) == ["foundation-models", "coreml:\(id)"])
        #expect(observed.withLock { $0 } == [root])
        #expect(descriptors.map(\.measuresKickstart) == [false, true])
        await #expect(throws: SessionProbeError.invalidOwner) { try await models.prepareProbeBackends(owner: UUID()) }
        for descriptor in descriptors { await descriptor.release() }
        await models.releaseProbeReservation(owner)
        #expect(!models.isProbeReserved)
    }
}
private struct ProbeInstaller: ModelInstaller {
    func installFolder(root: URL) -> URL { root.appending(path: "installed") }
    func isInstalled(root: URL) async -> Bool { true }
    func install(root: URL, progress: @escaping @Sendable (Double) -> Void) async throws { Issue.record("Probe must not download") }
    func warm(root: URL) async throws { Issue.record("Probe must not select or warm via installer") }
}
