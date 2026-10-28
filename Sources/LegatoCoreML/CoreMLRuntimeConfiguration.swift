import Foundation

/// The supported native configuration for one immutable converted checkpoint.
public struct CoreMLRuntimeConfiguration: Sendable, Hashable {
    public let version: String
    public let contextLength: Int
    public let batchSize: Int
    public let numChunks: Int
    public let modelPrefix: String
    public let splitLMHead: Int
    public let argmaxInModel: Bool
    public let slidingWindow: Int?
    public let updateMaskPrefill: Bool
    public let prefillDynamicSlice: Bool
    public let vocabSize: Int?
    public let lmHeadChunkSizes: [Int]?

    static let qwen3_1_7b = Self(
        version: "0.3.5", contextLength: 2_048, batchSize: 64, numChunks: 2,
        modelPrefix: "qwen", splitLMHead: 16, argmaxInModel: false, slidingWindow: nil,
        updateMaskPrefill: false, prefillDynamicSlice: true, vocabSize: nil, lmHeadChunkSizes: nil)
    static let qwen3_0_6b = Self(
        version: "0.3.4", contextLength: 4_096, batchSize: 64, numChunks: 1,
        modelPrefix: "qwen", splitLMHead: 16, argmaxInModel: false, slidingWindow: nil,
        updateMaskPrefill: false, prefillDynamicSlice: false, vocabSize: nil, lmHeadChunkSizes: nil)
    static let gemma3_1b = Self(
        version: "0.3.5", contextLength: 4_096, batchSize: 64, numChunks: 1,
        modelPrefix: "gemma3", splitLMHead: 16, argmaxInModel: true, slidingWindow: 512,
        updateMaskPrefill: false, prefillDynamicSlice: true, vocabSize: 262_144,
        lmHeadChunkSizes: Array(repeating: 16_384, count: 16))

    func validate(_ actual: Self) throws {
        guard actual == self else { throw CoreMLInstallError.invalidManifest }
    }
}
