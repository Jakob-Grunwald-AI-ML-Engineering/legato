import Foundation
import LegatoModels
import Testing
@testable import LegatoCoreML

struct CoreMLCatalogTests {
    @Test(arguments: [ModelPlatform.iOS, .macOS])
    func retainsAllThreeModelChoicesOnBothPlatforms(_ platform: ModelPlatform) {
        #expect(Set(CoreMLModels.descriptors(platform: platform).map(\.id)) == [
            "coreml-qwen3-0.6b-lut8", "coreml-qwen3-1.7b-lut6", "coreml-gemma3-1b-lut6"
        ])
    }

    @Test(arguments: ["coreml-qwen3-0.6b-lut8", "coreml-gemma3-1b-lut6"])
    func rejectsMissingNativeFilesAndCrossModelManifests(_ id: String) throws {
        let spec = try #require(CoreMLModels.spec(id: id))
        let manifest = try CoreMLManifest.bundled(for: spec)
        let missing = CoreMLManifest(repository: manifest.repository, revision: manifest.revision, files: Array(manifest.files.dropLast()))
        #expect(throws: CoreMLInstallError.invalidManifest) { try missing.validate(for: spec) }
        let duplicate = CoreMLManifest(repository: manifest.repository, revision: manifest.revision, files: manifest.files + [manifest.files[0]])
        #expect(throws: CoreMLInstallError.invalidManifest) { try duplicate.validate(for: spec) }
        #expect(throws: CoreMLInstallError.invalidManifest) { try manifest.validate(for: CoreMLModels.specs[0]) }
    }

    @Test(arguments: [
        ("coreml-qwen3-0.6b-lut8", "1eb386120ff45628b308e9027cb1567e185b431d", 22),
        ("coreml-gemma3-1b-lut6", "a1b00f628f348c8ff55c9fe088e5db97535fd567", 21)
    ])
    func eachNewChoiceHasItsOwnPinnedCompleteManifest(_ id: String, _ revision: String, _ count: Int) throws {
        let spec = try #require(CoreMLModels.spec(id: id))
        let manifest = try CoreMLManifest.bundled(for: spec)
        try manifest.validate(for: spec)
        #expect(manifest.revision == revision)
        #expect(manifest.files.count == count)
        #expect(manifest.files.reduce(Int64(0)) { $0 + $1.bytes } == (id == "coreml-qwen3-0.6b-lut8" ? 961_377_611 : 1_437_792_811))
        let metadata = try #require(manifest.files.first { $0.path == "meta.yaml" })
        #expect(metadata.sha256 == (id == "coreml-qwen3-0.6b-lut8"
            ? "b097ea5679ef0edbf2a92ed00445097a26ed04154c34f90007bc3be91f14140c"
            : "377114b49a7213f6212707347ea05ebdb07fc61b5ea6f812d085c2433430f535"))
        #expect(manifest.files.allSatisfy { !$0.path.contains("02of02") })
    }
}
