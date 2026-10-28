import Foundation
import LegatoCoreML
import LegatoModels
import Testing
@testable import LegatoAppServices

@Suite struct CoreMLSelectionMigrationTests {
    @Test(arguments: ["mlx-qwen3-0.6b-4bit", "mlx-qwen3-1.7b-4bit", "mlx-gemma3-1b-4bit", "unknown-old-model"])
    func previousModelAndBackendChoicesAreNotCarriedForward(id: String) {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let selection = SelectionStore(defaults: defaults)
        selection.set(id, for: .cleanup)
        selection.set("parakeet-eou-320", for: .liveDictation)
        defaults.set("auto", forKey: "cleanup.backend")
        defaults.set("mlx", forKey: "meeting.summaryBackend")
        defaults.set(4, forKey: "cleanup.timeoutSeconds")
        _ = CleanupSettingsStore(defaults: defaults)
        #expect(selection.selected(for: .cleanup) == nil)
        #expect(defaults.string(forKey: "cleanup.backend") == "foundationModels")
        #expect(defaults.string(forKey: "meeting.summaryBackend") == "foundationModels")
        #expect(selection.selected(for: .liveDictation) == "parakeet-eou-320")
        #expect(defaults.integer(forKey: "cleanup.timeoutSeconds") == 4)
    }

    @Test(arguments: ["coreml-qwen3-0.6b-lut8", "coreml-qwen3-1.7b-lut6", "coreml-gemma3-1b-lut6"])
    func validNewChoicesRemainSelectedWhenSettingsOpen(id: String) {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let selection = SelectionStore(defaults: defaults)
        selection.set(id, for: .cleanup)
        defaults.set("coreML", forKey: "cleanup.backend")
        defaults.set("foundationModels", forKey: "meeting.summaryBackend")
        _ = MeetingSettings(defaults: defaults)
        _ = CleanupSettingsStore(defaults: defaults)
        #expect(selection.selected(for: .cleanup) == id)
        #expect(defaults.string(forKey: "cleanup.backend") == "coreML")
        #expect(defaults.string(forKey: "meeting.summaryBackend") == "foundationModels")
    }

    @Test func explicitNewCoreMLChoiceWithoutWeightsRemainsAChooseModelState() {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        defaults.set("coreML", forKey: "cleanup.backend")
        _ = CleanupSettingsStore(defaults: defaults)
        #expect(defaults.string(forKey: "cleanup.backend") == "coreML")
        #expect(SelectionStore(defaults: defaults).selected(for: .cleanup) == nil)
    }

    @MainActor @Test(arguments: [ModelPlatform.iOS, .macOS])
    func productionCatalogContainsOnlyTheThreeCoreMLCleanupFamilies(platform: ModelPlatform) async {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let models = ModelServices(root: .temporaryDirectory.appending(path: UUID().uuidString), defaults: defaults, platform: platform, installers: [:])
        #expect(Set(models.cleanupModels.map(\.id)) == ["coreml-qwen3-0.6b-lut8", "coreml-qwen3-1.7b-lut6", "coreml-gemma3-1b-lut6"])
        for descriptor in models.cleanupModels { #expect(await models.manager.state(of: descriptor.id) == .notInstalled) }
    }
}
