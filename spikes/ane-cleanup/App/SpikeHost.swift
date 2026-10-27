import ActivityKit
import ANECleanupCore
import AVFAudio
import Foundation
import CryptoKit
import LegatoAppleSpeech
import LegatoAudio
import LegatoCore
import LegatoMLX
import LegatoPostProcessing
import MLX
import Observation
import Speech
import Synchronization
import UIKit

final class TraceContext: Sendable {
    let values = Mutex([String: String]())
    let recorder: RunRecorder
    let workers = WorkerOwnership()
    let invocations = BackendInvocationLedger()
    init(recorder: RunRecorder) { self.recorder = recorder }
    func set(_ fields: [String: String]) { values.withLock { $0.merge(fields) { _, new in new } } }
    func emit(_ name: String, _ fields: [String: String] = [:]) {
        if name == "prefill.begin" || name == "inference.apiBegin" {
            set(["inferenceState": values.withLock { $0["appState"] ?? "unknown" }])
        }
        if name == "cleanup.begin" { set(["cleanupState": values.withLock { $0["appState"] ?? "unknown" }, "inputChars": fields["inputChars"] ?? "0"]) }
        if name == "cleanup.pipelineEnd" {
            set(["cleanupTimedOut": fields["timedOut"] ?? "false", "cleanupGuardRejected": fields["guardRejected"] ?? "false"])
        }
        if name == "backend.response" { set(["backendSucceeded": fields["succeeded"] ?? "false"]) }
        recorder.event(name, fields: values.withLock { $0.merging(fields) { _, new in new } })
    }
}
struct SpikeCleanup: TranscriptPostProcessor {
    let id = "spike-cleanup"
    let backend: any LLMBackend
    let trace: TraceContext
    func process(_ text: String, locale: Locale) async throws -> String {
        trace.emit("cleanup.begin", ["inputChars": String(text.count)])
        let invocation = trace.values.withLock { $0["runID"] ?? "" }
        let stage = LLMCleanupStage(backend: ObservedBackend(base: backend, trace: trace, runID: invocation), prompt: .standard)
        let report = await PostProcessingPipeline(stages: [stage], timeout: .seconds(60)).processReporting(text, locale: locale)
        if report.timedOut || Task.isCancelled { trace.workers.cancel() }
        trace.emit("cleanup.pipelineEnd", ["timedOut": String(report.timedOut), "guardRejected": String(report.guardRejected), "outputChars": String(report.text.count)])
        return report.text
    }
}

private struct ObservedBackend: LLMBackend {
    let base: any LLMBackend
    let trace: TraceContext
    let runID: String
    var id: String { base.id }
    var maxPromptCharacters: Int? { base.maxPromptCharacters }
    var availability: LLMAvailability { get async { await base.availability } }
    func respond(instructions: String, prompt: String) async throws -> String {
        try await respond(instructions: instructions, examples: [], prompt: prompt)
    }
    func respond(instructions: String, examples: [LLMExample], prompt: String) async throws -> String {
        try Task.checkCancellation()
        try trace.workers.beginWorker(runID: runID)
        defer { trace.workers.finishWorker(cancelled: Task.isCancelled) }
        trace.set(["backendInvocationRunID": runID, "backendSucceeded": "false"])
        trace.emit("backend.begin")
        if !base.id.hasPrefix("anemll") { trace.emit("inference.apiBegin") }
        let reply = try await trace.invocations.respond(runID: runID) {
            try await base.respond(instructions: instructions, examples: examples, prompt: prompt)
        }
        trace.emit("backend.response", ["succeeded": String(!reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)])
        return reply
    }
}

@MainActor @Observable final class SpikeHost {
    static let shared = SpikeHost()
    var status = "Tests are controlled from your computer. Complete setup if prompted."
    var selectedBackend = UserDefaults.standard.string(forKey: "backend") ?? "anemll"
    var selectedModel = UserDefaults.standard.string(forKey: "model") ?? "gemma3-1b"
    var selectedFixture = "de-short-01-time"
    var localeID = UserDefaults.standard.string(forKey: "locale") ?? "de-DE"
    var synthetic = false
    var bucket = 0
    var outputCap = 1024
    var busy = false
    var recording = false
    var lastText = ""
    var setupComplete: Bool { SpikeIDs.defaults.bool(forKey: "setupComplete") }
    let recorder: RunRecorder
    let context: TraceContext
    private let engine = AppleSpeechEngine()
    private var session: DictationSession?
    private var activityID: String?
    private var ane: ANEMLLBackend?
    private var operation: Task<Void, Never>?
    private var assertion = UIBackgroundTaskIdentifier.invalid
    private var armedForeground = false
    private var lastRequestID: UUID?
    private var runID = ""
    private var trigger = ""
    private var startClass = ""
    private var resolvedMLXFolder: URL?
    private var resolvedMLXSpec: MLXModelSpec?
    private var loadedBaselineIDs: Set<String> = []
    private var cancellationRequestedAt: Date?
    private var backendForRun: (any LLMBackend)?
    private var launchArgumentsHandled = false
    private let remoteCommands = RunLease()
    private var insertionPoll: Task<Void, Never>?

    static var state: String {
        switch UIApplication.shared.applicationState { case .active: "active"; case .inactive: "inactive"; case .background: "background"; @unknown default: "unknown" }
    }
    static var buildConfiguration: String {
        #if DEBUG
        "Debug (wiring only)"
        #else
        "Release (detached timing eligible)"
        #endif
    }
    private init() {
        // Private app container: results and models never share production history or settings.
        let output = URL.documentsDirectory.appending(path: "Results", directoryHint: .isDirectory)
        recorder = try! RunRecorder(directory: output)
        context = TraceContext(recorder: recorder)
        context.set(["appState": Self.state, "runID": "none", "build": Self.buildConfiguration])
        context.emit("launch")
        let center = NotificationCenter.default
        for (note, label) in [(UIApplication.didBecomeActiveNotification, "active"),
                              (UIApplication.didEnterBackgroundNotification, "background"),
                              (UIApplication.willResignActiveNotification, "inactive")] {
            center.addObserver(forName: note, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.context.workers.observe(state: label); self?.context.set(["appState": label]); self?.context.emit("lifecycle", ["state": label]) }
            }
        }
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), Unmanaged.passUnretained(self).toOpaque(), { _, pointer, _, _, _ in
            guard let pointer else { return }
            let host = Unmanaged<SpikeHost>.fromOpaque(pointer).takeUnretainedValue()
            Task { @MainActor in await host.receiveRequest() }
        }, SpikeIDs.requestNote as CFString, nil, .deliverImmediately)
        SpikeIDs.defaults.set("Open the spike to finish setup.", forKey: "status")
    }
    func trace(_ name: String, _ fields: [String: String] = [:]) {
        context.workers.observe(state: Self.state)
        context.set(["appState": Self.state])
        context.emit(name, fields)
    }
    private func publish(_ text: String) {
        status = text
        SpikeIDs.defaults.set(text, forKey: "status")
        SpikeIDs.defaults.synchronize()
    }
    func setup() async {
        guard !busy && !remoteCommands.isRunning && reusable() else { return }
        busy = true; defer { busy = false }
        publish("Requesting microphone and speech access…")
        let granted = await AVAudioApplication.requestRecordPermission()
        trace("setup.microphonePermission", ["granted": String(granted)])
        let speech = await PermissionBridge.request { completion in
            SFSpeechRecognizer.requestAuthorization { @Sendable status in completion(status == .authorized) }
        }
        trace("setup.speechPermission", ["granted": String(speech)])
        guard granted && speech && ActivityAuthorizationInfo().areActivitiesEnabled else {
            publish("Microphone, speech permission and Live Activities must be enabled in Settings."); return
        }
        publish("Preparing Apple Speech assets…")
        for await _ in engine.installAssets(locale: Locale(identifier: localeID)) {}
        do {
            guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: localeID)) else {
                throw LLMError.unavailable(reason: "Speech locale unsupported")
            }
            let module = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
            guard await AssetInventory.status(forModules: [module]) == .installed else {
                throw LLMError.unavailable(reason: "Apple Speech assets are not installed yet")
            }
            SpikeIDs.defaults.set(true, forKey: "setupComplete")
            publish("Setup complete. Ready for tests from your computer.")
        } catch { publish("Setup failed: \(error.localizedDescription)") }
    }
    func handle(_ url: URL) async {
        guard url.scheme == SpikeIDs.scheme else { return }
        if url.host == "cancel" { trace("remote.cancelURL"); cancel(); return }
        if url.host == "arm" { await arm() }
        if url.host == "fixture" || url.host == "unload" {
            for _ in 0..<50 {
                if Self.state == "active" { break }
                try? await Task.sleep(for: .milliseconds(100))
            }
            guard Self.state == "active" else { trace("url.refusedNonForeground"); return }
            let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let options = Dictionary(query.compactMap { item in item.value.map { (item.name, $0) } }, uniquingKeysWith: { _, last in last })
            await remoteCommand(options, trigger: "foregroundURLFixture", unloadOnly: url.host == "unload")
        }
    }

    private func selectBackend() async -> any LLMBackend {
        if selectedBackend == "foundation-models" { return FoundationModelsBackend() }
        if selectedBackend == "mlx-cpu" {
            // Process-global policy: this isolated host has no MLX GPU runs.
            // CPU streams alone do not disable MLXNN compiled activations on iOS.
            MLX.compile(enable: false)
            let id = selectedModel.hasPrefix("gemma") ? MLXModels.gemma3_1bID : selectedModel == "qwen3-1.7b" ? MLXModels.qwen3_1_7bID : MLXModels.qwen3_0_6bID
            let spec = MLXModels.spec(id: id)!
            let folder = URL.documentsDirectory.appending(path: "Models/mlx/\(spec.folderName)")
            resolvedMLXFolder = folder; resolvedMLXSpec = spec
            return MLXBackend(spec: spec, folder: folder, device: .cpu)
        }
        if let ane { return ane }
        let family: PromptFamily = selectedModel.hasPrefix("gemma") ? .gemma3 : .qwen3
        let context = context
        let new = ANEMLLBackend(folder: URL.documentsDirectory.appending(path: "Models/\(selectedModel)"), family: family,
                                event: { context.emit($0, $1) })
        ane = new
        return new
    }
    private func reusable() -> Bool {
        do { try context.workers.requireReusable(); return true }
        catch { publish(context.workers.isQuarantined ? "Cancelled baseline is quarantined. Restart only the spike process before another run." : "Waiting for backend worker settlement."); return false }
    }
    func resetModel() async {
        guard !busy && !recording && reusable() else { return }
        await session?.endLease(); session = nil; armedForeground = false
        if let ane { try? await ane.unload() }
        ane = nil
        if let folder = resolvedMLXFolder { await MLXModels.release(folder: folder) }
        resolvedMLXFolder = nil; resolvedMLXSpec = nil; loadedBaselineIDs.removeAll()
        publish("Model unloaded. Next request is model cold; process remains resident.")
    }
    private func makeSession() async -> DictationSession {
        let backend = await selectBackend()
        backendForRun = backend
        if selectedBackend == "anemll", let ane { await ane.configure(outputCap: 1024, exactBucket: nil) }
        return DictationSession(engine: engine, source: MicSource(), sessionControl: AudioSessionController(),
            history: JSONLHistoryStore(fileURL: URL.documentsDirectory.appending(path: "spike-history.jsonl")),
            postProcessor: SpikeCleanup(backend: backend, trace: context), linger: .off)
    }
    func arm() async {
        guard !busy && !recording && !remoteCommands.isRunning && setupComplete && reusable() else { publish("Finish setup before arming."); return }
        busy = true; defer { busy = false }
        if session == nil { session = await makeSession() }
        do {
            await session?.adoptLinger(.seconds(60))
            try await session?.armLease(locale: Locale(identifier: localeID))
            armedForeground = true
            publish("Microphone armed for 60 seconds. Return to the other app and tap the spike keyboard.")
            trace("microphone.armed", ["seconds": "60", "foregroundArmed": "true"])
        } catch { publish("Arm failed: \(error.localizedDescription)"); trace("arm.failed", ["error": String(describing: error)]) }
    }
    func toggle(trigger: String) async {
        guard !busy && !remoteCommands.isRunning else { return }
        if recording { await stop(); return }
        guard setupComplete else { publish("Open the spike and finish setup first."); return }
        busy = true; defer { busy = false }
        runID = UUID().uuidString; self.trigger = trigger
        do { try context.workers.beginRun(id: runID, opaqueCancellation: selectedBackend != "anemll", state: Self.state) } catch { publish("Backend cannot start another run."); return }
        let entryState = Self.state
        context.set(["runID": runID, "trigger": trigger, "cleanupTimedOut": "false", "cleanupGuardRejected": "false", "backendSucceeded": "false", "inferenceState": "notStarted"])
        cancellationRequestedAt = nil
        trace("trigger.entry", ["entryState": entryState])
        if session == nil { session = await makeSession() }
        startClass = StartClassification.classify(entryState: entryState, recordingState: Self.state,
                                                   foregroundHop: false, armedForeground: armedForeground)
        let reusedArmedLease = armedForeground && session?.leaseState == .armed
        do {
            try await RecordingStartPolicy.start(trigger: trigger, requestActivity: {
                try Activity.request(attributes: SpikeRecordingAttributes(runID: runID),
                    content: ActivityContent(state: .init(phase: "starting"), staleDate: nil), pushType: nil).id
            }, activityUnavailable: { error in
                trace("activity.requestFailed", ["policy": "bestEffort", "error": String(describing: error)])
            }, startRecording: { requestedActivityID in
                activityID = requestedActivityID
                try await session?.start(locale: Locale(identifier: localeID))
            })
            await session?.adoptLinger(.off)
            startClass = StartClassification.classify(entryState: entryState, recordingState: Self.state,
                foregroundHop: false, armedForeground: reusedArmedLease)
            recording = true
            publish("Recording (\(startClass)). Tap again to stop.")
            await Self.updateActivity(id: activityID, phase: "recording")
            trace("recording.start", ["classification": startClass, "actualState": Self.state])
        } catch {
            trace("recording.failed", ["classification": startClass, "error": String(describing: error)])
            publish("Recording failed (no foreground retry): \(error.localizedDescription)")
            await Self.endActivity(id: activityID); activityID = nil
            await session?.endLease(); session = nil; armedForeground = false
        }
    }
    private func beginCompletion() {
        assertion = UIApplication.shared.beginBackgroundTask(withName: "ANE spike completion") { [weak self] in
            guard let self else { return }
            self.requestCancellation()
            self.context.workers.cancel()
            self.trace("runtime.expired")
            self.ane?.lease.cancel()
            self.operation?.cancel()
            self.endCompletion()
        }
        trace("runtime.begin", ["remainingSeconds": String(UIApplication.shared.backgroundTimeRemaining)])
    }
    private func endCompletion() {
        if assertion != .invalid { UIApplication.shared.endBackgroundTask(assertion); assertion = .invalid }
    }
    private func stop() async {
        guard let session else { return }
        busy = true
        recording = false
        trace("recording.stop")
        publish("Finishing ASR and cleanup…")
        beginCompletion()
        await Self.updateActivity(id: activityID, phase: "cleanup")
        let run = runID
        let voiceHeader = await measurementHeader(workload: selectedBackend == "anemll" ? "voiceCleanupLastChunk" : "voiceCleanupEndToEnd",
            classification: startClass, cap: selectedBackend == "foundation-models" ? nil : 1024, backendID: backendForRun?.id ?? selectedBackend)
        recorder.record(voiceHeader)
        operation = Task { [self] in
            defer { endCompletion(); busy = false; operation = nil }
            var row = voiceHeader
            let stopStarted = ContinuousClock.now
            let memory = MemorySampler()
            let memoryTask = Task.detached {
                while !Task.isCancelled { memory.sample(); try? await Task.sleep(for: .milliseconds(50)) }
            }
            defer { memoryTask.cancel() }
            do {
                let entry = try await session.stop()
                await context.workers.waitUntilSettled()
                if let ane { await ane.waitUntilSettled() }
                if let entry {
                    row.outputCharacters = entry.text.count
                    row.inputCharacters = (entry.rawText ?? entry.text).count
                    row.rawPreserved = entry.rawText != nil
                    lastText = entry.text
                    SpikeIDs.defaults.set(try? JSONEncoder().encode(SpikeResult(runID: run, text: entry.text, created: Date())), forKey: "result")
                    SpikeIDs.defaults.synchronize()
                    UIPasteboard.general.string = entry.text
                    trace("result.published", ["chars": String(entry.text.count), "rawPreserved": String(entry.rawText != nil)])
                    publish("Result ready (\(entry.text.count) characters). Return to the spike keyboard to insert.")
                    observeInsertion(run: run)
                } else { publish("No transcript produced.") }
            } catch {
                let info = error as NSError
                row.error = "\(type(of: error)) \(info.domain) \(info.code)"
                publish("Stop failed: \(error.localizedDescription)"); trace("stop.failed", ["error": row.error ?? "unknown"])
            }
            if Task.isCancelled { context.workers.cancel() }
            await context.workers.waitUntilSettled()
            if let ane { await ane.waitUntilSettled() }
            let outcome = context.values.withLock { $0 }
            row.appStateAtInference = outcome["inferenceState"] ?? "notStarted"
            let invocations = context.invocations.summary(for: run)
            row.backendInvocationCount = invocations.invocationCount
            row.backendSuccessfulInvocationCount = invocations.successfulInvocationCount
            row.backendFailedInvocationCount = invocations.failedInvocationCount
            row.metricScope = "Outcome/guard status and invocation counts cover all cleanup chunks; endToEndMs covers ASR finish plus all cleanup chunks."
            row.status = invocations.voiceStatus(cancelled: cancellationRequestedAt != nil || Task.isCancelled,
                timedOut: outcome["cleanupTimedOut"] == "true", guardRejected: outcome["cleanupGuardRejected"] == "true",
                capped: false)
            row.guardAccepted = invocations.guardAccepted(guardRejected: outcome["cleanupGuardRejected"] == "true")
            if selectedBackend == "anemll", context.workers.wasInvoked(runID: run), outcome["backendInvocationRunID"] == run, let ane, let metrics = await ane.lastMetrics() {
                row.metricScope = "Token/phase metrics cover the last cleanup chunk only; outcome/guard status and invocation counts cover all cleanup chunks; endToEndMs covers ASR finish plus all cleanup chunks."
                row.executedBackend = "anemll-coreml"
                row.renderedPromptSHA256 = metrics.renderedPromptSHA256
                row.inputTokens = metrics.inputTokens; row.outputTokens = metrics.outputTokens
                row.contextLength = metrics.contextLength; row.stopReason = metrics.stopReason
                row.modelLoadMs = metrics.modelLoadMs; row.tokenizerLoadMs = metrics.tokenizerLoadMs
                row.tokenizationMs = metrics.tokenizationMs; row.prefillMs = metrics.prefillMs
                row.firstTokenMs = metrics.firstTokenMs; row.decodeMs = metrics.decodeMs
                row.cacheState = metrics.modelWasLoaded ? "warm weights; fresh KV" : "modelCold"
                if metrics.stopReason == "max_tokens", row.status == "rawOrUnavailable" { row.status = "capped" }
            } else if invocations.successfulInvocationCount > 0 {
                row.executedBackend = backendForRun?.id
            }
            if row.error != nil { row.status = "failed" }
            memory.sample(); row.sampledPeakBytes = memory.sampledPeakBytes
            row.endToEndMs = Double(stopStarted.duration(to: .now) / .milliseconds(1))
            row.cancellationRequestedAt = cancellationRequestedAt; row.publicBackendReturnedAt = Date()
            row.settledAt = context.workers.isQuarantined ? nil : Date()
            row.appStateAtSettlement = Self.state; row.foregroundInterruptedAt = context.workers.foregroundInterruptedAt
            row.backgroundCompletionEligible = context.workers.backgroundEligible(settlementState: Self.state)
            if row.startClassification.hasPrefix("backgroundFixture"), row.backgroundCompletionEligible != true, ["completed", "timingOnly", "timingOnlyCapped", "capped", "guardRejected"].contains(row.status) { row.status = "foregroundInterrupted" }
            row.workerSettlement = context.workers.isQuarantined ? "public API returned; opaque native worker unverified; process restart required" : "owned backend invocation joined"
            recorder.record(row) // No transcript, candidate or final text is included in operational rows.
            await session.endLease()
            self.session = nil; armedForeground = false
            await Self.endActivity(id: activityID); activityID = nil
            trace(context.workers.isQuarantined ? "run.quarantined" : "run.settled")
        }
        await operation?.value
    }
    private func observeInsertion(run: String) {
        insertionPoll?.cancel()
        insertionPoll = Task { [weak self] in
            for _ in 0..<120 {
                guard !Task.isCancelled else { return }
                SpikeIDs.defaults.synchronize()
                if SpikeIDs.defaults.string(forKey: "insertedRun") == run {
                    self?.recorder.event("keyboard.insertAcknowledged", fields: ["runID": run]); return
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }
    private func receiveRequest() async {
        SpikeIDs.defaults.synchronize()
        guard let data = SpikeIDs.defaults.data(forKey: "request"), let request = try? JSONDecoder().decode(SpikeRequest.self, from: data),
              request.id != lastRequestID, (0...10).contains(Date().timeIntervalSince(request.created)), ["toggle", "fixture"].contains(request.command) else { return }
        lastRequestID = request.id
        SpikeIDs.defaults.set(request.id.uuidString, forKey: "ack")
        trace("keyboard.request", ["requestID": request.id.uuidString])
        if request.command == "fixture" { await runFixture(trigger: "keyboardFixture") }
        else { await toggle(trigger: "keyboard") }
    }
    private func measurementHeader(workload: String, classification: String, cap: Int?, backendID: String) async -> ANECleanupCore.Measurement {
        let revision = selectedModel == "gemma3-1b" ? "a1b00f628f348c8ff55c9fe088e5db97535fd567"
            : selectedModel == "qwen3-1.7b" ? "0977a61d00e39118aab5ed1e510f1d228df5eefd" : "c1899de289a04d12100db370d81485cdf75e47ca"
        let actualRevision = selectedBackend == "anemll" ? revision : selectedBackend == "mlx-cpu"
            ? resolvedMLXSpec!.revision : "system-managed; exact model version unavailable; \(ProcessInfo.processInfo.operatingSystemVersionString)"
        var header = Measurement(backend: selectedBackend, revision: actualRevision,
            family: selectedBackend == "foundation-models" ? "system semantic prompt" : selectedModel.hasPrefix("gemma") ? "gemma3" : "qwen3", trigger: trigger,
            classification: classification, state: Self.state, buildConfiguration: Self.buildConfiguration)
        header.tokenizerRevision = selectedBackend == "foundation-models" ? nil : actualRevision
        header.workload = workload
        header.prompt = workload == "syntheticPrefill" ? "Synthetic numbered-list continuation; repeated hello input; no cleanup examples; timing only" : header.prompt
        header.buildID = Bundle.main.object(forInfoDictionaryKey: "SpikeBuildID") as? String
        if selectedBackend == "anemll", let ane {
            let artifact = ArtifactProvenance.read(folder: ane.folder)
            header.modelValidation = artifact.modelValidation
            header.artifactManifestSHA256 = artifact.manifestSHA256
            let metadataURL = ane.folder.appending(path: "meta.yaml")
            if let data = try? Data(contentsOf: metadataURL) {
                header.modelMetadataSHA256 = Self.digest(data)
                let yaml = String(decoding: data, as: UTF8.self)
                header.modelQuantization = yaml.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { $0.hasPrefix("lut_") || $0.hasPrefix("precision:") || $0.hasPrefix("quantization:") }.joined(separator: "; ")
            }
            let conversionURL = ane.folder.appending(path: "conversion.json")
            if let data = try? Data(contentsOf: conversionURL) { header.conversionManifestSHA256 = Self.digest(data) }
        }
        header.cacheState = selectedBackend == "anemll" ? (await ane!.isLoaded() ? "warm weights; fresh KV" : "modelCold")
            : selectedBackend == "mlx-cpu" ? (loadedBaselineIDs.contains(backendID) ? "warm weights; fresh session" : "modelCold") : "system-managed; unknown"
        UIDevice.current.isBatteryMonitoringEnabled = true
        header.batteryLevel = UIDevice.current.batteryLevel
        header.batteryState = String(describing: UIDevice.current.batteryState)
        header.runID = runID
        header.outputCap = cap
        return header
    }
    struct Fixture: Decodable {
        let name: String
        let locale: String
        let input: String
        let vocabulary: [String]
        let mustContain: [String]
        let mustNotContain: [String]
    }
    func runFixture(trigger fixtureTrigger: String = "foregroundFixture", remoteOwned: Bool = false) async {
        guard !busy && !recording && (!remoteCommands.isRunning || remoteOwned) && reusable() else { return }
        busy = true
        let wasArmedForeground = armedForeground && session?.leaseState == .armed
        runID = UUID().uuidString; trigger = fixtureTrigger
        do { try context.workers.beginRun(id: runID, opaqueCancellation: selectedBackend != "anemll", state: Self.state) } catch { busy = false; publish("Backend cannot start another run."); return }
        cancellationRequestedAt = nil
        context.set(["runID": runID, "trigger": trigger, "inferenceState": "notStarted"])
        let previousIdleTimer = UIApplication.shared.isIdleTimerDisabled
        if Self.state == "active" {
            UIApplication.shared.isIdleTimerDisabled = true
            trace("fixture.idleTimerDisabled")
        }
        trace("fixture.begin", ["fixture": selectedFixture])
        beginCompletion()
        await session?.endLease(); session = nil; armedForeground = false
        let backend = await selectBackend()
        var header = await measurementHeader(workload: synthetic ? "syntheticPrefill" : "cleanupFixture",
            classification: Self.state == "background" ? (wasArmedForeground ? "backgroundFixtureForegroundArmed" : "backgroundFixture") : "foregroundFixture",
            cap: selectedBackend == "anemll" ? outputCap : selectedBackend == "mlx-cpu" ? 1024 : nil, backendID: backend.id)
        header.fixture = synthetic ? nil : selectedFixture
        let timeoutSeconds = FixtureDeadline.seconds(appState: Self.state, modelCold: header.cacheState == "modelCold")
        header.fixtureDeadlineSeconds = timeoutSeconds
        trace("fixture.deadline", ["seconds": String(timeoutSeconds), "cacheState": header.cacheState])
        recorder.record(header) // durable before model loading or any risky prediction
        operation = Task { [self] in
            var row = header
            defer {
                UIApplication.shared.isIdleTimerDisabled = previousIdleTimer
                endCompletion(); busy = false; operation = nil
            }
            let started = ContinuousClock.now
            let memory = MemorySampler()
            memory.sample()
            let memoryTask = Task.detached {
                while !Task.isCancelled { memory.sample(); try? await Task.sleep(for: .milliseconds(50)) }
            }
            defer { memoryTask.cancel() }
            let deadline = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(timeoutSeconds)) } catch { return }
                self?.requestCancellation()
                self?.context.workers.cancel()
                self?.trace("fixture.timeout", ["seconds": String(timeoutSeconds)])
                self?.ane?.lease.cancel()
                self?.operation?.cancel()
            }
            defer { deadline.cancel() }
            do {
                guard let url = Bundle.main.url(forResource: selectedFixture, withExtension: "json", subdirectory: "Fixtures") else {
                    throw LLMError.failed("Fixture resource missing")
                }
                let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
                if case .unavailable(let reason) = await backend.availability { throw LLMError.unavailable(reason: reason) }
                if let ane, selectedBackend == "anemll" { await ane.configure(outputCap: outputCap, exactBucket: bucket == 0 ? nil : bucket) }
                let prompt = CleanupPrompt.standard
                let locale = Locale(identifier: fixture.locale)
                let semantic = [prompt.instructions(locale, fixture.vocabulary)]
                    + prompt.examples(locale).flatMap { [$0.user, $0.assistant] }
                    + [prompt.userMessage(fixture.input, locale, fixture.vocabulary)]
                row.semanticPromptSHA256 = SHA256.hash(data: Data(semantic.joined(separator: "\u{001E}").utf8)).map { String(format: "%02x", $0) }.joined()
                let reply: String
                if synthetic {
                    guard selectedBackend == "anemll", let ane, [300, 500, 800].contains(bucket) else {
                        throw LLMError.failed("Synthetic mode requires ANEMLL and an explicit 300/500/800 total-token bucket")
                    }
                    row.semanticPromptSHA256 = nil
                    try context.workers.beginWorker(runID: runID)
                    defer { context.workers.finishWorker(cancelled: Task.isCancelled) }
                    reply = try await ane.respondSynthetic(totalInputTokens: bucket)
                } else {
                    reply = try await ObservedBackend(base: backend, trace: context, runID: runID).respond(instructions: prompt.instructions(locale, fixture.vocabulary),
                        examples: prompt.examples(locale), prompt: prompt.userMessage(fixture.input, locale, fixture.vocabulary))
                }
                let extracted = prompt.extractText(reply)
                let accepted = CleanupGuard().accepts(extracted, reference: fixture.input)
                row.rawCandidate = reply; row.extractedText = extracted; row.guardAccepted = accepted
                row.finalText = accepted ? extracted : fixture.input
                row.qualityPassed = accepted && fixture.mustContain.allSatisfy(extracted.contains)
                    && !fixture.mustNotContain.contains(where: extracted.contains)
                row.executedBackend = backend.id; row.status = synthetic ? "timingOnly" : accepted ? "completed" : "guardRejected"
                if synthetic { row.guardAccepted = nil; row.qualityPassed = nil; row.finalText = nil }
                loadedBaselineIDs.insert(backend.id)
                lastText = row.finalText ?? fixture.input
                publish("Fixture \(row.status); quality \(row.qualityPassed == true ? "passed" : "failed").")
            } catch {
                row.status = error is CancellationError ? "cancelled" : (error as? SpikeError) == .contextBudget ? "infeasible" : "failed"
                row.error = String(describing: error)
                publish("Fixture \(row.status): \(error)")
            }
            if Task.isCancelled { context.workers.cancel() }
            await context.workers.waitUntilSettled()
            if let ane, selectedBackend == "anemll" {
                await ane.waitUntilSettled()
                if context.workers.wasInvoked(runID: row.runID) { row.inputTokens = await ane.lastInputTokens() }
                if context.workers.wasInvoked(runID: row.runID), let metrics = await ane.lastMetrics() {
                    row.executedBackend = backend.id
                    row.renderedPromptSHA256 = metrics.renderedPromptSHA256
                    row.inputTokens = metrics.inputTokens; row.outputTokens = metrics.outputTokens
                    row.modelLoadMs = metrics.modelLoadMs; row.tokenizerLoadMs = metrics.tokenizerLoadMs; row.tokenizationMs = metrics.tokenizationMs
                    row.cacheState = metrics.modelWasLoaded ? "warm weights; fresh KV" : "modelCold"
                    row.prefillMs = metrics.prefillMs; row.firstTokenMs = metrics.firstTokenMs; row.decodeMs = metrics.decodeMs
                    row.contextLength = metrics.contextLength; row.sampledPeakBytes = metrics.sampledPeakBytes
                    row.stopReason = metrics.stopReason
                    if metrics.stopReason == "max_tokens" {
                        row.status = synthetic ? "timingOnlyCapped" : "capped"; row.qualityPassed = synthetic ? nil : false
                        row.rawCandidate = await ane.lastCandidate()
                    }
                }
            }
            memory.sample()
            row.sampledPeakBytes = max(row.sampledPeakBytes ?? 0, memory.sampledPeakBytes)
            row.endToEndMs = Double(started.duration(to: .now) / .milliseconds(1))
            row.appStateAtInference = context.values.withLock { $0["inferenceState"] ?? "notStarted" }
            if cancellationRequestedAt != nil || Task.isCancelled { row.status = "cancelled" }
            row.cancellationRequestedAt = cancellationRequestedAt
            row.publicBackendReturnedAt = Date()
            row.settledAt = context.workers.isQuarantined ? nil : Date()
            row.appStateAtSettlement = Self.state; row.foregroundInterruptedAt = context.workers.foregroundInterruptedAt
            row.backgroundCompletionEligible = context.workers.backgroundEligible(settlementState: Self.state)
            if row.startClassification.hasPrefix("backgroundFixture"), row.backgroundCompletionEligible != true, ["completed", "timingOnly", "timingOnlyCapped", "capped", "guardRejected"].contains(row.status) { row.status = "foregroundInterrupted" }
            row.workerSettlement = context.workers.isQuarantined ? "public API returned; opaque native worker unverified; process restart required" : "owned backend invocation joined"
            recorder.record(row)
            trace(context.workers.isQuarantined ? "fixture.quarantined" : "fixture.settled", ["status": row.status])
        }
        await operation?.value
    }
    private func requestCancellation(at date: Date = Date()) {
        cancellationRequestedAt = CancellationTimestamp.retain(first: cancellationRequestedAt, requested: date)
    }
    func cancel() {
        context.workers.cancel()
        requestCancellation()
        trace("cancel.request")
        ane?.lease.cancel()
        operation?.cancel()
        publish("Cancellation requested; waiting for the in-flight prediction to settle.")
    }
    nonisolated private static func updateActivity(id: String?, phase: String) async {
        guard let id else { return }
        await Activity<SpikeRecordingAttributes>.activities.first { $0.id == id }?
            .update(ActivityContent(state: .init(phase: phase), staleDate: nil))
    }
    nonisolated private static func endActivity(id: String?) async {
        guard let id else { return }
        await Activity<SpikeRecordingAttributes>.activities.first { $0.id == id }?
            .end(nil, dismissalPolicy: .immediate)
    }
    nonisolated private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    func runLaunchArguments() async {
        guard !launchArgumentsHandled else { return }
        launchArgumentsHandled = true
        let args = ProcessInfo.processInfo.arguments
        guard args.contains("--spike-run-fixture") else { return }
        func option(_ name: String) -> String? {
            guard let index = args.firstIndex(of: name), args.indices.contains(index + 1) else { return nil }
            return args[index + 1]
        }
        // devicectl launch is a foreground cell only; lifecycle must confirm it before automation runs.
        for _ in 0..<50 {
            if Self.state == "active" { break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard Self.state == "active" else { trace("cli.refusedNonForeground"); return }
        var options: [String: String] = [:]
        for (argument, key) in [("--spike-backend", "backend"), ("--spike-model", "model"),
                                ("--spike-fixture", "fixture"), ("--spike-cap", "cap"),
                                ("--spike-bucket", "bucket"), ("--spike-locale", "locale"),
                                ("--spike-repeat", "repeat")] {
            if let value = option(argument) { options[key] = value }
        }
        options["synthetic"] = args.contains("--spike-synthetic") ? "true" : "false"
        await remoteCommand(options, trigger: "cliForegroundFixture")
    }
    /// Configuration changes and the complete run batch share one lease; callbacks/UI never reset a live model.
    private func remoteCommand(_ options: [String: String], trigger: String, unloadOnly: Bool = false) async {
        guard !busy && !recording && reusable() else { trace("remote.rejectedBusy"); return }
        do { try remoteCommands.begin() } catch { trace("remote.rejectedBusy"); return }
        defer { remoteCommands.settle() }
        let backend = options["backend"] ?? selectedBackend
        let model = options["model"] ?? selectedModel
        let fixture = options["fixture"] ?? selectedFixture
        let cap = options["cap"].flatMap(Int.init) ?? outputCap
        let total = options["bucket"].flatMap(Int.init) ?? bucket
        let repeats = options["repeat"].flatMap(Int.init) ?? 1
        guard ["anemll", "mlx-cpu", "foundation-models"].contains(backend),
              ["gemma3-1b", "qwen3-1.7b", "qwen3-0.6b"].contains(model),
              ["de-short-01-time", "en-short-01-reschedule", "mixed-short-01-meeting"].contains(fixture),
              (1...1024).contains(cap), [0, 300, 500, 800].contains(total), (1...10).contains(repeats) else {
            publish("Invalid remote test configuration."); trace("remote.invalidConfiguration"); return
        }
        if backend != selectedBackend || model != selectedModel || unloadOnly { await resetModel() }
        selectedBackend = backend; selectedModel = model; selectedFixture = fixture
        outputCap = cap; bucket = total
        if let value = options["locale"] { localeID = value }
        if let value = options["synthetic"] { synthetic = value == "true" || value == "1" }
        saveConfiguration()
        trace("remote.configured", ["backend": backend, "model": model, "fixture": fixture, "repeat": String(repeats)])
        if unloadOnly { return }
        for _ in 0..<repeats {
            await runFixture(trigger: trigger, remoteOwned: true)
            if cancellationRequestedAt != nil || !context.workers.canContinueBatch { break }
        }
    }
    func saveConfiguration() {
        UserDefaults.standard.set(selectedBackend, forKey: "backend")
        UserDefaults.standard.set(selectedModel, forKey: "model")
        UserDefaults.standard.set(localeID, forKey: "locale")
    }
}
