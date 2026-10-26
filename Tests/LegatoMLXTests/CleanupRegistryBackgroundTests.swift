import Foundation
import LegatoCore
import LegatoModels
import LegatoPostProcessing
import Testing
@testable import LegatoMLX

private let qwen = MLXModels.spec(id: MLXModels.qwen3_1_7bID)!

private struct Rig {
    let root = tempRoot()
    let manager: ModelManager

    init(installed: Bool = true, selected: String? = qwen.id) {
        let (defaults, _) = freshDefaults()
        let installer = CountingInstaller(folderName: "mlx/\(qwen.folderName)", installed: installed)
        let store = SelectionStore(defaults: defaults)
        store.set(selected, for: .cleanup)
        if installed {
            try? InstallMarker.write(in: installer.installFolder(root: root), id: qwen.id, stage: .installed)
        }
        manager = ModelManager(root: root, catalog: [qwen.descriptor], installers: [qwen.id: installer], selection: store)
    }

    /// `gpu`: whether the GPU is usable now (false: the phone app is in the background).
    func registry(gpu: Bool, cpuAvailable: LLMAvailability = .available) -> CleanupRegistry {
        CleanupRegistry(
            models: manager, foundationModels: NamedBackend(id: "fm"),
            makeMLXBackend: { spec, _ in NamedBackend(id: "gpu:\(spec.id)") },
            makeCPUBackend: { spec, _ in NamedBackend(id: "cpu:\(spec.id)", availabilityValue: cpuAvailable) },
            canUseGPU: { gpu })
    }
}

@Suite("CleanupRegistry in the background")
struct CleanupRegistryBackgroundTests {
    @Test func withoutTheGpuThePickedModelRunsOnTheCpu() async {
        let resolution = await Rig().registry(gpu: false).resolve(preference: .auto, background: .cpu)
        #expect(resolution.choice == .mlx(modelID: qwen.id))
        #expect(resolution.backend?.id == "cpu:\(qwen.id)")
        #expect(resolution.device == .cpu)
        #expect(resolution.skipped.isEmpty)
    }

    @Test func withTheGpuThePickedModelRunsOnTheGpuWhateverTheBackgroundSetting() async {
        for background in CleanupRegistry.BackgroundCleanup.allCases {
            let resolution = await Rig().registry(gpu: true).resolve(preference: .auto, background: background)
            #expect(resolution.backend?.id == "gpu:\(qwen.id)")
            #expect(resolution.device == .gpu)
        }
    }

    @Test func backgroundSetToFoundationModelsPassesTheMlxModelOver() async {
        let resolution = await Rig().registry(gpu: false).resolve(preference: .auto, background: .foundationModels)
        #expect(resolution.choice == .foundationModels)
        #expect(resolution.device == nil)
        #expect(resolution.skipped == [.mlxNeedsForeground(modelID: qwen.id)])
    }

    @Test func backgroundCleanupOffRunsNoLanguageModelAtAll() async {
        let resolution = await Rig().registry(gpu: false).resolve(preference: .auto, background: .off)
        #expect(resolution.choice == .itnOnly)
        #expect(resolution.backend == nil)
        #expect(resolution.skipped == [.backgroundCleanupOff])
    }

    @Test func backgroundCleanupOffAlsoStopsFoundationModels() async {
        let resolution = await Rig().registry(gpu: false).resolve(preference: .foundationModels, background: .off)
        #expect(resolution.backend == nil)
        #expect(resolution.skipped == [.backgroundCleanupOff])
    }

    @Test func anUnusableCpuBackendFallsThroughToFoundationModels() async {
        let rig = Rig()
        let resolution = await rig.registry(gpu: false, cpuAvailable: .unavailable(reason: "not loaded"))
            .resolve(preference: .auto, background: .cpu)
        #expect(resolution.choice == .foundationModels)
        #expect(resolution.skipped == [.mlxUnavailable(modelID: qwen.id, reason: "not loaded")])
    }

    @Test func aModelThatIsNotInstalledFallsThroughOnTheCpuToo() async {
        let resolution = await Rig(installed: false).registry(gpu: false).resolve(preference: .auto, background: .cpu)
        #expect(resolution.choice == .foundationModels)
        #expect(resolution.skipped == [.mlxNotInstalled(modelID: qwen.id)])
    }

    @Test func foundationModelsOnlyStaysFoundationModelsInTheBackground() async {
        let resolution = await Rig().registry(gpu: false).resolve(preference: .foundationModels, background: .cpu)
        #expect(resolution.choice == .foundationModels)
        #expect(resolution.device == nil)
    }

    @Test func thePipelineUsesTheBackgroundSetting() async {
        let built = await Rig().registry(gpu: false).pipeline(
            style: .verbatim, itn: false, preference: .auto, background: .cpu, timeout: .seconds(4))
        #expect(built.resolution.backend?.id == "cpu:\(qwen.id)")
        #expect(built.pipeline.stages.map(\.id) == ["llm-cleanup"])
    }

    @Test func theNewSkipReadsWell() {
        #expect(!CleanupRegistry.Skip.backgroundCleanupOff.description.isEmpty)
        #expect(CleanupRegistry.Skip.backgroundCleanupOff.description != CleanupRegistry.Skip.mlxNeedsForeground(modelID: qwen.id).description)
    }
}
