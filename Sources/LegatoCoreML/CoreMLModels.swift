import Foundation
import LegatoModels

public struct CoreMLModelSpec: Sendable, Hashable {
    public let id: String
    public let repo: String
    public let revision: String
    public let displayName: String
    public let approxBytes: Int64
    public let licence: String
    public let family: String
    public let folderName: String
    public let platforms: Set<ModelPlatform>
    public let manifestResource: String
    public let promptFamily: CoreMLPromptFamily
    public let runtimeConfiguration: CoreMLRuntimeConfiguration
    let artifactParts: [String]
    let ancillaryFiles: [String]

    init(id: String, repo: String, revision: String, displayName: String, approxBytes: Int64,
         licence: String, family: String, folderName: String, platforms: Set<ModelPlatform>,
         manifestResource: String = "qwen3-1.7b", promptFamily: CoreMLPromptFamily = .qwen3,
         runtimeConfiguration: CoreMLRuntimeConfiguration = .qwen3_1_7b,
         artifactParts: [String] = ["qwen_embeddings", "qwen_lm_head_lut6", "qwen_FFN_PF_lut6_chunk_01of02", "qwen_FFN_PF_lut6_chunk_02of02"],
         ancillaryFiles: [String] = ["README.md", "config.json", "meta.yaml", "tokenizer.json", "tokenizer_config.json"]) {
        self.id = id; self.repo = repo; self.revision = revision; self.displayName = displayName
        self.approxBytes = approxBytes; self.licence = licence; self.family = family
        self.folderName = folderName; self.platforms = platforms; self.manifestResource = manifestResource
        self.promptFamily = promptFamily; self.runtimeConfiguration = runtimeConfiguration
        self.artifactParts = artifactParts; self.ancillaryFiles = ancillaryFiles
    }

    var requiredArtifactPaths: Set<String> {
        Set(ancillaryFiles + artifactParts.flatMap { part in
            ["analytics/coremldata.bin", "coremldata.bin", "metadata.json", "model.mil", "weights/weight.bin"]
                .map { "\(part).mlmodelc/\($0)" }
        })
    }
    public var descriptor: ModelDescriptor {
        .init(id: id, kind: .llm, displayName: displayName, approxBytes: approxBytes, licence: licence, platforms: platforms, family: family)
    }
    public func folder(root: URL) -> URL { root.appending(path: "coreml", directoryHint: .isDirectory).appending(path: folderName, directoryHint: .isDirectory) }
}

public enum CoreMLModels {
    public static let qwen3_1_7bID = "coreml-qwen3-1.7b-lut6"
    public static let qwen3_0_6bID = "coreml-qwen3-0.6b-lut8"
    public static let gemma3_1bID = "coreml-gemma3-1b-lut6"
    /// New converted checkpoints require native quality and resource validation before release.
    public static let specs: [CoreMLModelSpec] = [
        .init(id: qwen3_1_7bID, repo: "anemll/anemll-Qwen-Qwen3-1.7B-ctx2048_0.3.5", revision: "0977a61d00e39118aab5ed1e510f1d228df5eefd", displayName: "Qwen3 1.7B (Core ML)", approxBytes: 1_953_000_000, licence: "Apache-2.0 (Qwen); MIT (ANEMLL)", family: "qwen3-coreml", folderName: "qwen3-1.7b", platforms: [.iOS, .macOS]),
        .init(id: qwen3_0_6bID, repo: "stemwats/anemll-Qwen3-0.6B-ctx4096-lut8_v0.3.4",
              revision: "1eb386120ff45628b308e9027cb1567e185b431d", displayName: "Qwen3 0.6B (Core ML)",
              approxBytes: 961_377_611, licence: "Apache-2.0 (Qwen); MIT (ANEMLL)", family: "qwen3-coreml",
              folderName: "qwen3-0.6b", platforms: [.iOS, .macOS], manifestResource: "qwen3-0.6b",
              runtimeConfiguration: .qwen3_0_6b,
              artifactParts: ["qwen_embeddings", "qwen_lm_head_lut8", "qwen_FFN_PF_lut8_chunk_01of01"],
              ancillaryFiles: ["README.md", "config.json", "meta.yaml", "tokenizer.json", "tokenizer_config.json", "vocab.json", "merges.txt"]),
        .init(id: gemma3_1bID, repo: "anemll/anemll-google-gemma-3-1b-it-ctx4096_0.3.5",
              revision: "a1b00f628f348c8ff55c9fe088e5db97535fd567", displayName: "Gemma 3 1B (Core ML)",
              approxBytes: 1_437_792_811, licence: "Gemma Terms of Use (Google); MIT (ANEMLL)", family: "gemma3-coreml",
              folderName: "gemma3-1b", platforms: [.iOS, .macOS], manifestResource: "gemma3-1b", promptFamily: .gemma3,
              runtimeConfiguration: .gemma3_1b,
              artifactParts: ["gemma3_embeddings_lut8", "gemma3_lm_head_lut6", "gemma3_FFN_PF_lut6_chunk_01of01"],
              ancillaryFiles: ["README.md", "config.json", "meta.yaml", "tokenizer.json", "tokenizer_config.json", "tokenizer.model"])
    ]
    public static func spec(id: String) -> CoreMLModelSpec? { specs.first { $0.id == id } }
    public static func descriptors(platform: ModelPlatform = .current) -> [ModelDescriptor] { specs.filter { $0.platforms.contains(platform) }.map(\.descriptor) }
    public static func installers(platform: ModelPlatform = .current, fetcher: any CoreMLFileFetcher = CoreMLHTTPFetcher()) -> [String: any ModelInstaller] {
        Dictionary(uniqueKeysWithValues: specs.filter { $0.platforms.contains(platform) }.map { ($0.id, CoreMLInstaller(spec: $0, fetcher: fetcher) as any ModelInstaller) })
    }
    public static func release(folder: URL) async { await CoreMLModelStore.shared.release(folder: folder) }
}
