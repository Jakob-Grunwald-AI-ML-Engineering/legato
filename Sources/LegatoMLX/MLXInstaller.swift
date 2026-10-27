import Foundation
import HuggingFace
import LegatoModels

/// Downloads a model repository's files into a folder. A seam so tests stage files without the network.
public protocol MLXFileFetcher: Sendable {
    /// Downloads the files of `repo` at `revision` matching `patterns` into `folder`, reporting the
    /// fraction done. Honors task cancellation by throwing.
    func fetch(
        repo: String, revision: String, to folder: URL, matching patterns: [String],
        progress: @escaping @Sendable (Double) -> Void
    ) async throws
}

/// Hugging Face Hub downloads through swift-huggingface into the Legato folder.
///
/// The Hub client only downloads through a cache, so the cache lives in a `.hub-cache` folder inside the
/// target folder (never `~/.cache/huggingface`). The snapshot is copied out (a clone on APFS, so no second
/// copy of the weights) and the cache removed, which also leaves nothing behind when the manager deletes
/// the folder after a cancel.
public struct HubFileFetcher: MLXFileFetcher {
    private let session: URLSession

    /// - Parameter session: the URL session the Hub client uses; tests pass one that records requests.
    public init(session: URLSession = URLSession(configuration: .default)) {
        self.session = session
    }

    public func fetch(
        repo: String, revision: String, to folder: URL, matching patterns: [String],
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        guard let id = Repo.ID(rawValue: repo) else {
            throw MLXInstallError.invalidRepository(repo)
        }
        let cacheFolder = folder.appending(path: ".hub-cache", directoryHint: .isDirectory)
        // Public repositories need no account: no token (so none from the environment is sent either) and the
        // fixed Hub host, not the `HF_ENDPOINT` one, since the download is pinned to a commit of that host.
        let client = HubClient(
            session: session, host: HubClient.defaultHost, tokenProvider: .none,
            cache: HubCache(cacheDirectory: cacheFolder))
        _ = try await client.downloadSnapshot(
            of: id, to: folder, revision: revision, matching: patterns,
            progressHandler: { @MainActor update in progress(update.fractionCompleted) })
        try? FileManager.default.removeItem(at: cacheFolder)
    }
}

public enum MLXInstallError: Error, Sendable, Equatable {
    case invalidRepository(String)
}

/// Installs one MLX model under `<root>/mlx/<repo-name>`: weights plus tokenizer files.
public struct MLXInstaller: ModelInstaller {
    /// Weights, configs and tokenizer files. The same set mlx-swift-lm's own downloader asks for, plus
    /// SentencePiece models and merge lists.
    public static let filePatterns = ["*.safetensors", "*.json", "*.jinja", "*.txt", "tokenizer.model"]

    private let spec: MLXModelSpec
    private let fetcher: any MLXFileFetcher
    private let loader: (@Sendable (MLXModelSpec, URL) async throws -> Void)?
    private let generator: any MLXGenerating
    private let canUseGPU: @Sendable () async -> Bool

    /// - Parameters:
    ///   - loader: loads the installed folder once so the first cleanup call is fast ("warm"). `nil` uses
    ///     the shared model cache, so ``MLXBackend`` reuses the loaded model.
    public init(
        spec: MLXModelSpec,
        fetcher: any MLXFileFetcher = HubFileFetcher(),
        loader: (@Sendable (MLXModelSpec, URL) async throws -> Void)? = nil
    ) {
        self.init(spec: spec, fetcher: fetcher, loader: loader, generator: MLXChatGenerator(),
                  canUseGPU: CleanupRegistry.defaultCanUseGPU)
    }

    /// The default warm-up loads on the GPU only while `canUseGPU` allows it: a download can finish while
    /// the phone app is in the background, where iOS refuses GPU work.
    init(spec: MLXModelSpec, fetcher: any MLXFileFetcher, loader: (@Sendable (MLXModelSpec, URL) async throws -> Void)? = nil,
         generator: any MLXGenerating, canUseGPU: @escaping @Sendable () async -> Bool) {
        self.spec = spec
        self.fetcher = fetcher
        self.loader = loader
        self.generator = generator
        self.canUseGPU = canUseGPU
    }

    public func installFolder(root: URL) -> URL { spec.folder(root: root) }

    public func isInstalled(root: URL) async -> Bool {
        Self.isComplete(folder: installFolder(root: root))
    }

    /// `config.json`, a tokenizer (`tokenizer.json` or `tokenizer.model`) and every weights file present.
    /// A folder with a `weight_map` index needs each shard it names.
    public static func isComplete(folder: URL) -> Bool {
        let fm = FileManager.default
        func exists(_ name: String) -> Bool { fm.fileExists(atPath: folder.appending(path: name).path) }
        guard exists("config.json"), exists("tokenizer.json") || exists("tokenizer.model") else { return false }
        let names = (try? fm.contentsOfDirectory(atPath: folder.path)) ?? []
        guard names.contains(where: { $0.hasSuffix(".safetensors") }) else { return false }
        guard let data = try? Data(contentsOf: folder.appending(path: "model.safetensors.index.json")),
              let index = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let map = index["weight_map"] as? [String: String]
        else { return true }
        return Set(map.values).allSatisfy(exists)
    }

    public func install(root: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        let folder = installFolder(root: root)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try await fetcher.fetch(repo: spec.repo, revision: spec.revision, to: folder, matching: Self.filePatterns, progress: progress)
        try Task.checkCancellation()
        guard Self.isComplete(folder: folder) else { throw MLXInstallError.invalidRepository(spec.repo) }
    }

    public func warm(root: URL) async throws {
        let folder = installFolder(root: root)
        if let loader {
            try await loader(spec, folder)
        } else {
            try await generator.load(spec: spec, folder: folder, device: await canUseGPU() ? .gpu : .cpu)
        }
    }
}
