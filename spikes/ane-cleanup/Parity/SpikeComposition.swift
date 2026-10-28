import ANECleanupCore
import Foundation
import LegatoAppServices
import LegatoCore
import LegatoPostProcessing
import LegatoVocabulary
import Synchronization
import UIKit

/// The only app-specific ANE composition. Recording, transport, keyboard UI and insertion remain production sources.
@MainActor final class SpikeComposition {
    let admission = ParityAdmission()
    let owner: ParityModelOwner
    let processor: ParityCleanupProcessor
    private let recorder: RunRecorder?
    private let state: ParityAppState
    private let settings: CleanupSettingsStore
    private var observers: [NSObjectProtocol] = []

    init(defaults: UserDefaults, vocabulary: VocabularyService,
         preferredLocale: @escaping @Sendable () -> Locale?,
         report: @escaping @Sendable (CleanupRunReport) async -> Void) {
        let recorder = try? RunRecorder(directory: URL.documentsDirectory.appending(path: "ParityEvidence"))
        self.recorder = recorder
        let state = ParityAppState(Self.appState)
        self.state = state
        let settings = CleanupSettingsStore(defaults: defaults)
        self.settings = settings
        let backend = ANEMLLBackend(
            folder: URL.documentsDirectory.appending(path: ParityBootstrap.modelDirectory), family: .qwen3,
            requiresPreparation: true,
            event: { name, fields in
                recorder?.event(name, fields: fields.merging(["appState": state.value]) { _, new in new })
            })
        let owner = ParityModelOwner(runtime: backend)
        self.owner = owner
        processor = ParityCleanupProcessor(
            owner: owner, settings: settings, preferredLocale: preferredLocale, vocabulary: vocabulary,
            event: { item in
                recorder?.event("cleanup.outcome", fields: [
                    "status": item.status, "invocations": String(item.invocations),
                    "failedInvocations": String(item.failedInvocations), "refine": String(item.refine),
                    "backend": "anemll-coreml", "modelRevision": ParityBootstrap.revision,
                    "computeUnits": "cpuAndNeuralEngine", "anePlacement": "unverified",
                    "appState": state.value, "runID": state.runID,
                ])
            }, report: report)
        for (name, phase) in [
            (UIApplication.didEnterBackgroundNotification, "background"),
            (UIApplication.willEnterForegroundNotification, "inactive"),
            (UIApplication.didBecomeActiveNotification, "active"),
            (UIApplication.willResignActiveNotification, "inactive"),
        ] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
                state.value = phase
                recorder?.event("lifecycle", fields: ["appState": phase])
            })
        }
        record("composition.ready", ["modelRevision": ParityBootstrap.revision,
                                     "retention": "model-resident; configured microphone lease",
                                     "sourceBuildID": Bundle.main.object(forInfoDictionaryKey: "SpikeBuildID") as? String ?? "missing"])
    }
    static var appState: String {
        switch UIApplication.shared.applicationState {
        case .active: "active"
        case .inactive: "inactive"
        case .background: "background"
        @unknown default: "unknown"
        }
    }
    func runStarted(_ runID: String) {
        state.runID = runID
        record("dictation.runStarted", ["runID": runID])
    }
    func prepare(inBackground: Bool) async throws {
        guard settings.enabled else { record("model.prepare.skipped", ["reason": "cleanupDisabled"]); return }
        record("model.prepare.request", ["background": String(inBackground)])
        try await owner.prepare(inBackground: inBackground)
        record("model.ready")
        sampleMemory("model.ready")
    }
    func reset(beforeUnload: @MainActor () async -> Void) async {
        await admission.reset {
            record("model.reset.request")
            // Cancel/invalidate microphone readiness before releasing the model it depended on.
            await beforeUnload()
            do { try await owner.reset(); record("model.reset.settled") }
            catch { record("model.reset.failed", ["errorType": String(describing: type(of: error))]) }
        }
    }
    func refine(_ text: String, locale: Locale) async -> String? {
        let result = await processor.run(text, locale: locale, style: .message,
                                         timeout: .seconds(max(settings.timeoutSeconds * 2, 8)), refine: true)
        let refined = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return refined.isEmpty || refined == text ? nil : refined
    }
    func record(_ name: String, _ fields: [String: String] = [:]) {
        recorder?.event(name, fields: fields.merging(["appState": Self.appState]) { _, new in new })
    }
    func sampleMemory(_ reason: String) {
        let sample = MemorySampler(); sample.sample()
        record("memory.sample", ["reason": reason, "physicalFootprintBytes": String(sample.sampledPeakBytes)])
    }
    isolated deinit { for observer in observers { NotificationCenter.default.removeObserver(observer) } }
}
private final class ParityAppState: Sendable {
    private let state: Mutex<String>
    private let run = Mutex("")
    init(_ initial: String) { state = Mutex(initial) }
    var runID: String {
        get { run.withLock { $0 } }
        set { run.withLock { $0 = newValue } }
    }
    var value: String {
        get { state.withLock { $0 } }
        set { state.withLock { $0 = newValue } }
    }
}
