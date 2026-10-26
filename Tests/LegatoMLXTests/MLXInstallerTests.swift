import Foundation
import LegatoModels
import Synchronization
import Testing
@testable import LegatoMLX

private final class ProgressLog: Sendable {
    private let values = Mutex<[Double]>([])
    func add(_ v: Double) { values.withLock { $0.append(v) } }
    var all: [Double] { values.withLock { $0 } }
}

private let qwen06 = MLXModels.spec(id: MLXModels.qwen3_0_6bID)!

@Suite("MLX catalog")
struct MLXCatalogTests {
    @Test func offersTheThreePickableModels() {
        let ids = Set(MLXModels.specs.map(\.id))
        #expect(ids == [MLXModels.qwen3_0_6bID, MLXModels.qwen3_1_7bID, MLXModels.gemma3_1bID])
    }

    @Test func repoIdsAreTheMlxCommunityConversions() {
        #expect(MLXModels.spec(id: MLXModels.qwen3_0_6bID)?.repo == "mlx-community/Qwen3-0.6B-4bit")
        #expect(MLXModels.spec(id: MLXModels.qwen3_1_7bID)?.repo == "mlx-community/Qwen3-1.7B-4bit")
        #expect(MLXModels.spec(id: MLXModels.gemma3_1bID)?.repo == "mlx-community/gemma-3-1b-it-qat-4bit")
    }

    @Test func everyDescriptorIsAnLlmThatFitsTheCleanupRole() {
        for descriptor in MLXModels.descriptors(platform: .macOS) {
            #expect(descriptor.kind == .llm)
            #expect(descriptor.kind == ModelRole.cleanup.kind)
            #expect(descriptor.approxBytes > 100_000_000)
        }
    }

    @Test func platformFlagsDecideWhatEachPlatformListsIncludingTheSmallModelOnPhone() {
        let mac = Set(MLXModels.descriptors(platform: .macOS).map(\.id))
        let phone = Set(MLXModels.descriptors(platform: .iOS).map(\.id))
        #expect(mac == [MLXModels.qwen3_0_6bID, MLXModels.qwen3_1_7bID, MLXModels.gemma3_1bID])
        #expect(phone == [MLXModels.qwen3_0_6bID, MLXModels.gemma3_1bID])
    }

    @Test func everyModelIsPinnedToACommitHash() {
        for spec in MLXModels.specs {
            #expect(
                spec.revision.count == 40 && spec.revision.allSatisfy { $0.isHexDigit && !$0.isUppercase },
                "\(spec.id): \(spec.revision) is not a 40-character commit hash")
        }
    }

    @Test func eachListedModelHasAnInstallerAndNoneHasADefault() {
        let installers = MLXModels.installers(platform: .macOS, fetcher: FakeFetcher())
        #expect(Set(installers.keys) == Set(MLXModels.descriptors(platform: .macOS).map(\.id)))
    }
}

@Suite("MLXInstaller")
struct MLXInstallerTests {
    private func installer(_ fetcher: FakeFetcher = FakeFetcher(),
                           loader: @escaping @Sendable (MLXModelSpec, URL) async throws -> Void = { _, _ in }) -> MLXInstaller {
        MLXInstaller(spec: qwen06, fetcher: fetcher, loader: loader)
    }

    @Test func installsUnderMlxSlashTheRepoName() {
        let root = URL(filePath: "/tmp/legato-root")
        #expect(installer().installFolder(root: root).path == "/tmp/legato-root/mlx/Qwen3-0.6B-4bit")
    }

    @Test func installStagesWeightsAndTokenizerIntoTheLegatoRoot() async throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fetcher = FakeFetcher()
        let installer = installer(fetcher)
        let log = ProgressLog()

        #expect(await installer.isInstalled(root: root) == false)
        try await installer.install(root: root) { log.add($0) }

        let call = try #require(fetcher.recorded.first)
        #expect(call.repo == "mlx-community/Qwen3-0.6B-4bit")
        #expect(call.revision == qwen06.revision, "the download is pinned to the spec's commit")
        #expect(call.folder == installer.installFolder(root: root))
        for pattern in ["*.safetensors", "*.json"] { #expect(call.patterns.contains(pattern)) }
        for name in ["config.json", "tokenizer.json", "model.safetensors"] {
            #expect(FileManager.default.fileExists(atPath: call.folder.appending(path: name).path), "missing \(name)")
        }
        #expect(await installer.isInstalled(root: root))
        #expect(log.all.last == 1.0)
        #expect(log.all == log.all.sorted())
    }

    @Test(arguments: [
        ["tokenizer.json", "model.safetensors"],  // no config
        ["config.json", "model.safetensors"],  // no tokenizer
        ["config.json", "tokenizer.json"],  // no weights
        ["config.json", "tokenizer.json", "model.safetensors.part"],  // a partial download
        [],
    ])
    func partialFoldersAreNotInstalled(_ files: [String]) async throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let installer = installer()
        let folder = installer.installFolder(root: root)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for name in files { try Data("x".utf8).write(to: folder.appending(path: name)) }
        #expect(await installer.isInstalled(root: root) == false)
    }

    @Test func aSentencePieceTokenizerCounts() async throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let installer = installer(FakeFetcher(files: ["config.json", "tokenizer.model", "model.safetensors"]))
        try await installer.install(root: root) { _ in }
        #expect(await installer.isInstalled(root: root))
    }

    @Test func shardedWeightsNeedEveryShard() async throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let installer = installer()
        let folder = installer.installFolder(root: root)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: folder.appending(path: "config.json"))
        try Data("x".utf8).write(to: folder.appending(path: "tokenizer.json"))
        try Data("x".utf8).write(to: folder.appending(path: "model-00001-of-00002.safetensors"))
        let index = #"{"weight_map": {"a": "model-00001-of-00002.safetensors", "b": "model-00002-of-00002.safetensors"}}"#
        try Data(index.utf8).write(to: folder.appending(path: "model.safetensors.index.json"))
        #expect(await installer.isInstalled(root: root) == false)
        try Data("x".utf8).write(to: folder.appending(path: "model-00002-of-00002.safetensors"))
        #expect(await installer.isInstalled(root: root))
    }

    @Test func aFetchFailureSurfaces() async {
        struct Offline: Error {}
        let installer = installer(FakeFetcher(files: [], failure: Offline()))
        let root = tempRoot()
        await #expect(throws: Offline.self) { try await installer.install(root: root) { _ in } }
        #expect(await installer.isInstalled(root: root) == false)
    }

    @Test func checkingNeverDownloads() async {
        let fetcher = FakeFetcher()
        let installer = installer(fetcher)
        _ = await installer.isInstalled(root: tempRoot())
        _ = installer.installFolder(root: tempRoot())
        #expect(fetcher.recorded.isEmpty)
    }

    @Test func warmLoadsTheInstalledFolderOnce() async throws {
        let root = tempRoot()
        let loaded = Mutex<[URL]>([])
        let installer = installer(loader: { _, folder in loaded.withLock { $0.append(folder) } })
        try await installer.warm(root: root)
        #expect(loaded.withLock { $0 } == [installer.installFolder(root: root)])
    }

    @Test func pickingAModelInstallsItThroughTheManagerAndSelectsIt() async throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (defaults, suite) = freshDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let fetcher = FakeFetcher()
        let warmed = Mutex(0)
        let manager = ModelManager(
            root: root,
            catalog: [qwen06.descriptor],
            installers: [qwen06.id: MLXInstaller(spec: qwen06, fetcher: fetcher, loader: { _, _ in warmed.withLock { $0 += 1 } })],
            selection: SelectionStore(defaults: defaults))

        #expect(await manager.selected(role: .cleanup) == nil)
        try await manager.select(qwen06.id, role: .cleanup)
        #expect(await manager.selected(role: .cleanup) == qwen06.id)
        #expect(fetcher.recorded.count == 1)
        #expect(warmed.withLock { $0 } == 1)
        guard case .installed = await manager.state(of: qwen06.id) else {
            Issue.record("not installed")
            return
        }
    }
}

// MARK: Hub requests

/// Answers every request with a 503 and records it, so the fetcher's requests can be read without a network.
private final class RecordingProtocol: URLProtocol, @unchecked Sendable {
    static let requests = Mutex<[URLRequest]>([])

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requests.withLock { $0.append(request) }
        let response = HTTPURLResponse(url: request.url!, statusCode: 503, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data())
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Suite("HubFileFetcher", .serialized)
struct HubFileFetcherTests {
    @Test func askForThePinnedCommitWithoutSendingAnyToken() async {
        RecordingProtocol.requests.withLock { $0 = [] }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RecordingProtocol.self]
        let fetcher = HubFileFetcher(session: URLSession(configuration: configuration))
        let folder = tempRoot()
        defer { try? FileManager.default.removeItem(at: folder) }
        // A token in the environment must not reach a public download.
        setenv("HF_TOKEN", "hf_secret_token_for_test", 1)
        defer { unsetenv("HF_TOKEN") }

        _ = try? await fetcher.fetch(
            repo: qwen06.repo, revision: qwen06.revision, to: folder, matching: MLXInstaller.filePatterns
        ) { _ in }

        let requests = RecordingProtocol.requests.withLock { $0 }
        #expect(!requests.isEmpty)
        for request in requests {
            #expect(request.value(forHTTPHeaderField: "Authorization") == nil, "\(request.url?.absoluteString ?? "")")
            #expect(request.url?.host == "huggingface.co")
        }
        #expect(
            requests.contains { $0.url?.absoluteString.contains(qwen06.revision) == true },
            "the commit appears in the request: \(requests.compactMap { $0.url?.absoluteString })")
    }
}
