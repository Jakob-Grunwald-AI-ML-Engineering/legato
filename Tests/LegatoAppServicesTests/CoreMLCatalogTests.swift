import Foundation
import LegatoCore
import LegatoModels
import Testing
@testable import LegatoAppServices

@Suite @MainActor struct CoreMLCatalogTests {
    @Test(arguments: [ModelPlatform.iOS, .macOS])
    func qwenCoreMLIsAnExplicitOptInOnBothPlatforms(platform: ModelPlatform) async {
        let models = ModelServices(root: .temporaryDirectory.appending(path: UUID().uuidString), defaults: UserDefaults(suiteName: UUID().uuidString)!, platform: platform, installers: [:])
        let descriptor = models.cleanupModels.first { $0.id == "coreml-qwen3-1.7b-lut6" }
        #expect(descriptor?.displayName == "Qwen3 1.7B (Core ML)")
        #expect(models.selected(.cleanup) == nil)
        #expect(models.cleanupChoice(for: "coreml-qwen3-1.7b-lut6") == .coreML)
        #expect(!models.cleanupModels.contains { $0.id.hasPrefix("mlx-") })
        #expect(await models.manager.state(of: "coreml-qwen3-1.7b-lut6") == .notInstalled)
    }
    @Test func unsupportedOldBackendUsesTheNewBuiltInDefault() {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        defaults.set("mlx", forKey: "cleanup.backend")
        let settings = CleanupSettingsStore(defaults: defaults)
        #expect(settings.backend == .foundationModels)
        #expect(settings.backend.preference == .foundationModels)
        #expect(CleanupSettingsStore(defaults: defaults).backend.preference == .foundationModels)
    }
}
