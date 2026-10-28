import CryptoKit
import Foundation
import LegatoModels
import Synchronization
import Testing
@testable import LegatoCoreML

private let fixtureBytes = Data("fixture".utf8)
private let fixtureHash = SHA256.hash(data: fixtureBytes).map { String(format: "%02x", $0) }.joined()
private let artifactParts = ["qwen_embeddings", "qwen_lm_head_lut6", "qwen_FFN_PF_lut6_chunk_01of02", "qwen_FFN_PF_lut6_chunk_02of02"]
private func fixtureManifest() -> CoreMLManifest {
    let files = ["README.md", "config.json", "meta.yaml", "tokenizer.json", "tokenizer_config.json"] + artifactParts.flatMap { part in ["analytics/coremldata.bin", "coremldata.bin", "metadata.json", "model.mil", "weights/weight.bin"].map { "\(part).mlmodelc/\($0)" } }
    return .init(repository: "anemll/anemll-Qwen-Qwen3-1.7B-ctx2048_0.3.5", revision: "0977a61d00e39118aab5ed1e510f1d228df5eefd", files: files.map { .init(path: $0, bytes: 7, sha256: fixtureHash) })
}
private final class ArtifactFetcher: CoreMLFileFetcher, Sendable {
    let calls = Mutex<[URL]>([])
    let corrupt: Bool
    let cancelled: Bool
    init(corrupt: Bool = false, cancelled: Bool = false) { self.corrupt = corrupt; self.cancelled = cancelled }
    func fetch(_ source: URL, to destination: URL) async throws {
        calls.withLock { $0.append(source) }
        try (corrupt ? Data("invalid".utf8) : fixtureBytes).write(to: destination)
        if cancelled { throw CancellationError() }
    }
}
private func artifactRoot() -> URL { FileManager.default.temporaryDirectory.appending(path: "legato-coreml-\(UUID().uuidString)", directoryHint: .isDirectory) }
struct CoreMLInstallerTests {
    private let spec = CoreMLModels.specs[0]
    @Test func pinnedManifestContainsEveryNativePartAndHash() throws {
        let manifest = try CoreMLManifest.bundled(for: spec)
        try manifest.validate(for: spec)
        #expect(manifest.revision == "0977a61d00e39118aab5ed1e510f1d228df5eefd")
        #expect(manifest.files.count == 25)
        let embeddings = try #require(manifest.files.first { $0.path == "qwen_embeddings.mlmodelc/weights/weight.bin" })
        #expect(embeddings.sha256 == "80d4a53fa6ef9baa7f3411fbab47dfcc6434c4045af34d06fba90fbff676d8c8")
        #expect(embeddings.bytes == 622_329_984)
        #expect(Set(CoreMLModels.descriptors(platform: .iOS).map(\.id)) == ["coreml-qwen3-1.7b-lut6"])
        #expect(Set(CoreMLModels.descriptors(platform: .macOS).map(\.id)) == ["coreml-qwen3-1.7b-lut6"])
    }
    @Test(arguments: ["../escape", "/absolute", "a/../../escape", "a//b", "a/./b"])
    func rejectsTraversalAndAbsolutePaths(_ path: String) {
        let manifest = CoreMLManifest(repository: spec.repo, revision: spec.revision, files: [.init(path: path, bytes: 7, sha256: fixtureHash)])
        #expect(throws: (any Error).self) { try manifest.validate(for: spec) }
    }
    @Test func rejectsMissingChunkAndWrongRevision() {
        let fixture = fixtureManifest()
        let missing = CoreMLManifest(repository: fixture.repository, revision: fixture.revision, files: fixture.files.filter { !$0.path.contains("02of02") })
        #expect(throws: (any Error).self) { try missing.validate(for: spec) }
        let changed = CoreMLManifest(repository: fixture.repository, revision: String(repeating: "a", count: 40), files: fixture.files)
        #expect(throws: (any Error).self) { try changed.validate(for: spec) }
    }
    @Test func installsVerifiedFilesUsingOnlyPinnedRevisionAndReusesValidFiles() async throws {
        let root = artifactRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let fetcher = ArtifactFetcher()
        let installer = CoreMLInstaller(spec: spec, fetcher: fetcher, manifest: fixtureManifest())
        #expect(await installer.isInstalled(root: root) == false)
        try await installer.install(root: root) { _ in }
        #expect(await installer.isInstalled(root: root))
        #expect(fetcher.calls.withLock { $0.count } == 25)
        #expect(fetcher.calls.withLock { $0.allSatisfy { $0.host == "huggingface.co" && $0.path.contains("/resolve/0977a61d00e39118aab5ed1e510f1d228df5eefd/") } })
        try await installer.install(root: root) { _ in }
        #expect(fetcher.calls.withLock { $0.count } == 25)
        let missing = installer.installFolder(root: root).appending(path: "qwen_FFN_PF_lut6_chunk_02of02.mlmodelc/weights/weight.bin")
        try FileManager.default.removeItem(at: missing)
        #expect(await installer.isInstalled(root: root) == false)
    }
    @Test func refusesSameSizeCorruptionWithoutMarkingInstallComplete() async {
        let root = artifactRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let installer = CoreMLInstaller(spec: spec, fetcher: ArtifactFetcher(corrupt: true), manifest: fixtureManifest())
        await #expect(throws: (any Error).self) { try await installer.install(root: root) { _ in } }
        #expect(await installer.isInstalled(root: root) == false)
    }
    @Test func cancellationLeavesNoCompleteInstallation() async {
        let root = artifactRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let installer = CoreMLInstaller(spec: spec, fetcher: ArtifactFetcher(cancelled: true), manifest: fixtureManifest())
        await #expect(throws: CancellationError.self) { try await installer.install(root: root) { _ in } }
        #expect(await installer.isInstalled(root: root) == false)
    }
}

extension CoreMLInstallerTests {
    @Test func sameSizeModificationInvalidatesCheapReadinessAndFullHashVerification() async throws {
        let root = artifactRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let manifest = fixtureManifest()
        let installer = CoreMLInstaller(spec: spec, fetcher: ArtifactFetcher(), manifest: manifest)
        try await installer.install(root: root) { _ in }
        let folder = installer.installFolder(root: root)
        let changed = folder.appending(path: "tokenizer.json")
        try Data("changed".utf8).write(to: changed)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_000)], ofItemAtPath: changed.path)
        #expect(await installer.isInstalled(root: root) == false)
        #expect(throws: (any Error).self) { try CoreMLReceipt.inspect(folder: folder, manifest: manifest, verifyHashes: true) }
    }
    @Test func symbolicModelParentCannotRedirectWritesOutsideStorageRoot() async throws {
        let root = artifactRoot(), outside = artifactRoot()
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: root.appending(path: "coreml"), withDestinationURL: outside)
        let installer = CoreMLInstaller(spec: spec, fetcher: ArtifactFetcher(), manifest: fixtureManifest())
        await #expect(throws: (any Error).self) { try await installer.install(root: root) { _ in } }
        #expect(FileManager.default.fileExists(atPath: outside.appending(path: "qwen3-1.7b").path) == false)
        #expect(await installer.isInstalled(root: root) == false)
    }
}
