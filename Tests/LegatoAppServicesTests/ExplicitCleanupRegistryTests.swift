import Foundation
import LegatoCore
import LegatoCoreML
import LegatoModels
import Testing
@testable import LegatoAppServices

private struct CatalogInstaller: ModelInstaller {
    func installFolder(root: URL) -> URL { root.appending(path: "coreml-test") }
    func isInstalled(root: URL) async -> Bool { true }
    func install(root: URL, progress: @escaping @Sendable (Double) -> Void) async throws { Issue.record("Resolution must not download") }
    func warm(root: URL) async throws { Issue.record("Resolution must not prepare") }
}
private struct CatalogBackend: LLMBackend {
    let id: String
    let available: Bool
    let maxPromptCharacters: Int? = nil
    var availability: LLMAvailability { available ? .available : .unavailable(reason: "Prepare in Legato") }
    func respond(instructions: String, prompt: String) async throws -> String { prompt }
}
@Suite struct ExplicitCleanupRegistryTests {
    private func registry(id: String? = CoreMLModels.qwen3_1_7bID, installed: Bool = true, prepared: Bool = true) throws -> CleanupRegistry {
        let selection = SelectionStore(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        selection.set(id, for: .cleanup)
        let root = URL.temporaryDirectory.appending(path: UUID().uuidString)
        let spec = CoreMLModels.spec(id: CoreMLModels.qwen3_1_7bID)!
        let installer = CatalogInstaller()
        if installed { try InstallMarker.write(in: installer.installFolder(root: root), id: spec.id, stage: .installed) }
        let manager = ModelManager(root: root, catalog: [spec.descriptor], installers: [spec.id: installer], selection: selection)
        return CleanupRegistry(models: manager, foundationModels: CatalogBackend(id: "foundation", available: true),
                               makeCoreMLBackend: { _, _ in CatalogBackend(id: "coreml", available: prepared) })
    }
    @Test func preparedCoreMLResolvesWithoutSubstitution() async throws {
        let result = await (try registry()).resolve(preference: .coreML)
        #expect(result.choice == .coreML(modelID: CoreMLModels.qwen3_1_7bID))
        #expect(result.backend?.id == "coreml")
        #expect(result.execution == "CPU + Neural Engine requested; placement unverified")
    }
    @Test func explicitFoundationModelsIgnoresLocalReadinessAndSelection() async throws {
        let result = await (try registry(installed: false, prepared: false)).resolve(preference: .foundationModels)
        #expect(result.choice == .foundationModels)
        #expect(result.backend?.id == "foundation")
        #expect(result.skipped.isEmpty)
    }
    @Test(arguments: [String?.none, "unknown-local-model", "mlx-qwen3-0.6b-4bit"])
    func unresolvedLocalIntentNeverFallsBackToFoundationModels(id: String?) async throws {
        let result = await (try registry(id: id)).resolve(preference: .coreML)
        #expect(result.choice == .itnOnly)
        #expect(result.backend == nil)
        #expect(!result.skipped.isEmpty)
    }
    @Test(arguments: [false, true])
    func missingOrUnpreparedCoreMLNeverFallsBack(installed: Bool) async throws {
        let registry = try registry(installed: installed, prepared: false)
        let result = await registry.resolve(preference: .coreML)
        #expect(result.choice == .itnOnly)
        #expect(result.backend == nil)
        let (pipeline, _) = await registry.pipeline(style: .verbatim, itn: false, preference: .coreML, timeout: .seconds(4))
        #expect(await pipeline.process("keep this raw text", locale: Locale(identifier: "en-US")) == "keep this raw text")
    }
    @Test func gemmaDownloadExposesCompleteOfflineTermsAndRestrictions() throws {
        let terms = try #require(try CleanupModelTerms.forModel(CoreMLModels.gemma3_1bID))
        #expect(terms.notice.contains("Gemma is provided under and subject to the Gemma Terms of Use"))
        #expect(terms.terms.contains("3.2"))
        #expect(terms.restrictions.contains("You may not use nor allow others to use Gemma"))
        #expect(try CleanupModelTerms.forModel(CoreMLModels.qwen3_0_6bID) == nil)
    }
}
