import LegatoANEMLL
import CoreML
import Foundation
import LegatoCore

/// Native objects are confined to CoreMLBackend's lease, including cancellation and preparation.
final class NativeCoreMLDriver: CoreMLDriving, @unchecked Sendable {
    let contextLength: Int
    private let tokenizer: LegatoANEMLL.Tokenizer
    private let manager: InferenceManager
    private let cancellation: CoreMLCancellation
    private init(config: YAMLConfig, tokenizer: LegatoANEMLL.Tokenizer, manager: InferenceManager, cancellation: CoreMLCancellation) {
        self.contextLength = config.contextLength; self.tokenizer = tokenizer; self.manager = manager; self.cancellation = cancellation
    }
    static func load(folder: URL, cancellation: CoreMLCancellation) async throws -> NativeCoreMLDriver {
        let config = try YAMLConfig.load(from: folder.appending(path: "meta.yaml").path)
        guard config.contextLength == 2_048, config.batchSize == 64, config.numChunks == 2,
              config.modelPrefix == "qwen", config.splitLMHead == 16 else { throw CoreMLInstallError.invalidManifest }
        try cancellation.check()
        let tokenizer = try await LegatoANEMLL.Tokenizer(modelPath: folder.path, template: "qwen3", debugLevel: 0)
        try cancellation.check()
        let loader = ModelLoader()
        let models = try await withTaskCancellationHandler {
            try await loader.loadModel(from: config, configuration: .init(computeUnits: .cpuAndNeuralEngine))
        } onCancel: { Task { await loader.cancelLoading() } }
        try cancellation.check()
        let manager = try InferenceManager(
            models: models, contextLength: config.contextLength, batchSize: config.batchSize,
            splitLMHead: config.splitLMHead, debugLevel: 0, v110: config.configVersion == "0.1.1",
            argmaxInModel: config.argmaxInModel, slidingWindow: config.slidingWindow,
            updateMaskPrefill: config.updateMaskPrefill, prefillDynamicSlice: config.prefillDynamicSlice,
            modelPrefix: config.modelPrefix, vocabSize: config.vocabSize, lmHeadChunkSizes: config.lmHeadChunkSizes)
        manager.setSamplingConfig(.greedy)
        manager.cancellationCheck = { try cancellation.check() }
        return .init(config: config, tokenizer: tokenizer, manager: manager, cancellation: cancellation)
    }
    func tokens(instructions: String, examples: [LLMExample], prompt: String) async throws -> [Int] {
        try cancellation.check()
        let rendered = CoreMLPrompt.render(instructions: instructions, examples: examples, prompt: prompt)
        let tokens = tokenizer.rawTokens(rendered)
        let canonical = try tokenizer.canonicalChatTokens(messages: CoreMLPrompt.messages(instructions: instructions, examples: examples, prompt: prompt), thinking: false)
        guard tokens == canonical else { throw LLMError.failed("The installed checkpoint chat template differs from the supported Qwen3 format.") }
        return tokens
    }
    func generate(tokens: [Int], outputLimit: Int) async throws -> CoreMLGeneration {
        let cancellation = cancellation
        let result = try await manager.generateResponse(initialTokens: tokens, temperature: 0, maxTokens: outputLimit, eosTokens: tokenizer.eosTokenIds, tokenizer: tokenizer, onToken: nil, onWindowShift: { cancellation.cancel() })
        try cancellation.check()
        return .init(text: tokenizer.decode(tokens: result.0, skipSpecialTokens: true), stopReason: result.2)
    }
}
