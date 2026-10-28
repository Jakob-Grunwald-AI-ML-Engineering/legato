import Foundation
import LegatoCore
import LegatoModels
import Testing
@testable import LegatoMLX

@Suite("CleanupRegistryCoreML")
struct CleanupRegistryCoreMLTests {
    private let modelID = "coreml-qwen3-1.7b"

    private func registry(installed: Bool = true, available: Bool = true, foreground: Bool = true) -> CleanupRegistry {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let root = URL.temporaryDirectory.appending(path: UUID().uuidString)
        let selection = SelectionStore(defaults: defaults)
        selection.set(modelID, for: .cleanup)
        let installer = CountingInstaller(folderName: "coreml/qwen", installed: installed)
        if installed { try? InstallMarker.write(in: installer.installFolder(root: root), id: modelID, stage: .installed) }
        let descriptor = ModelDescriptor(id: modelID, kind: .llm, displayName: "Qwen Core ML", approxBytes: 1, licence: "Apache-2.0", family: "qwen3")
        let manager = ModelManager(root: root, catalog: [descriptor], installers: [modelID: installer], selection: selection)
        return CleanupRegistry(models: manager, foundationModels: NamedBackend(id: "fm"), makeCoreMLBackend: { id, _ in
            guard id == "coreml-qwen3-1.7b" else { return nil }
            return NamedBackend(id: "coreml", availabilityValue: available ? .available : .unavailable(reason: "Prepare in foreground"))
        }, canUseGPU: { foreground })
    }

    @Test func selectedPreparedCoreMLRunsInForeground() async {
        let result = await registry().resolve(preference: .auto, background: .cpu)
        #expect(result.choice == .coreML(modelID: "coreml-qwen3-1.7b"))
        #expect(result.backend?.id == "coreml")
        #expect(result.execution == "CPU + Neural Engine requested; placement unverified")
    }

    @Test func selectedPreparedCoreMLRunsInBackgroundWithoutGPU() async {
        let result = await registry(foreground: false).resolve(preference: .coreML, background: .cpu)
        #expect(result.choice == .coreML(modelID: "coreml-qwen3-1.7b"))
    }

    @Test func explicitFoundationModelsPreferenceBypassesCoreML() async {
        let result = await registry().resolve(preference: .foundationModels, background: .cpu)
        #expect(result.choice == .foundationModels)
    }

    @Test func legacyFoundationModelsPolicyDoesNotSwitchSelectedCoreML() async {
        let result = await registry(foreground: false).resolve(preference: .coreML, background: .foundationModels)
        #expect(result.choice == .coreML(modelID: "coreml-qwen3-1.7b"))
        #expect(result.skipped.isEmpty)
    }

    @Test func legacyBackgroundOffDoesNotDisableSelectedCoreML() async {
        let result = await registry(foreground: false).resolve(preference: .coreML, background: .off)
        #expect(result.choice == .coreML(modelID: "coreml-qwen3-1.7b"))
        #expect(result.backend?.id == "coreml")
    }

    @Test func unpreparedCoreMLKeepsRawTextAndNeverSubstitutesFoundationModels() async {
        let result = await registry(available: false).resolve(preference: .coreML, background: .cpu)
        #expect(result.choice == .itnOnly)
        #expect(result.backend == nil)
        #expect(result.skipped == [.coreMLUnavailable(modelID: "coreml-qwen3-1.7b", reason: "Prepare in foreground")])
    }

    @Test func incompleteInstallNeverInvokesCoreML() async {
        let result = await registry(installed: false).resolve(preference: .coreML, background: .cpu)
        #expect(result.choice == .itnOnly)
        #expect(result.backend == nil)
        #expect(result.skipped == [.coreMLUnavailable(modelID: "coreml-qwen3-1.7b", reason: "Model is not installed")])
    }
}
