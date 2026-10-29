// Compile-only stand-in. Tests inject Legato's native-driver boundary; this module never infers.
import CoreML
import Foundation
private enum StubError: Error { case unavailable }
public struct YAMLConfig: Sendable {
    public let contextLength = 2048, batchSize = 64, numChunks = 2, splitLMHead = 16
    public let configVersion = "0.3.5", modelPrefix = "qwen"
    public let argmaxInModel = false, updateMaskPrefill = false, prefillDynamicSlice = true
    public let slidingWindow: Int? = nil, vocabSize: Int? = nil, lmHeadChunkSizes: [Int]? = nil
    public static func load(from: String) throws -> Self { throw StubError.unavailable }
}
public final class Tokenizer: Sendable {
    public let eosTokenIds: [Int] = []
    public init(modelPath: String, template: String, debugLevel: Int) async throws { throw StubError.unavailable }
    public func rawTokens(_ text: String) -> [Int] { fatalError("Compile-only stub") }
    public func canonicalChatTokens(messages: [[String: any Sendable]], thinking: Bool) throws -> [Int] { throw StubError.unavailable }
    public func decode(tokens: [Int], skipSpecialTokens: Bool) -> String { fatalError("Compile-only stub") }
}
public struct LoadedModels: Sendable {}
public actor ModelLoader {
    public struct Configuration: @unchecked Sendable { public init(computeUnits: MLComputeUnits) {} }
    public init() {}
    public func loadModel(from: YAMLConfig, configuration: Configuration) async throws -> LoadedModels { throw StubError.unavailable }
    public func cancelLoading() {}
}
public struct SamplingConfig: Sendable { public static let greedy = SamplingConfig() }
public final class InferenceManager: @unchecked Sendable {
    public var cancellationCheck: (@Sendable () throws -> Void)?
    public init(models: LoadedModels, contextLength: Int, batchSize: Int, splitLMHead: Int, debugLevel: Int, v110: Bool, argmaxInModel: Bool, slidingWindow: Int?, updateMaskPrefill: Bool, prefillDynamicSlice: Bool, modelPrefix: String, vocabSize: Int?, lmHeadChunkSizes: [Int]?) throws { throw StubError.unavailable }
    public func setSamplingConfig(_ config: SamplingConfig) {}
    public func generateResponse(initialTokens: [Int], temperature: Float, maxTokens: Int, eosTokens: [Int], tokenizer: Tokenizer, onToken: ((Int) -> Void)?, onWindowShift: (() -> Void)?, reusingPrefix: Int = 0) async throws -> ([Int], TimeInterval, String) { throw StubError.unavailable }
}
