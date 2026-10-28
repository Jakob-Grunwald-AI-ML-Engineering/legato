import Foundation
import LegatoCoreML
import LegatoModels
import Testing
@testable import LegatoAppServices

@Suite struct CoreMLSelectionMigrationTests {
    @Test(arguments: [
        ("mlx-qwen3-0.6b-4bit", "coreml-qwen3-0.6b-lut8"),
        ("mlx-qwen3-1.7b-4bit", "coreml-qwen3-1.7b-lut6"),
        ("mlx-gemma3-1b-4bit", "coreml-gemma3-1b-lut6")
    ])
    func migratesSameFamilyWithoutInstallingOrChangingOtherPreferences(ids: (String, String)) {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let selection = SelectionStore(defaults: defaults)
        selection.set(ids.0, for: .cleanup)
        selection.set("parakeet-eou-320", for: .liveDictation)
        defaults.set("auto", forKey: "cleanup.backend")
        defaults.set("foundationModels", forKey: "meeting.summaryBackend")
        defaults.set(4, forKey: "cleanup.timeoutSeconds")
        defaults.set("message", forKey: "cleanup.style")
        defaults.set("hold", forKey: "cleanup.delivery")
        defaults.set("off", forKey: "cleanup.background")
        _ = CleanupSettingsStore(defaults: defaults)
        #expect(selection.selected(for: .cleanup) == ids.1)
        #expect(defaults.string(forKey: "cleanup.backend") == "coreML")
        #expect(defaults.string(forKey: "meeting.summaryBackend") == "foundationModels")
        #expect(selection.selected(for: .liveDictation) == "parakeet-eou-320")
        #expect(defaults.integer(forKey: "cleanup.timeoutSeconds") == 4)
        #expect(defaults.string(forKey: "cleanup.style") == "message")
        #expect(defaults.string(forKey: "cleanup.delivery") == "hold")
        // Reopening must preserve an explicit later selection.
        selection.set(CoreMLModels.qwen3_1_7bID, for: .cleanup)
        _ = CleanupSettingsStore(defaults: defaults)
        #expect(selection.selected(for: .cleanup) == CoreMLModels.qwen3_1_7bID)
    }

    @Test(arguments: ["auto", "mlx", "coreML", "foundationModels"])
    func independentBackendIntentsSurviveWithNoLocalSelection(raw: String) {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        defaults.set(raw, forKey: "cleanup.backend")
        defaults.set("mlx", forKey: "meeting.summaryBackend")
        _ = MeetingSettings(defaults: defaults)
        _ = CleanupSettingsStore(defaults: defaults)
        #expect(defaults.string(forKey: "cleanup.backend") == ((raw == "auto" || raw == "foundationModels") ? "foundationModels" : "coreML"))
        #expect(defaults.string(forKey: "meeting.summaryBackend") == "coreML")
        #expect(SelectionStore(defaults: defaults).selected(for: .cleanup) == nil)
    }

    @Test func unknownLocalSelectionKeepsItsIdentityAndNeverBecomesFoundationModels() {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        SelectionStore(defaults: defaults).set("removed-local-model", for: .cleanup)
        defaults.set("foundationModels", forKey: "cleanup.backend")
        defaults.set("auto", forKey: "meeting.summaryBackend")
        _ = CleanupSettingsStore(defaults: defaults)
        #expect(defaults.string(forKey: "cleanup.backend") == "foundationModels")
        #expect(defaults.string(forKey: "meeting.summaryBackend") == "coreML")
        #expect(SelectionStore(defaults: defaults).selected(for: .cleanup) == "removed-local-model")
    }

    @MainActor @Test(arguments: [ModelPlatform.iOS, .macOS])
    func productionCatalogContainsOnlyTheThreeCoreMLCleanupFamilies(platform: ModelPlatform) async {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let models = ModelServices(root: .temporaryDirectory.appending(path: UUID().uuidString), defaults: defaults, platform: platform, installers: [:])
        #expect(Set(models.cleanupModels.map(\.id)) == ["coreml-qwen3-0.6b-lut8", "coreml-qwen3-1.7b-lut6", "coreml-gemma3-1b-lut6"])
        for descriptor in models.cleanupModels { #expect(await models.manager.state(of: descriptor.id) == .notInstalled) }
    }
}
