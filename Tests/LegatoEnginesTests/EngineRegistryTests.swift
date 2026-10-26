import Foundation
import LegatoCore
import LegatoFluidAudio
import LegatoModels
import Synchronization
import Testing

@testable import LegatoEngines

/// Counts install/warm calls; "installed" is a marker file, so tests stage models by writing it.
final class CountingInstaller: ModelInstaller {
    let folderName: String
    private let counts = Mutex((installs: 0, warms: 0))
    init(folderName: String) { self.folderName = folderName }

    var installs: Int { counts.withLock { $0.installs } }
    var warms: Int { counts.withLock { $0.warms } }

    func installFolder(root: URL) -> URL { root.appending(path: folderName, directoryHint: .isDirectory) }
    func isInstalled(root: URL) async -> Bool {
        FileManager.default.fileExists(atPath: installFolder(root: root).appending(path: "ok").path)
    }
    func install(root: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        counts.withLock { $0.installs += 1 }
        try stage(root: root)
        progress(1)
    }
    func warm(root: URL) async throws { counts.withLock { $0.warms += 1 } }

    /// Marks the model installed without counting as an install.
    func stage(root: URL) throws {
        let folder = installFolder(root: root)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(count: 10).write(to: folder.appending(path: "ok"))
    }
}

/// Real speech descriptors over counting fakes, a temp root and a throwaway defaults suite.
struct Rig: @unchecked Sendable {
    let root: URL
    let suite: String
    let defaults: UserDefaults
    let installers: [String: CountingInstaller]

    init() {
        root = FileManager.default.temporaryDirectory.appending(path: "legato-engines-\(UUID().uuidString)", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        suite = "legato.engines.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
        installers = Dictionary(uniqueKeysWithValues: FluidAudioCatalog.descriptors().map { ($0.id, CountingInstaller(folderName: $0.id)) })
    }

    /// A fresh manager and registry over the same root and defaults, like a relaunch.
    func registry() -> EngineRegistry {
        let manager = ModelManager(
            root: root, catalog: FluidAudioCatalog.descriptors(), installers: installers,
            selection: SelectionStore(defaults: defaults))
        return EngineRegistry(models: manager, settings: EngineSettings(defaults: defaults))
    }

    var totalInstalls: Int { installers.values.reduce(0) { $0 + $1.installs } }
    var totalWarms: Int { installers.values.reduce(0) { $0 + $1.warms } }

    func cleanUp() {
        try? FileManager.default.removeItem(at: root)
        defaults.removePersistentDomain(forName: suite)
    }
}

@Suite struct EngineRegistryTests {
    @Test func installedChoiceIsReturnedWithTierAndLocaleSet() async throws {
        let rig = Rig(); defer { rig.cleanUp() }
        try rig.installers["nemotron-multilingual-560"]!.stage(root: rig.root)
        let registry = rig.registry()
        registry.settings.preferredLocales = [Locale(identifier: "de-DE"), Locale(identifier: "en-US")]
        registry.settings.silenceMs = 800
        try await registry.models.select("nemotron-multilingual-560", role: .liveDictation)

        let live = await registry.liveEngine()
        #expect(live.engine.id == "nemotron-multilingual-560")
        #expect(live.modelID == "nemotron-multilingual-560")
        #expect(live.preferredLocales.map(\.identifier) == ["de-DE", "en-US"])
        #expect(live.silenceMs == 800)
        #expect(live.fallback == nil)
    }

    @Test func eouAndLatinChoicesMapToTheirEngines() async throws {
        let rig = Rig(); defer { rig.cleanUp() }
        for id in ["parakeet-eou-320", "nemotron-latin-2240"] {
            try rig.installers[id]!.stage(root: rig.root)
            let registry = rig.registry()
            try await registry.models.select(id, role: .liveDictation)
            #expect(await registry.liveEngine().engine.id == id)
        }
    }

    @Test func missingModelFallsBackToAppleSpeechWithAssetsNotInstalled() async throws {
        let rig = Rig(); defer { rig.cleanUp() }
        // Persisted pick whose files are gone (e.g. deleted outside the app).
        SelectionStore(defaults: rig.defaults).set("nemotron-multilingual-1120", for: .liveDictation)

        let live = await rig.registry().liveEngine()
        #expect(live.engine.id == "apple-speech")
        #expect(live.modelID == nil)
        #expect(live.fallback == .assetsNotInstalled)
        #expect(live.fallback?.dictationError == .assetsNotInstalled)
    }

    @Test func unknownPersistedIDFallsBackWithDistinctReason() async throws {
        let rig = Rig(); defer { rig.cleanUp() }
        SelectionStore(defaults: rig.defaults).set("nemotron-from-the-future", for: .liveDictation)

        let live = await rig.registry().liveEngine()
        #expect(live.engine.id == "apple-speech")
        #expect(live.fallback == .unknownModel("nemotron-from-the-future"))
        #expect(live.fallback?.dictationError == nil)
    }

    @Test func aBatchIDPersistedForLiveCountsAsUnknown() async throws {
        let rig = Rig(); defer { rig.cleanUp() }
        SelectionStore(defaults: rig.defaults).set("parakeet-v3", for: .liveDictation)
        #expect(await rig.registry().liveEngine().fallback == .unknownModel("parakeet-v3"))
    }

    @Test func nothingSelectedIsAppleSpeechWithoutAReason() async {
        let rig = Rig(); defer { rig.cleanUp() }
        let live = await rig.registry().liveEngine()
        #expect(live.engine.id == "apple-speech")
        #expect(live.fallback == nil)
        #expect(live.silenceMs == 1200)
        #expect(live.preferredLocales.isEmpty)
    }

    @Test func choicesPersistAcrossRegistryInstances() async throws {
        let rig = Rig(); defer { rig.cleanUp() }
        try rig.installers["parakeet-eou-160"]!.stage(root: rig.root)
        try rig.installers["parakeet-v3"]!.stage(root: rig.root)
        let first = rig.registry()
        first.settings.preferredLocales = [Locale(identifier: "fr-FR")]
        first.settings.silenceMs = 500
        try await first.models.select("parakeet-eou-160", role: .liveDictation)
        try await first.models.select("parakeet-v3", role: .postPass)

        let second = rig.registry()
        let live = await second.liveEngine()
        #expect(live.engine.id == "parakeet-eou-160")
        #expect(live.preferredLocales.map(\.identifier) == ["fr-FR"])
        #expect(live.silenceMs == 500)
        #expect(await second.postPassTranscriber()?.id == "parakeet-v3")
    }

    @Test func postPassIsNilWhenNothingChosenOrNotInstalled() async {
        let rig = Rig(); defer { rig.cleanUp() }
        #expect(await rig.registry().postPassTranscriber() == nil)
        SelectionStore(defaults: rig.defaults).set("parakeet-ultra", for: .postPass)
        #expect(await rig.registry().postPassTranscriber() == nil)
    }

    @Test func registryNeverStartsAnInstallOrWarmUp() async throws {
        let rig = Rig(); defer { rig.cleanUp() }
        let store = SelectionStore(defaults: rig.defaults)
        // Every shape of persisted state: missing, unknown, post-pass missing, none.
        for id in [nil, "nemotron-multilingual-1120", "bogus"] {
            store.set(id, for: .liveDictation)
            store.set(id == nil ? nil : "parakeet-ultra", for: .postPass)
            let registry = rig.registry()
            _ = await registry.liveEngine()
            _ = await registry.postPassTranscriber()
        }
        #expect(rig.totalInstalls == 0)
        #expect(rig.totalWarms == 0)
    }

    @Test func settingsDefaultsAndPersistence() {
        let rig = Rig(); defer { rig.cleanUp() }
        let settings = EngineSettings(defaults: rig.defaults)
        #expect(settings.silenceMs == 1200)
        #expect(settings.preferredLocales.isEmpty)
        settings.silenceMs = 500
        #expect(EngineSettings(defaults: rig.defaults).silenceMs == 500)
    }
}

@Suite struct FluidAudioCatalogTests {
    @Test func catalogCoversEverySpeechModelAndInstallerIsKeyedByID() {
        let descriptors = FluidAudioCatalog.descriptors(platform: .macOS)
        #expect(descriptors.count == 6 + 2 + 2)
        let installers = FluidAudioCatalog.installers(platform: .macOS)
        #expect(Set(installers.keys) == Set(descriptors.map(\.id)))
    }

    @Test func iOSListIsFilteredToFlaggedModels() {
        let ios = FluidAudioCatalog.descriptors(platform: .iOS)
        #expect(ios.allSatisfy { $0.supports(.iOS) })
        #expect(Set(FluidAudioCatalog.installers(platform: .iOS).keys) == Set(ios.map(\.id)))
    }

    @Test func suggestedLiveModelIsTheMultilingual1120Tier() {
        #expect(FluidAudioCatalog.suggestedLiveModelID == "nemotron-multilingual-1120")
        #expect(FluidAudioCatalog.descriptors().contains { $0.id == FluidAudioCatalog.suggestedLiveModelID })
    }

    @Test func defaultRootIsUnderApplicationSupportLegato() {
        let path = FluidAudioCatalog.defaultRoot().path
        #expect(path.hasSuffix("Legato/Models"))
        #expect(path.contains("Application Support"))
    }
}

@Suite struct FluidAudioPinTests {
    @Test func buildingTheSpeechManagerPinsTheDownloadsToReviewedCommits() {
        _ = FluidAudioCatalog.makeManager(
            root: FileManager.default.temporaryDirectory.appending(path: "legato-pin-\(UUID().uuidString)"),
            selection: SelectionStore(defaults: UserDefaults(suiteName: "legato.pin.\(UUID().uuidString)")!))
        #expect(FluidAudioModels.revisionsArePinned)
    }
}
