import Foundation
import LegatoClaude
import LegatoCore
import LegatoMLX
import LegatoMeetings
import LegatoModels
import Synchronization
import Testing
@testable import LegatoAppServices

/// Installs at once and is installed ever after.
private final class InstantInstaller: ModelInstaller {
    let folderName: String
    init(folderName: String) { self.folderName = folderName }
    func installFolder(root: URL) -> URL { root.appending(path: folderName, directoryHint: .isDirectory) }
    func isInstalled(root: URL) async -> Bool {
        FileManager.default.fileExists(atPath: installFolder(root: root).appending(path: "complete").path)
    }
    func install(root: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        let folder = installFolder(root: root)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: folder.appending(path: "complete"))
    }
    func warm(root: URL) async throws {}
}

private final class FakeLLM: LLMBackend {
    let id: String
    let calls = Mutex(0)
    init(id: String) { self.id = id }
    var maxPromptCharacters: Int? { nil }
    var availability: LLMAvailability { get async { .available } }
    func respond(instructions: String, prompt: String) async throws -> String {
        calls.withLock { $0 += 1 }
        return "## Summary\n\(id)"
    }
}

private func sameInstance(_ a: any DictationEngine, _ b: (any DictationEngine)?) -> Bool {
    guard let b, let x = a as? AnyObject, let y = b as? AnyObject else { return false }
    return x === y
}

private let nemotron = "nemotron-multilingual-560"
private let parakeetEOU = "parakeet-eou-320"

@MainActor
private struct Rig {
    let root = FileManager.default.temporaryDirectory.appending(path: "legato-meeting-services-\(UUID().uuidString)")
    let models: ModelServices
    let store: MeetingStore
    let settings: MeetingSettings
    let keys = InMemoryAPIKeyStore(apiKey: "sk-test")
    let foundation = FakeLLM(id: "fake-fm")
    let claude = FakeLLM(id: "claude")

    init() {
        let suite = "legato.meeting-services.\(UUID().uuidString)"
        let catalog = ModelServices(root: root, defaults: UserDefaults(suiteName: suite + ".a")!, platform: .macOS).catalog
        let installers = Dictionary(uniqueKeysWithValues: catalog.map { ($0.id, InstantInstaller(folderName: $0.id)) })
        models = ModelServices(root: root, defaults: UserDefaults(suiteName: suite + ".b")!, platform: .macOS, installers: installers)
        store = MeetingStore(root: root.appending(path: "Meetings"))
        settings = MeetingSettings(defaults: UserDefaults(suiteName: suite + ".c")!)
    }

    func services(claudeBackend: (any LLMBackend)? = nil) -> MeetingServices {
        MeetingServices(
            models: models, store: store, settings: settings, keyStore: keys,
            cleanup: CleanupRegistry(models: models.manager, foundationModels: foundation),
            claudeBackend: claudeBackend)
    }

    func pick(_ id: String, role: ModelRole = .liveDictation) async throws {
        try await models.manager.select(id, role: role)
    }
}

@MainActor @Suite struct MeetingServicesTests {
    // MARK: Engines

    @Test func theMacRunsAppleSpeechOnBothStreamsWhenEOUIsPicked() async throws {
        let rig = Rig()
        try await rig.pick(parakeetEOU)
        let engines = await rig.services().engines(for: .macOS)
        #expect(engines.mic.id == "apple-speech")
        #expect(engines.system?.id == "apple-speech")
        #expect(engines.engineID == "apple-speech")
        let reason = try #require(engines.fallbackReason)
        #expect(reason.contains("Parakeet EOU") && reason.contains("Apple Speech"))
        #expect(!sameInstance(engines.mic, engines.system), "one instance per stream")
    }

    @Test func enginesPrepareForTheSingleChosenLanguageElseNone() async throws {
        let rig = Rig()
        try await rig.pick(nemotron)
        #expect(await rig.services().engines(for: .macOS).locale == nil)

        rig.models.engineSettings.preferredLocales = [Locale(identifier: "de-DE")]
        #expect(await rig.services().engines(for: .macOS).locale == Locale(identifier: "de-DE"))
        #expect(await rig.services().engines(for: .iOS).locale == Locale(identifier: "de-DE"))

        rig.models.engineSettings.preferredLocales = [Locale(identifier: "de-DE"), Locale(identifier: "en-US")]
        #expect(await rig.services().engines(for: .macOS).locale == nil)
    }

    @Test func iOSKeepsEOUOnItsOneStream() async throws {
        let rig = Rig()
        try await rig.pick(parakeetEOU)
        let engines = await rig.services().engines(for: .iOS)
        #expect(engines.mic.id == parakeetEOU)
        #expect(engines.system == nil)
        #expect(engines.engineID == parakeetEOU)
        #expect(engines.fallbackReason == nil)
    }

    @Test func theMacRunsOneNemotronInstancePerStream() async throws {
        let rig = Rig()
        try await rig.pick(nemotron)
        let engines = await rig.services().engines(for: .macOS)
        #expect(engines.mic.id == nemotron)
        #expect(engines.system?.id == nemotron)
        #expect(engines.fallbackReason == nil)
        #expect(!sameInstance(engines.mic, engines.system))
    }

    @Test func nothingPickedMeansAppleSpeechWithoutAReason() async {
        let rig = Rig()
        let mac = await rig.services().engines(for: .macOS)
        #expect(mac.mic.id == "apple-speech" && mac.system?.id == "apple-speech")
        #expect(mac.fallbackReason == nil)
        let phone = await rig.services().engines(for: .iOS)
        #expect(phone.mic.id == "apple-speech" && phone.system == nil)
    }

    // MARK: Backends

    @Test func theSummaryBackendComesFromTheCleanupRegistryAndIsNeverClaude() async throws {
        let rig = Rig()
        for choice in CleanupBackendChoice.allCases {
            rig.settings.backend = choice
            let backend = await rig.services(claudeBackend: rig.claude).summaryBackend()
            #expect(backend?.id == "fake-fm", "\(choice)")
        }
    }

    @Test func noPostPassModelMeansNoTranscriber() async {
        let rig = Rig()
        #expect(await rig.services().postPassTranscriber() == nil)
    }

    @Test func claudeIsTheClaudeBackend() {
        let rig = Rig()
        #expect(rig.services().claudeBackend() is ClaudeBackend)
    }

    // MARK: Chains

    private func seedProcessing(_ rig: Rig) async throws -> UUID {
        let id = UUID()
        try await rig.store.create(Meeting(id: id, title: "Sync", date: Date(), duration: 10, engineID: "live", state: .processing))
        try await rig.store.appendSegment(MeetingSegment(stream: .mic, text: "we ship friday", start: 0, end: 3), to: id)
        return id
    }

    @Test func theAutomaticChainWritesTheOnDeviceSummaryAndNeverCallsClaude() async throws {
        let rig = Rig()
        let id = try await seedProcessing(rig)
        let outcome = try await rig.services(claudeBackend: rig.claude).pipeline().run(meetingID: id)
        #expect(outcome.summaryBackendID == "fake-fm")
        #expect(try await rig.store.summaries(for: id).map(\.backendID) == ["fake-fm"])
        #expect(rig.claude.calls.withLock { $0 } == 0)
        #expect(try await rig.store.meeting(id: id)?.state == .finished)
    }

    @Test func summarizeWithClaudeWritesItsOwnSummaryOnly() async throws {
        let rig = Rig()
        let id = try await seedProcessing(rig)
        let services = rig.services(claudeBackend: rig.claude)
        _ = try await services.pipeline().run(meetingID: id)
        let url = try await services.summarizeWithClaude(meetingID: id)
        #expect(url.lastPathComponent == "summary-claude.md")
        #expect(rig.claude.calls.withLock { $0 } == 1)
        #expect(Set(try await rig.store.summaries(for: id).map(\.backendID)) == ["fake-fm", "claude"])
        #expect(try await rig.store.summaries(for: id).first?.backendID == "claude", "newest first")
    }

    @Test func theCustomPromptFromSettingsIsUsed() async throws {
        let rig = Rig()
        rig.settings.customPrompt = "Only list decisions."
        let id = try await seedProcessing(rig)
        let capture = PromptCapture()
        let services = MeetingServices(
            models: rig.models, store: rig.store, settings: rig.settings, keyStore: rig.keys,
            cleanup: CleanupRegistry(models: rig.models.manager, foundationModels: capture))
        _ = try await services.pipeline().run(meetingID: id)
        #expect(capture.instructions.withLock { $0.first } == "Only list decisions.")
    }
}

private final class PromptCapture: LLMBackend {
    let id = "capture"
    let instructions = Mutex<[String]>([])
    var maxPromptCharacters: Int? { nil }
    var availability: LLMAvailability { get async { .available } }
    func respond(instructions: String, prompt: String) async throws -> String {
        self.instructions.withLock { $0.append(instructions) }
        return "ok"
    }
}
