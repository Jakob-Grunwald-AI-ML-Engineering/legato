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
