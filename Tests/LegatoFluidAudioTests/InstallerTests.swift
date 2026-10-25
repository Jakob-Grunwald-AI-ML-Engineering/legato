import Foundation
import LegatoModels
import Testing
@testable import LegatoFluidAudio

/// Stages files under a fresh temp root so installed checks run against real folders, never the network.
private struct StagedRoot {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("legato-installer-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func file(_ path: String) throws {
        let target = url.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: target)
    }

    func directory(_ path: String) throws {
        let target = url.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: target.appendingPathComponent("weights"), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: target.appendingPathComponent("weights/weight.bin"))
    }

    func remove() { try? FileManager.default.removeItem(at: url) }
}

@Suite("Installers") enum InstallerTests {}

extension InstallerTests {
@Suite("Nemotron installer")
struct Nemotron {
    @Test(arguments: [
        (NemotronVariant.multilingual, 560, "nemotron-multilingual/multilingual/560ms"),
        (.multilingual, 1120, "nemotron-multilingual/multilingual/1120ms"),
        (.multilingual, 2240, "nemotron-multilingual/multilingual/2240ms"),
        (.latin, 560, "nemotron-multilingual/latin/560ms"),
        (.latin, 1120, "nemotron-multilingual/latin/1120ms"),
        (.latin, 2240, "nemotron-multilingual/latin/2240ms"),
    ])
    func installFolderIsTheVariantFolderFluidAudioWrites(variant: NemotronVariant, chunkMs: Int, relative: String) throws {
        let root = URL(fileURLWithPath: "/models")
        let folder = NemotronInstaller(variant: variant, chunkMs: chunkMs).installFolder(root: root)
        #expect(folder.path == "/models/\(relative)")
    }

    @Test func notInstalledWhenEmpty() async throws {
        let staged = try StagedRoot()
        defer { staged.remove() }
        #expect(await NemotronInstaller(variant: .latin, chunkMs: 1120).isInstalled(root: staged.url) == false)
    }

    @Test func installedWhenMetadataTokenizerAndEncoderArePresent() async throws {
        let staged = try StagedRoot()
        defer { staged.remove() }
        let base = "nemotron-multilingual/multilingual/1120ms"
        try staged.file("\(base)/metadata.json")
        try staged.file("\(base)/tokenizer.json")
        try staged.directory("\(base)/encoder.mlmodelc")
        #expect(await NemotronInstaller(variant: .multilingual, chunkMs: 1120).isInstalled(root: staged.url))
    }

    @Test(arguments: ["metadata.json", "tokenizer.json", "encoder.mlmodelc"])
    func notInstalledWhenARequiredPartIsMissing(missing: String) async throws {
        let staged = try StagedRoot()
        defer { staged.remove() }
        let base = "nemotron-multilingual/latin/560ms"
        for name in ["metadata.json", "tokenizer.json"] where name != missing { try staged.file("\(base)/\(name)") }
        if missing != "encoder.mlmodelc" { try staged.directory("\(base)/encoder.mlmodelc") }
        #expect(await NemotronInstaller(variant: .latin, chunkMs: 560).isInstalled(root: staged.url) == false)
    }

    @Test func installedStateIsPerTier() async throws {
        let staged = try StagedRoot()
        defer { staged.remove() }
        let base = "nemotron-multilingual/multilingual/2240ms"
        try staged.file("\(base)/metadata.json")
        try staged.file("\(base)/tokenizer.json")
        try staged.directory("\(base)/encoder.mlmodelc")
        #expect(await NemotronInstaller(variant: .multilingual, chunkMs: 2240).isInstalled(root: staged.url))
        #expect(await NemotronInstaller(variant: .multilingual, chunkMs: 1120).isInstalled(root: staged.url) == false)
        #expect(await NemotronInstaller(variant: .latin, chunkMs: 2240).isInstalled(root: staged.url) == false)
    }
}

@Suite("Parakeet EOU installer")
struct Eou {
    @Test func installFolderPerChunk() {
        let root = URL(fileURLWithPath: "/models")
        #expect(ParakeetEouInstaller(chunk: .ms160).installFolder(root: root).path == "/models/parakeet-eou-streaming/160ms")
        #expect(ParakeetEouInstaller(chunk: .ms320).installFolder(root: root).path == "/models/parakeet-eou-streaming/320ms")
    }

    @Test func installedWhenEveryRequiredFileIsPresent() async throws {
        let staged = try StagedRoot()
        defer { staged.remove() }
        let base = "parakeet-eou-streaming/160ms"
        for dir in ["streaming_encoder.mlmodelc", "decoder.mlmodelc", "joint_decision.mlmodelc"] {
            try staged.directory("\(base)/\(dir)")
        }
        try staged.file("\(base)/vocab.json")
        #expect(await ParakeetEouInstaller(chunk: .ms160).isInstalled(root: staged.url))
        #expect(await ParakeetEouInstaller(chunk: .ms320).isInstalled(root: staged.url) == false)
    }

    @Test(arguments: ["streaming_encoder.mlmodelc", "decoder.mlmodelc", "joint_decision.mlmodelc", "vocab.json"])
    func notInstalledWhenARequiredFileIsMissing(missing: String) async throws {
        let staged = try StagedRoot()
        defer { staged.remove() }
        let base = "parakeet-eou-streaming/320ms"
        for dir in ["streaming_encoder.mlmodelc", "decoder.mlmodelc", "joint_decision.mlmodelc"] where dir != missing {
            try staged.directory("\(base)/\(dir)")
        }
        if missing != "vocab.json" { try staged.file("\(base)/vocab.json") }
        #expect(await ParakeetEouInstaller(chunk: .ms320).isInstalled(root: staged.url) == false)
    }
}

@Suite("Parakeet batch installer")
struct ParakeetBatch {
    @Test func installFolderIsTheRepoFolderUnderRoot() {
        let root = URL(fileURLWithPath: "/models")
        #expect(ParakeetBatchInstaller(model: .v3).installFolder(root: root).path == "/models/parakeet-tdt-0.6b-v3")
        #expect(ParakeetBatchInstaller(model: .ultra).installFolder(root: root).path == "/models/parakeet-ultra")
    }

    @Test(arguments: [(ParakeetBatchModel.v3, "parakeet-tdt-0.6b-v3"), (.ultra, "parakeet-ultra")])
    func installedWhenModelsAndVocabularyArePresent(model: ParakeetBatchModel, folder: String) async throws {
        let staged = try StagedRoot()
        defer { staged.remove() }
        for dir in ["Preprocessor.mlmodelc", "Encoder.mlmodelc", "Decoder.mlmodelc", "JointDecisionv3.mlmodelc"] {
            try staged.directory("\(folder)/\(dir)")
        }
        #expect(await ParakeetBatchInstaller(model: model).isInstalled(root: staged.url) == false, "vocabulary still missing")
        try staged.file("\(folder)/parakeet_vocab.json")
        #expect(await ParakeetBatchInstaller(model: model).isInstalled(root: staged.url))
    }

    @Test func notInstalledWhenEmpty() async throws {
        let staged = try StagedRoot()
        defer { staged.remove() }
        #expect(await ParakeetBatchInstaller(model: .v3).isInstalled(root: staged.url) == false)
    }
}

@Suite("FluidAudio catalog rows")
struct CatalogRows {
    static let expectedIDs: Set<String> = [
        "nemotron-multilingual-560", "nemotron-multilingual-1120", "nemotron-multilingual-2240",
        "nemotron-latin-560", "nemotron-latin-1120", "nemotron-latin-2240",
        "parakeet-eou-160", "parakeet-eou-320",
        "parakeet-v3", "parakeet-ultra",
    ]

    @Test func descriptorIDsMatchThePlan() {
        #expect(Set(FluidAudioModels.descriptors.map(\.id)) == CatalogRows.expectedIDs)
        #expect(FluidAudioModels.descriptors.count == CatalogRows.expectedIDs.count)
    }

    @Test func everyDescriptorHasAnInstallerAndKindMatchesRole() {
        let installers = FluidAudioModels.installers
        for descriptor in FluidAudioModels.descriptors {
            #expect(installers[descriptor.id] != nil, "\(descriptor.id)")
        }
        #expect(installers.count == FluidAudioModels.descriptors.count)
        let kinds = Dictionary(uniqueKeysWithValues: FluidAudioModels.descriptors.map { ($0.id, $0.kind) })
        #expect(kinds["parakeet-v3"] == .speechBatch)
        #expect(kinds["parakeet-ultra"] == .speechBatch)
        #expect(kinds["nemotron-latin-1120"] == .speechStreaming)
        #expect(kinds["parakeet-eou-160"] == .speechStreaming)
    }

    @Test func installFoldersAreDistinctAndNeverNested() {
        let root = URL(fileURLWithPath: "/models")
        let folders = FluidAudioModels.descriptors.compactMap { FluidAudioModels.installers[$0.id]?.installFolder(root: root).path }
        #expect(folders.count == CatalogRows.expectedIDs.count)
        #expect(Set(folders).count == folders.count)
        for a in folders {
            for b in folders where a != b {
                #expect(!b.hasPrefix(a + "/"), "\(b) is inside \(a)")
            }
        }
    }

    @Test func licencesAndLanguages() {
        func descriptor(_ id: String) -> ModelDescriptor {
            FluidAudioModels.descriptors.first { $0.id == id }
                ?? ModelDescriptor(id: id, kind: .llm, displayName: "missing", approxBytes: 0, licence: "missing", family: "missing")
        }
        #expect(descriptor("nemotron-multilingual-1120").licence == "OpenMDW-1.1")
        #expect(descriptor("nemotron-latin-560").licence == "OpenMDW-1.1")
        #expect(descriptor("parakeet-v3").licence == "CC-BY-4.0")
        #expect(descriptor("parakeet-ultra").licence == "CC-BY-4.0")
        #expect(descriptor("parakeet-eou-160").licence == "NVIDIA Open Model License")
        #expect(descriptor("parakeet-eou-160").languages == ["en"])
        #expect(Set(descriptor("nemotron-latin-1120").languages) == ["de", "en", "fr", "es", "it", "pt"])
        #expect(descriptor("nemotron-multilingual-1120").languages.count > 6)
        #expect(descriptor("parakeet-v3").languages.count == 25)
    }

    @Test func tiersHaveNamedChunks() {
        #expect(NemotronInstaller.supportedChunks == [560, 1120, 2240])
    }
}
}
