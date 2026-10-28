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
    public var descriptor: ModelDescriptor {
        .init(id: id, kind: .llm, displayName: displayName, approxBytes: approxBytes, licence: licence, platforms: platforms, family: family)
    }
    public func folder(root: URL) -> URL { root.appending(path: "coreml", directoryHint: .isDirectory).appending(path: folderName, directoryHint: .isDirectory) }
}

public enum CoreMLModels {
    public static let qwen3_1_7bID = "coreml-qwen3-1.7b-lut6"
    public static let specs: [CoreMLModelSpec] = [
        .init(id: qwen3_1_7bID, repo: "anemll/anemll-Qwen-Qwen3-1.7B-ctx2048_0.3.5", revision: "0977a61d00e39118aab5ed1e510f1d228df5eefd", displayName: "Qwen3 1.7B (Core ML)", approxBytes: 1_953_000_000, licence: "Apache-2.0 (Qwen); MIT (ANEMLL)", family: "qwen3-coreml", folderName: "qwen3-1.7b", platforms: [.iOS, .macOS])
    ]
    public static func spec(id: String) -> CoreMLModelSpec? { specs.first { $0.id == id } }
    public static func descriptors(platform: ModelPlatform = .current) -> [ModelDescriptor] { specs.filter { $0.platforms.contains(platform) }.map(\.descriptor) }
    public static func installers(platform: ModelPlatform = .current, fetcher: any CoreMLFileFetcher = CoreMLHTTPFetcher()) -> [String: any ModelInstaller] {
        Dictionary(uniqueKeysWithValues: specs.filter { $0.platforms.contains(platform) }.map { ($0.id, CoreMLInstaller(spec: $0, fetcher: fetcher) as any ModelInstaller) })
    }
    public static func release(folder: URL) async { await CoreMLModelStore.shared.release(folder: folder) }
}
