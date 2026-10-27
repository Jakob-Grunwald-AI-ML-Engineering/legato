import Foundation
import LegatoModels
import Testing
@testable import LegatoAppServices

@MainActor @Suite struct PostPassPickerTests {
    private func services(_ platform: ModelPlatform, _ suite: String = UUID().uuidString) -> ModelServices {
        ModelServices(
            root: FileManager.default.temporaryDirectory.appending(path: "legato-pp-\(suite)"),
            defaults: UserDefaults(suiteName: "legato.pp.\(suite)")!, platform: platform)
    }

    @Test func theChoicesAreTheBatchSpeechModelsOfThisPlatform() {
        let mac = services(.macOS)
        #expect(mac.postPassModels.map(\.id) == ["parakeet-v3", "parakeet-ultra"])
        #expect(mac.postPassModels.allSatisfy { $0.kind == .speechBatch && $0.supports(.macOS) })
        #expect(services(.iOS).postPassModels.allSatisfy { $0.kind == .speechBatch && $0.supports(.iOS) })
    }

    @Test func offClearsThePostPassPickAndLeavesLiveDictationAlone() {
        let suite = UUID().uuidString
        let defaults = UserDefaults(suiteName: "legato.pp.\(suite)")!
        let store = SelectionStore(defaults: defaults)
        store.set("parakeet-v3", for: .postPass)
        store.set("nemotron-latin-560", for: .liveDictation)
        let services = services(.macOS, suite)
        #expect(services.selected(.postPass) == "parakeet-v3")
        services.clearPick(.postPass)
        #expect(services.selected(.postPass) == nil)
        #expect(services.selected(.liveDictation) == "nemotron-latin-560")
    }
}
