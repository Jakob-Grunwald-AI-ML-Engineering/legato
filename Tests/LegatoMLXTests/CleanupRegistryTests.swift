import Foundation
import LegatoCore
import Synchronization
import LegatoModels
import LegatoPostProcessing
import Testing
@testable import LegatoMLX

private let qwen = MLXModels.spec(id: MLXModels.qwen3_1_7bID)!

private struct Rig {
    let root = tempRoot()
    let defaults: UserDefaults
    let suite: String
    let installer: CountingInstaller
    let manager: ModelManager

    init(installed: Bool, selected: String? = qwen.id) {
        (defaults, suite) = freshDefaults()
        installer = CountingInstaller(folderName: "mlx/\(qwen.folderName)", installed: installed)
        let store = SelectionStore(defaults: defaults)
        store.set(selected, for: .cleanup)
        if installed {  // what an earlier install would have left behind
            try? InstallMarker.write(in: installer.installFolder(root: root), id: qwen.id, stage: .installed)
        }
        manager = ModelManager(root: root, catalog: [qwen.descriptor], installers: [qwen.id: installer], selection: store)
    }

    func registry(foundationModels: (any LLMBackend)?) -> CleanupRegistry {
        CleanupRegistry(models: manager, foundationModels: foundationModels) { spec, folder in
            NamedBackend(id: "mlx:\(spec.id)@\(folder.lastPathComponent)")
        }
    }
}

@Suite("CleanupRegistry")
struct CleanupRegistryTests {
    @Test func aSelectedInstalledMlxModelWins() async {
        let rig = Rig(installed: true)
        let (choice, backend) = await rig.registry(foundationModels: NamedBackend(id: "fm")).resolve()
        #expect(choice == .mlx(modelID: qwen.id))
        #expect(backend?.id == "mlx:\(qwen.id)@\(qwen.folderName)")
    }

    @Test func aSelectedButMissingMlxModelFallsBackToFoundationModels() async {
        let rig = Rig(installed: false)
        let (choice, backend) = await rig.registry(foundationModels: NamedBackend(id: "fm")).resolve()
        #expect(choice == .foundationModels)
        #expect(backend?.id == "fm")
    }

    @Test func noSelectionUsesFoundationModels() async {
        let rig = Rig(installed: true, selected: nil)
        let (choice, _) = await rig.registry(foundationModels: NamedBackend(id: "fm")).resolve()
        #expect(choice == .foundationModels)
    }

    @Test func anUnknownSelectionFallsBack() async {
        let rig = Rig(installed: true, selected: "something-else")
        let (choice, _) = await rig.registry(foundationModels: NamedBackend(id: "fm")).resolve()
        #expect(choice == .foundationModels)
    }

    @Test func unavailableFoundationModelsFallsBackToItnOnly() async {
        let rig = Rig(installed: false)
        let fm = NamedBackend(id: "fm", availabilityValue: .unavailable(reason: "off"))
        let (choice, backend) = await rig.registry(foundationModels: fm).resolve()
        #expect(choice == .itnOnly)
        #expect(backend == nil)
    }

    @Test func noFoundationModelsAtAllFallsBackToItnOnly() async {
        let rig = Rig(installed: false, selected: nil)
        let (choice, backend) = await rig.registry(foundationModels: nil).resolve()
        #expect(choice == .itnOnly)
        #expect(backend == nil)
    }

    @Test func aUnavailableMlxBackendFallsBackToo() async {
        let rig = Rig(installed: true)
        let registry = CleanupRegistry(models: rig.manager, foundationModels: NamedBackend(id: "fm")) { spec, _ in
            NamedBackend(id: spec.id, availabilityValue: .unavailable(reason: "broken"))
        }
        let (choice, _) = await registry.resolve()
        #expect(choice == .foundationModels)
    }

    // MARK: GPU access

    @Test func withoutGPUAccessAnInstalledMlxModelFallsBackToFoundationModels() async {
        let rig = Rig(installed: true)
        let registry = CleanupRegistry(
            models: rig.manager, foundationModels: NamedBackend(id: "fm"),
            makeMLXBackend: { spec, _ in NamedBackend(id: spec.id) }, canUseGPU: { false })
        let (choice, backend) = await registry.resolve()
        #expect(choice == .foundationModels)
        #expect(backend?.id == "fm")
    }

    @Test func withoutGPUAccessAndNoFoundationModelsOnlyItnRuns() async {
        let rig = Rig(installed: true)
        let registry = CleanupRegistry(
            models: rig.manager, foundationModels: nil,
            makeMLXBackend: { spec, _ in NamedBackend(id: spec.id) }, canUseGPU: { false })
        let (choice, backend) = await registry.resolve()
        #expect(choice == .itnOnly)
        #expect(backend == nil)
        #expect(await registry.pipeline().stages.map(\.id) == ["itn"])
    }

    @Test func withGPUAccessMlxIsUsed() async {
        let rig = Rig(installed: true)
        let registry = CleanupRegistry(
            models: rig.manager, foundationModels: NamedBackend(id: "fm"),
            makeMLXBackend: { spec, _ in NamedBackend(id: spec.id) }, canUseGPU: { true })
        #expect(await registry.resolve().choice == .mlx(modelID: qwen.id))
    }

    @Test func theGPUCheckIsAskedAgainOnEveryResolve() async {
        let rig = Rig(installed: true)
        let allowed = Mutex(true)
        let registry = CleanupRegistry(
            models: rig.manager, foundationModels: NamedBackend(id: "fm"),
            makeMLXBackend: { spec, _ in NamedBackend(id: spec.id) }, canUseGPU: { allowed.withLock { $0 } })
        #expect(await registry.resolve().choice == .mlx(modelID: qwen.id))
        allowed.withLock { $0 = false }
        #expect(await registry.resolve().choice == .foundationModels, "the app went to the background")
        allowed.withLock { $0 = true }
        #expect(await registry.resolve().choice == .mlx(modelID: qwen.id))
    }

    @Test func theGPUCheckIsSkippedWhenNoMlxModelIsPicked() async {
        let rig = Rig(installed: true, selected: nil)
        let asked = Mutex(0)
        let registry = CleanupRegistry(
            models: rig.manager, foundationModels: NamedBackend(id: "fm"),
            makeMLXBackend: { spec, _ in NamedBackend(id: spec.id) },
            canUseGPU: { asked.withLock { $0 += 1 }; return false })
        #expect(await registry.resolve().choice == .foundationModels)
        #expect(asked.withLock { $0 } == 0)
    }

    @Test func theDefaultGPUCheckAllowsTheForegroundMac() async {
        #if os(macOS)
        #expect(await CleanupRegistry.defaultCanUseGPU())
        #endif
    }

    @Test func resolvingNeverStartsAnInstallOrWarmUp() async {
        for (installed, fm) in [(true, true), (false, true), (false, false)] {
            let rig = Rig(installed: installed)
            let registry = rig.registry(foundationModels: fm ? NamedBackend(id: "fm") : nil)
            _ = await registry.resolve()
            _ = await registry.pipeline()
            #expect(rig.installer.installCalls == 0)
            #expect(rig.installer.warmCalls == 0)
        }
    }

    @Test func thePipelineAlwaysStartsWithItnAndAddsTheLlmStageOnlyWithABackend() async {
        let withLLM = await Rig(installed: false).registry(foundationModels: NamedBackend(id: "fm")).pipeline()
        #expect(withLLM.stages.map(\.id) == ["itn", "llm-cleanup"])
        let without = await Rig(installed: false).registry(foundationModels: nil).pipeline()
        #expect(without.stages.map(\.id) == ["itn"])
    }
}
