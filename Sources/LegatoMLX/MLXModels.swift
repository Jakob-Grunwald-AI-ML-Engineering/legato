import Foundation
import LegatoModels

/// One downloadable MLX language model: the catalog entry plus what loading it needs.
public struct MLXModelSpec: Sendable, Hashable {
    /// The catalog id. Stable: ``SelectionStore`` persists it.
    public let id: String
    /// The Hugging Face repository, for example `mlx-community/Qwen3-0.6B-4bit`.
    public let repo: String
    /// The commit of ``repo`` that is downloaded: a 40-character hash, never a branch, so a changed
    /// upstream repository cannot swap the weights of a released build.
    public let revision: String
    public let displayName: String
    /// Approximate download size, shown before the user commits to a pick.
    public let approxBytes: Int64
    public let licence: String
    public let family: String
    public let platforms: Set<ModelPlatform>
    /// End-of-turn tokens the tokenizer config does not declare.
    public let extraEOSTokens: Set<String>

    public init(
        id: String, repo: String, revision: String = "main", displayName: String, approxBytes: Int64, licence: String, family: String,
        platforms: Set<ModelPlatform>, extraEOSTokens: Set<String> = []
    ) {
        self.id = id
        self.repo = repo
        self.revision = revision
        self.displayName = displayName
        self.approxBytes = approxBytes
        self.licence = licence
        self.family = family
        self.platforms = platforms
        self.extraEOSTokens = extraEOSTokens
    }

    /// The repo name, which is the folder under `<root>/mlx/`.
    public var folderName: String { repo.split(separator: "/").last.map(String.init) ?? repo }

    public var descriptor: ModelDescriptor {
        ModelDescriptor(
            id: id, kind: .llm, displayName: displayName, approxBytes: approxBytes, licence: licence,
            platforms: platforms, family: family)
    }

    /// `<root>/mlx/<repo-name>`.
    public func folder(root: URL) -> URL {
        root.appending(path: "mlx", directoryHint: .isDirectory)
            .appending(path: folderName, directoryHint: .isDirectory)
    }
}

/// The MLX cleanup models on offer. There is no default: the user picks one, and picking installs it.
public enum MLXModels {
    public static let qwen3_0_6bID = "mlx-qwen3-0.6b-4bit"
    public static let qwen3_1_7bID = "mlx-qwen3-1.7b-4bit"
    public static let gemma3_1bID = "mlx-gemma3-1b-4bit"

    /// Sizes are the repositories' file totals. The 1.7B model needs about 1 GB of weights in memory, which
    /// the phone's per-app limit does not leave room for next to a speech model, so it lists on the Mac only.
    public static let specs: [MLXModelSpec] = [
        MLXModelSpec(
            id: qwen3_0_6bID, repo: "mlx-community/Qwen3-0.6B-4bit", revision: "73e3e38d981303bc594367cd910ea6eb48349da8",
            displayName: "Qwen3 0.6B (4-bit)",
            approxBytes: 351_000_000, licence: "Apache-2.0", family: "qwen3",
            platforms: [.iOS, .macOS], extraEOSTokens: ["<|im_end|>"]),
        MLXModelSpec(
            id: qwen3_1_7bID, repo: "mlx-community/Qwen3-1.7B-4bit", revision: "3b1b1768f8f8cf8351c712464f906e86c2b8269e",
            displayName: "Qwen3 1.7B (4-bit)",
            approxBytes: 984_000_000, licence: "Apache-2.0", family: "qwen3",
            platforms: [.macOS], extraEOSTokens: ["<|im_end|>"]),
        MLXModelSpec(
            id: gemma3_1bID, repo: "mlx-community/gemma-3-1b-it-qat-4bit", revision: "15fed4eafb456c6fcb2a1165f19ac609670ed14b",
            displayName: "Gemma 3 1B (4-bit)",
            approxBytes: 772_000_000, licence: "Gemma Terms of Use", family: "gemma3",
            platforms: [.iOS, .macOS], extraEOSTokens: ["<end_of_turn>"]),
    ]

    public static func spec(id: String) -> MLXModelSpec? {
        specs.first { $0.id == id }
    }

    /// The catalog entries that run on `platform`.
    public static func descriptors(platform: ModelPlatform = .current) -> [ModelDescriptor] {
        specs.filter { $0.platforms.contains(platform) }.map(\.descriptor)
    }

    /// One installer per entry of ``descriptors(platform:)``, keyed by id. Creating them downloads nothing.
    public static func installers(
        platform: ModelPlatform = .current,
        fetcher: any MLXFileFetcher = HubFileFetcher()
    ) -> [String: any ModelInstaller] {
        Dictionary(uniqueKeysWithValues: specs.filter { $0.platforms.contains(platform) }.map {
            ($0.id, MLXInstaller(spec: $0, fetcher: fetcher) as any ModelInstaller)
        })
    }

    /// Lets go of the loaded copy of the model in `folder`. Pass it as the model manager's `onDelete` (as
    /// ``makeManager(root:selection:platform:fetcher:)`` does) so deleting a model also frees its memory.
    public static func release(folder: URL) async {
        await MLXModelCache.shared.evict(folder: folder)
    }

    /// A manager over the MLX catalog for `platform`, storing under `root`. Deleting a model also
    /// releases its loaded copy.
    public static func makeManager(
        root: URL,
        selection: SelectionStore = SelectionStore(),
        platform: ModelPlatform = .current,
        fetcher: any MLXFileFetcher = HubFileFetcher()
    ) -> ModelManager {
        ModelManager(
            root: root,
            catalog: descriptors(platform: platform),
            installers: installers(platform: platform, fetcher: fetcher),
            selection: selection,
            onDelete: { _, folder in await release(folder: folder) })
    }
}
