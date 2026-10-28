import Foundation
import LegatoCore
import LegatoModels
import LegatoPostProcessing
import Synchronization
import Testing
@testable import LegatoAppServices
import LegatoMLX

private func freshDefaults() -> UserDefaults {
    UserDefaults(suiteName: "legato-appservices-tests-\(UUID().uuidString)")!
}

private func emptyManager() -> ModelManager {
    ModelManager(
        root: FileManager.default.temporaryDirectory.appending(path: "legato-appservices-\(UUID().uuidString)"),
        catalog: [], installers: [:], selection: SelectionStore(defaults: freshDefaults()))
}

/// Answers with the prompt it got; `available` decides its availability.
private final class FakeFoundationModels: LLMBackend {
    let id = "fm"
    let maxPromptCharacters: Int? = nil
    let available: Bool
    init(available: Bool) { self.available = available }
    var availability: LLMAvailability { get async { available ? .available : .unavailable(reason: "off in tests") } }
    func respond(instructions: String, prompt: String) async throws -> String { prompt }
}

private final class Recorder: Sendable {
    private let state = Mutex<(starts: Int, reports: [CleanupRunReport])>((0, []))
    var starts: Int { state.withLock { $0.starts } }
    var reports: [CleanupRunReport] { state.withLock { $0.reports } }
    func started() { state.withLock { $0.starts += 1 } }
    func record(_ report: CleanupRunReport) { state.withLock { $0.reports.append(report) } }
}

@Suite struct CleanupSettingsStoreTests {
    @Test func defaultsAreOffReplaceVerbatimAutoNoITNFourSeconds() {
        let store = CleanupSettingsStore(defaults: freshDefaults())
        #expect(store.enabled == false)
        #expect(store.delivery == .replace)
        #expect(store.style == .verbatim)
        #expect(store.backend == .auto)
        #expect(store.itn == false)
        #expect(store.timeoutSeconds == 4)
    }

    @Test func valuesPersistInTheDefaults() {
        let defaults = freshDefaults()
        let store = CleanupSettingsStore(defaults: defaults)
        store.enabled = true
        store.delivery = .hold
        store.style = .message
        store.backend = .foundationModels
        store.itn = true
        store.timeoutSeconds = 7
        let again = CleanupSettingsStore(defaults: defaults)
        #expect(again.options == CleanupOptions(
            enabled: true, delivery: .hold, style: .message, backend: .foundationModels, itn: true, timeoutSeconds: 7))
    }

    @Test func timeLimitIsClampedToOneThroughTen() {
        let store = CleanupSettingsStore(defaults: freshDefaults())
        store.timeoutSeconds = 30
        #expect(store.timeoutSeconds == 10)
        store.timeoutSeconds = -2
        #expect(store.timeoutSeconds == 1)
    }

    @Test func onlyFoundationModelsPrefersFoundationModels() {
        #expect(CleanupBackendChoice.foundationModels.preference == .foundationModels)
        #expect(CleanupBackendChoice.auto.preference == .auto)
        #expect(CleanupBackendChoice.mlx.preference == .auto)
    }
}

@Suite struct CleanupProcessorTests {
    private func processor(
        _ store: CleanupSettingsStore, fmAvailable: Bool = true, recorder: Recorder
    ) -> CleanupProcessor {
        CleanupProcessor(
            registry: CleanupRegistry(models: emptyManager(), foundationModels: FakeFoundationModels(available: fmAvailable)),
            settings: store,
            willRun: { recorder.started() },
            report: { recorder.record($0) })
    }

    @Test func offReturnsTheTextUntouchedAndRunsNothing() async throws {
        let store = CleanupSettingsStore(defaults: freshDefaults())
        let recorder = Recorder()
        let out = try await processor(store, recorder: recorder).process("hello world", locale: Locale(identifier: "en_US"))
        #expect(out == "hello world")
        #expect(recorder.starts == 0)
        #expect(recorder.reports.isEmpty)
    }

    @Test func onAnnouncesTheRunAndReportsTheBackendAndStyle() async throws {
        let store = CleanupSettingsStore(defaults: freshDefaults())
        store.enabled = true
        store.style = .message
        let recorder = Recorder()
        _ = try await processor(store, recorder: recorder).process("hello world", locale: Locale(identifier: "en_US"))
        #expect(recorder.starts == 1)
        #expect(recorder.reports.count == 1)
        #expect(recorder.reports.first?.backend == "Apple Foundation Models")
        #expect(recorder.reports.first?.style == .message)
        #expect(recorder.reports.first?.refine == false)
    }

    @Test func reportsWhyNoLanguageModelRan() async throws {
        let store = CleanupSettingsStore(defaults: freshDefaults())
        store.enabled = true
        let recorder = Recorder()
        let out = try await processor(store, fmAvailable: false, recorder: recorder)
            .process("hello world", locale: Locale(identifier: "en_US"))
        #expect(out == "hello world")
        #expect(recorder.reports.first?.backend == "None (no language model)")
        #expect(recorder.reports.first?.skipped == ["Apple Foundation Models unavailable: off in tests"])
    }
}

// MARK: background cleanup (the phone app in the background: no GPU)

/// Says the files are there; enough for the manager to call a model installed once its marker is written.
private struct PresentInstaller: ModelInstaller {
    let folderName: String
    func installFolder(root: URL) -> URL { root.appending(path: folderName, directoryHint: .isDirectory) }
    func isInstalled(root: URL) async -> Bool { true }
    func install(root: URL, progress: @escaping @Sendable (Double) -> Void) async throws {}
    func warm(root: URL) async throws {}
}

private struct NamedLLM: LLMBackend {
    let id: String
    let maxPromptCharacters: Int? = nil
    var availability: LLMAvailability { get async { .available } }
    func respond(instructions: String, prompt: String) async throws -> String { prompt }
}

/// A registry whose picked MLX model is installed, with the GPU usable or not.
private func backgroundRegistry(gpu: Bool) -> CleanupRegistry {
    let spec = MLXModels.spec(id: MLXModels.qwen3_1_7bID)!
    let root = FileManager.default.temporaryDirectory.appending(path: "legato-appservices-\(UUID().uuidString)")
    let installer = PresentInstaller(folderName: "mlx/\(spec.folderName)")
    try? InstallMarker.write(in: installer.installFolder(root: root), id: spec.id, stage: .installed)
    let selection = SelectionStore(defaults: freshDefaults())
    selection.set(spec.id, for: .cleanup)
    let manager = ModelManager(root: root, catalog: [spec.descriptor], installers: [spec.id: installer], selection: selection)
    return CleanupRegistry(
        models: manager, foundationModels: FakeFoundationModels(available: true),
        makeMLXBackend: { _, _ in NamedLLM(id: "gpu") }, makeCPUBackend: { _, _ in NamedLLM(id: "cpu") },
        canUseGPU: { gpu })
}

@Suite struct BackgroundCleanupSettingTests {
    @Test func backgroundCleanupDefaultsToTheCpu() {
        #expect(CleanupSettingsStore(defaults: freshDefaults()).backgroundCleanup == .cpu)
    }

    @Test func backgroundCleanupPersists() {
        let defaults = freshDefaults()
        CleanupSettingsStore(defaults: defaults).backgroundCleanup = .foundationModels
        #expect(CleanupSettingsStore(defaults: defaults).backgroundCleanup == .foundationModels)
        #expect(CleanupSettingsStore(defaults: defaults).options.background == .foundationModels)
    }

    @Test func aBackgroundRunReportsTheCpu() async throws {
        let store = CleanupSettingsStore(defaults: freshDefaults())
        store.enabled = true
        let recorder = Recorder()
        let processor = CleanupProcessor(
            registry: backgroundRegistry(gpu: false), settings: store, report: { recorder.record($0) })
        _ = try await processor.process("hello world", locale: Locale(identifier: "en_US"))
        #expect(recorder.reports.first?.backend == "Qwen3 1.7B (4-bit)")
        #expect(recorder.reports.first?.device == "CPU")
    }

    @Test func aForegroundRunReportsTheGpu() async throws {
        let store = CleanupSettingsStore(defaults: freshDefaults())
        store.enabled = true
        let recorder = Recorder()
        let processor = CleanupProcessor(
            registry: backgroundRegistry(gpu: true), settings: store, report: { recorder.record($0) })
        _ = try await processor.process("hello world", locale: Locale(identifier: "en_US"))
        #expect(recorder.reports.first?.device == "GPU")
    }

    @Test func theSettingReachesTheRegistry() async throws {
        let store = CleanupSettingsStore(defaults: freshDefaults())
        store.enabled = true
        store.backgroundCleanup = .off
        let recorder = Recorder()
        let processor = CleanupProcessor(
            registry: backgroundRegistry(gpu: false), settings: store, report: { recorder.record($0) })
        let out = try await processor.process("hello world", locale: Locale(identifier: "en_US"))
        #expect(out == "hello world")
        #expect(recorder.reports.first?.device == nil)
        #expect(recorder.reports.first?.skipped == [CleanupRegistry.Skip.backgroundCleanupOff.description])
    }
}

// MARK: live delivery

/// Foundation Models stand-in that records the prompts it got and echoes the text inside `<text>` tags.
private final class EchoingFoundationModels: LLMBackend {
    let id = "fm"
    let maxPromptCharacters: Int? = nil
    private let prompts = Mutex<[String]>([])
    var sent: [String] { prompts.withLock { $0 } }
    var availability: LLMAvailability { get async { .available } }
    func respond(instructions: String, prompt: String) async throws -> String {
        prompts.withLock { $0.append(prompt) }
        return "<text>How are you?</text>"
    }
}

/// Answers "How are you?" after a fixed delay, so a run's time is measurable.
private struct SlowFoundationModels: LLMBackend {
    static let delayMs = 40
    let id = "fm"
    let maxPromptCharacters: Int? = nil
    var availability: LLMAvailability { get async { .available } }
    func respond(instructions: String, prompt: String) async throws -> String {
        try await Task.sleep(for: .milliseconds(Self.delayMs))
        return "<text>How are you?</text>"
    }
}

@Suite struct LiveCleanupProcessorTests {
    private func processor(_ store: CleanupSettingsStore, fm: EchoingFoundationModels, recorder: Recorder) -> CleanupProcessor {
        CleanupProcessor(
            registry: CleanupRegistry(models: emptyManager(), foundationModels: fm), settings: store,
            willRun: { recorder.started() }, report: { recorder.record($0) })
    }

    @Test func theLiveStopIsLimitedToTheSettingsTimeLimitWhileCleanupIsOn() {
        let store = CleanupSettingsStore(defaults: freshDefaults())
        store.timeoutSeconds = 7
        let p = processor(store, fm: EchoingFoundationModels(), recorder: Recorder())
        #expect(p.liveStopTimeLimit == nil, "cleanup off: the stop has nothing to limit")
        store.enabled = true
        #expect(p.liveStopTimeLimit == .seconds(7))
    }

    @Test func onlyTheLiveDeliveryCleansSegmentsLive() {
        let store = CleanupSettingsStore(defaults: freshDefaults())
        let p = processor(store, fm: EchoingFoundationModels(), recorder: Recorder())
        store.delivery = .live
        #expect(!p.cleansSegmentsLive, "cleanup off")
        store.enabled = true
        #expect(p.cleansSegmentsLive)
        for other in [CleanupDelivery.replace, .clipboard, .hold] {
            store.delivery = other
            #expect(!p.cleansSegmentsLive)
        }
    }

    @Test func aPassIsCleanedWithItsContextAndWithoutTheCleaningUpPhase() async throws {
        let store = CleanupSettingsStore(defaults: freshDefaults())
        store.enabled = true
        store.delivery = .live
        let fm = EchoingFoundationModels()
        let recorder = Recorder()
        let out = try await processor(store, fm: fm, recorder: recorder)
            .cleanLivePass("how are you", context: "Hello world.", locale: Locale(identifier: "en_US"), atStop: false)
        #expect(out.text == "How are you?")
        #expect(out.backend == "Apple Foundation Models")
        #expect(!out.guardRejected && !out.timedOut)
        #expect(fm.sent.first?.hasPrefix("<before>\nHello world.\n</before>\n") == true)
        #expect(recorder.starts == 0, "the run is still listening")
        #expect(recorder.reports.count == 1)
    }

    @Test func theReadoutOfALiveRunCoversAllItsPasses() async throws {
        let store = CleanupSettingsStore(defaults: freshDefaults())
        store.enabled = true
        store.delivery = .live
        let recorder = Recorder()
        let p = CleanupProcessor(
            registry: CleanupRegistry(models: emptyManager(), foundationModels: SlowFoundationModels()), settings: store,
            report: { recorder.record($0) })
        let en = Locale(identifier: "en_US")
        p.liveRunStarts()
        _ = try await p.cleanLivePass("how are you", context: "", locale: en, atStop: false) // changed
        _ = try await p.cleanLivePass("How are you?", context: "How are you?", locale: en, atStop: false) // unchanged
        let last = try #require(recorder.reports.last)
        #expect(last.changed, "a pass changed, so the run did")
        #expect(last.milliseconds >= 2 * SlowFoundationModels.delayMs, "the time of both passes")
        #expect(last.backend == "Apple Foundation Models")
        #expect(last.refine == false)
    }

    @Test func aNewLiveRunStartsAFreshReadout() async throws {
        let store = CleanupSettingsStore(defaults: freshDefaults())
        store.enabled = true
        store.delivery = .live
        let recorder = Recorder()
        let p = CleanupProcessor(
            registry: CleanupRegistry(models: emptyManager(), foundationModels: SlowFoundationModels()), settings: store,
            report: { recorder.record($0) })
        let en = Locale(identifier: "en_US")
        p.liveRunStarts()
        _ = try await p.cleanLivePass("how are you", context: "", locale: en, atStop: false)
        p.liveRunStarts()
        let clock = ContinuousClock()
        let started = clock.now
        _ = try await p.cleanLivePass("How are you?", context: "", locale: en, atStop: false)
        let elapsed = started.duration(to: clock.now)
        let last = try #require(recorder.reports.last)
        #expect(!last.changed, "only this run's pass counts")
        // The readout fits inside this pass's own wall time, so the first run's pass (at least delayMs) is not in it.
        // Relative to the measured pass, not a fixed bound, so a slow runner can't fail it.
        let elapsedMs = Int((Double(elapsed.components.attoseconds) / 1e15).rounded(.up)) + Int(elapsed.components.seconds) * 1000
        #expect(last.milliseconds <= elapsedMs, "this pass took \(elapsedMs) ms")
    }

    @Test func theStopPassAnnouncesItself() async throws {
        let store = CleanupSettingsStore(defaults: freshDefaults())
        store.enabled = true
        store.delivery = .live
        let recorder = Recorder()
        _ = try await processor(store, fm: EchoingFoundationModels(), recorder: recorder)
            .cleanLivePass("how are you", context: "", locale: Locale(identifier: "en_US"), atStop: true)
        #expect(recorder.starts == 1)
    }

    @Test func aPassWhoseReplyTheGuardRejectsSaysSo() async throws {
        let store = CleanupSettingsStore(defaults: freshDefaults())
        store.enabled = true
        store.delivery = .live
        let p = CleanupProcessor(
            registry: CleanupRegistry(
                models: emptyManager(), foundationModels: AnsweringFoundationModels(reply: "The capital of France is Paris, a city on the Seine with many museums.")),
            settings: store, report: { _ in })
        let out = try await p.cleanLivePass(
            "what is the capital of france", context: "", locale: Locale(identifier: "en_US"), atStop: false)
        #expect(out.text == "what is the capital of france", "the raw text is kept")
        #expect(out.guardRejected)
    }

    @Test func withCleanupOffAPassChangesNothing() async throws {
        let store = CleanupSettingsStore(defaults: freshDefaults())
        let out = try await processor(store, fm: EchoingFoundationModels(), recorder: Recorder())
            .cleanLivePass("how are you", context: "", locale: Locale(identifier: "en_US"), atStop: false)
        #expect(out == LivePassResult(text: "how are you"))
    }
}

/// Foundation Models stand-in that answers every prompt with `reply`.
private struct AnsweringFoundationModels: LLMBackend {
    let reply: String
    let id = "fm"
    let maxPromptCharacters: Int? = nil
    var availability: LLMAvailability { get async { .available } }
    func respond(instructions: String, prompt: String) async throws -> String { "<text>\(reply)</text>" }
}


@Suite struct CleanupOutcomeReportTests {
    private struct Backend: LLMBackend {
        let id = "test"
        let maxPromptCharacters: Int? = nil
        let fails: Bool
        var availability: LLMAvailability { .available }
        func respond(instructions: String, prompt: String) async throws -> String {
            if fails { throw LLMError.failed("No result") }
            return "hello world"
        }
    }
    @Test func backendFailureIsNotReportedAsCompleted() async throws {
        let store = CleanupSettingsStore(defaults: freshDefaults())
        store.enabled = true
        let recorder = Recorder()
        let processor = CleanupProcessor(registry: CleanupRegistry(models: emptyManager(), foundationModels: Backend(fails: true)), settings: store, report: { recorder.record($0) })
        let result = try await processor.process("hello world", locale: Locale(identifier: "en"))
        #expect(result == "hello world")
        #expect(recorder.reports.last?.outcome == "rawOrUnavailable")
    }
    @Test func unchangedSuccessfulOutputIsCompleted() async throws {
        let store = CleanupSettingsStore(defaults: freshDefaults())
        store.enabled = true
        let recorder = Recorder()
        let processor = CleanupProcessor(registry: CleanupRegistry(models: emptyManager(), foundationModels: Backend(fails: false)), settings: store, report: { recorder.record($0) })
        let result = try await processor.process("hello world", locale: Locale(identifier: "en"))
        #expect(result == "hello world")
        #expect(recorder.reports.last?.outcome == "completed")
    }
}
