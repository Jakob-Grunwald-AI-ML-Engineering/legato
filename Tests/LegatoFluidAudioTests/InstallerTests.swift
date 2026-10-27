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

    /// Every file a Nemotron tier needs, except the entries named in `skipping`.
    func nemotronTier(_ base: String, skipping: Set<String> = []) throws {
        for name in ["metadata.json", "tokenizer.json"] where !skipping.contains(name) { try file("\(base)/\(name)") }
        for name in ["preprocessor.mlmodelc", "encoder.mlmodelc", "decoder.mlmodelc", "joint.mlmodelc"]
        where !skipping.contains(name) {
            try directory("\(base)/\(name)")
        }
    }
}

/// CI stub mode (`LEGATO_STUB_DEPS=1`, see Package.swift): the heavy dependencies are no-behaviour stubs, so tests
/// that exercise their real behaviour are gated on this.
private let stubDeps = ProcessInfo.processInfo.environment["LEGATO_STUB_DEPS"] == "1"

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

    @Test func installedWhenMetadataTokenizerAndEveryModelArePresent() async throws {
        let staged = try StagedRoot()
        defer { staged.remove() }
        let base = "nemotron-multilingual/multilingual/1120ms"
        try staged.nemotronTier(base)
        #expect(await NemotronInstaller(variant: .multilingual, chunkMs: 1120).isInstalled(root: staged.url))
    }

    @Test(arguments: [
        "metadata.json", "tokenizer.json", "preprocessor.mlmodelc", "encoder.mlmodelc", "decoder.mlmodelc", "joint.mlmodelc",
    ])
    func notInstalledWhenARequiredPartIsMissing(missing: String) async throws {
        let staged = try StagedRoot()
        defer { staged.remove() }
        let base = "nemotron-multilingual/latin/560ms"
        try staged.nemotronTier(base, skipping: [missing])
        #expect(await NemotronInstaller(variant: .latin, chunkMs: 560).isInstalled(root: staged.url) == false)
    }

    @Test(arguments: ["encoder.mlmodelc/weights/weight.bin.partial", "tokenizer.json.partial", "metadata.json.partial.etag"])
    func notInstalledWhileADownloadIsStillStaged(partial: String) async throws {
        let staged = try StagedRoot()
        defer { staged.remove() }
        let base = "nemotron-multilingual/multilingual/1120ms"
        try staged.nemotronTier(base)
        let installer = NemotronInstaller(variant: .multilingual, chunkMs: 1120)
        #expect(await installer.isInstalled(root: staged.url), "precondition: the tier is complete")
        try staged.file("\(base)/\(partial)")
        #expect(await installer.isInstalled(root: staged.url) == false)
    }

    @Test func installedStateIsPerTier() async throws {
        let staged = try StagedRoot()
        defer { staged.remove() }
        let base = "nemotron-multilingual/multilingual/2240ms"
        try staged.nemotronTier(base)
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

    @Test(arguments: ["streaming_encoder.mlmodelc/weights/weight.bin.partial", "vocab.json.partial", "decoder.mlmodelc/model.mil.partial.etag"])
    func notInstalledWhileADownloadIsStillStaged(partial: String) async throws {
        let staged = try StagedRoot()
        defer { staged.remove() }
        let base = "parakeet-eou-streaming/160ms"
        for dir in ["streaming_encoder.mlmodelc", "decoder.mlmodelc", "joint_decision.mlmodelc"] {
            try staged.directory("\(base)/\(dir)")
        }
        try staged.file("\(base)/vocab.json")
        let installer = ParakeetEouInstaller(chunk: .ms160)
        #expect(await installer.isInstalled(root: staged.url), "precondition: the model is complete")
        try staged.file("\(base)/\(partial)")
        #expect(await installer.isInstalled(root: staged.url) == false)
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

    @Test(.disabled(if: stubDeps, "needs the real FluidAudio AsrModels.modelsExist"), arguments: [(ParakeetBatchModel.v3, "parakeet-tdt-0.6b-v3"), (.ultra, "parakeet-ultra")])
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

    @Test func everySpeechModelStatesItsRoleAndReach() {
        let streaming = ModelFamily.groups(of: FluidAudioModels.descriptors, kind: .speechStreaming)
        #expect(streaming.map(\.roleLine) == ["Live dictation", "Live dictation", "English only · live dictation"])
        let batch = FluidAudioModels.descriptors.filter { $0.kind == .speechBatch }
        #expect(batch.map(\.roleLine) == ["After meetings · not live", "After meetings · not live"])
    }

    @Test func tiersHaveNamedChunks() {
        #expect(NemotronInstaller.supportedChunks == [560, 1120, 2240])
    }

    @Test func speechTiersGroupIntoThreeFamiliesAndTheBatchModelsStaySeparate() {
        let streaming = ModelFamily.groups(of: FluidAudioModels.descriptors, kind: .speechStreaming)
        #expect(streaming.map(\.id) == ["nemotron-multilingual", "nemotron-latin", "parakeet-eou"])
        #expect(streaming.map(\.name) == ["Nemotron multilingual", "Nemotron Latin", "Parakeet EOU"])
        #expect(streaming.map(\.tiers) == [[560, 1120, 2240], [560, 1120, 2240], [160, 320]])
        let batch = ModelFamily.groups(of: FluidAudioModels.descriptors, kind: .speechBatch)
        #expect(batch.map(\.id) == ["parakeet-v3", "parakeet-ultra"])
    }

    @Test func tierDescriptorsKeepTheirPersistedIDs() throws {
        let nemotron = try #require(ModelFamily.groups(of: FluidAudioModels.descriptors, kind: .speechStreaming).first)
        #expect(nemotron.descriptor(tierMs: 560)?.id == "nemotron-multilingual-560")
        #expect(nemotron.descriptor(tierMs: 1120)?.id == FluidAudioModels.nemotronID(.multilingual, chunkMs: 1120))
        #expect(nemotron.descriptor(tierMs: 2240)?.id == "nemotron-multilingual-2240")
        let eou = try #require(ModelFamily.groups(of: FluidAudioModels.descriptors, kind: .speechStreaming).last)
        #expect(eou.descriptor(tierMs: 160)?.id == "parakeet-eou-160")
        #expect(eou.descriptor(tierMs: 320)?.id == "parakeet-eou-320")
    }

    @Test func everyTierOfAFamilyHasTheSameInstallerKindAndOwnFolder() {
        let root = URL(fileURLWithPath: "/models")
        for family in ModelFamily.groups(of: FluidAudioModels.descriptors, kind: .speechStreaming) {
            #expect(Set(family.members.map(\.languages)).count == 1, "\(family.id): one language set")
            #expect(Set(family.members.map(\.licence)).count == 1, "\(family.id): one licence")
            let folders = family.members.compactMap { FluidAudioModels.installers[$0.id]?.installFolder(root: root).path }
            #expect(Set(folders).count == family.members.count, "\(family.id): one folder per tier")
        }
    }
}
}
