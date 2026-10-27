import Foundation
import LegatoCore
import LegatoModels
import LegatoPostProcessing
import Synchronization
import Testing
@testable import LegatoMLX

private let qwen = MLXModels.spec(id: MLXModels.qwen3_1_7bID)!

/// Records the instructions it gets and echoes the text of the user message back in `<text>` tags.
private final class EchoBackend: LLMBackend {
    let id: String
    let maxPromptCharacters: Int? = nil
    private let seen = Mutex<[String]>([])
    init(id: String) { self.id = id }
    var availability: LLMAvailability { get async { .available } }
    var instructions: [String] { seen.withLock { $0 } }
    func respond(instructions: String, prompt: String) async throws -> String {
        try await respond(instructions: instructions, examples: [], prompt: prompt)
    }
    func respond(instructions: String, examples: [LLMExample], prompt: String) async throws -> String {
        seen.withLock { $0.append(instructions) }
        return prompt
    }
}

private struct Rig {
    let root = tempRoot()
    let manager: ModelManager

    init(installed: Bool, selected: String? = qwen.id) {
        let (defaults, _) = freshDefaults()
        let installer = CountingInstaller(folderName: "mlx/\(qwen.folderName)", installed: installed)
        let store = SelectionStore(defaults: defaults)
        store.set(selected, for: .cleanup)
        if installed {
            try? InstallMarker.write(in: installer.installFolder(root: root), id: qwen.id, stage: .installed)
        }
        manager = ModelManager(root: root, catalog: [qwen.descriptor], installers: [qwen.id: installer], selection: store)
    }

    func registry(fm: (any LLMBackend)? = NamedBackend(id: "fm"), gpu: Bool = true) -> CleanupRegistry {
        CleanupRegistry(
            models: manager, foundationModels: fm, makeMLXBackend: { spec, _ in NamedBackend(id: "mlx:\(spec.id)") },
            canUseGPU: { gpu })
    }
}

@Suite("CleanupRegistry options")
struct CleanupRegistryOptionsTests {
    // MARK: backend preference

    @Test func autoUsesThePickedMlxModel() async {
        let resolution = await Rig(installed: true).registry().resolve(preference: .auto)
        #expect(resolution.choice == .mlx(modelID: qwen.id))
        #expect(resolution.backend?.id == "mlx:\(qwen.id)")
        #expect(resolution.skipped.isEmpty)
    }

    @Test func foundationModelsOnlySkipsAnInstalledMlxModel() async {
        let resolution = await Rig(installed: true).registry().resolve(preference: .foundationModels)
        #expect(resolution.choice == .foundationModels)
        #expect(resolution.backend?.id == "fm")
    }

    // MARK: why a backend was skipped

    @Test func aBackgroundRunSaysWhyMlxWasSkipped() async {
        let resolution = await Rig(installed: true).registry(gpu: false).resolve(preference: .auto)
        #expect(resolution.choice == .foundationModels)
        #expect(resolution.skipped == [.mlxNeedsForeground(modelID: qwen.id)])
    }

    @Test func aPickedModelThatIsNotInstalledIsReported() async {
        let resolution = await Rig(installed: false).registry().resolve(preference: .auto)
        #expect(resolution.skipped == [.mlxNotInstalled(modelID: qwen.id)])
    }

    @Test func unavailableFoundationModelsAreReportedWithTheirReason() async {
        let fm = NamedBackend(id: "fm", availabilityValue: .unavailable(reason: "Apple Intelligence is off"))
        let resolution = await Rig(installed: false, selected: nil).registry(fm: fm).resolve(preference: .auto)
        #expect(resolution.choice == .itnOnly)
        #expect(resolution.skipped == [.foundationModelsUnavailable(reason: "Apple Intelligence is off")])
    }

    @Test func noFoundationModelsAtAllIsReported() async {
        let resolution = await Rig(installed: false, selected: nil).registry(fm: nil).resolve(preference: .auto)
        #expect(resolution.skipped == [.noFoundationModels])
    }

    @Test func everySkipHasAReadableDescription() {
        let skips: [CleanupRegistry.Skip] = [
            .mlxNotInstalled(modelID: "m"), .mlxNeedsForeground(modelID: "m"), .mlxUnavailable(modelID: "m", reason: "r"),
            .foundationModelsUnavailable(reason: "r"), .noFoundationModels,
        ]
        #expect(Set(skips.map(\.description)).count == skips.count)
        #expect(skips.allSatisfy { !$0.description.isEmpty })
    }

    // MARK: pipeline options

    @Test func itnCanBeLeftOut() async {
        let registry = Rig(installed: false).registry()
        let without = await registry.pipeline(style: .verbatim, itn: false, preference: .auto, timeout: .seconds(4))
        #expect(without.pipeline.stages.map(\.id) == ["llm-cleanup"])
        let with = await registry.pipeline(style: .verbatim, itn: true, preference: .auto, timeout: .seconds(4))
        #expect(with.pipeline.stages.map(\.id) == ["itn", "llm-cleanup"])
    }

    @Test func noBackendAndNoItnIsAnEmptyPipeline() async {
        let registry = Rig(installed: false, selected: nil).registry(fm: nil)
        let built = await registry.pipeline(style: .verbatim, itn: false, preference: .auto, timeout: .seconds(4))
        #expect(built.pipeline.stages.isEmpty)
        #expect(built.resolution.choice == .itnOnly)
    }

    @Test func theTimeoutIsPassedOn() async {
        let built = await Rig(installed: false).registry().pipeline(
            style: .verbatim, itn: false, preference: .auto, timeout: .seconds(7))
        #expect(built.pipeline.timeout == .seconds(7))
    }

    @Test func theStyleDecidesThePrompt() async {
        let fm = EchoBackend(id: "fm")
        let registry = Rig(installed: false, selected: nil).registry(fm: fm)
        let message = await registry.pipeline(style: .message, itn: false, preference: .auto, timeout: .seconds(4))
        _ = await message.pipeline.process("hello there", locale: Locale(identifier: "en-US"))
        let verbatim = await registry.pipeline(style: .verbatim, itn: false, preference: .auto, timeout: .seconds(4))
        _ = await verbatim.pipeline.process("hello there", locale: Locale(identifier: "en-US"))
        let sent = fm.instructions
        #expect(sent.count == 2)
        #expect(sent.first == CleanupStyle.message.prompt.instructions(Locale(identifier: "en-US"), []))
        #expect(sent.last == CleanupPrompt.standard.instructions(Locale(identifier: "en-US"), []))
    }
}
