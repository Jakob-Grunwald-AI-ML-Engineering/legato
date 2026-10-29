import LegatoANEMLL
import CoreML
import Foundation
import LegatoCore

/// Native objects are confined to CoreMLBackend's lease, including cancellation and preparation.
final class NativeCoreMLDriver: CoreMLDriving, @unchecked Sendable {
    let contextLength: Int
    let batchSize: Int
    let promptFamily: CoreMLPromptFamily
    private let tokenizer: LegatoANEMLL.Tokenizer
    private let manager: InferenceManager
    private let cancellation: CoreMLCancellation
    private init(config: YAMLConfig, promptFamily: CoreMLPromptFamily, tokenizer: LegatoANEMLL.Tokenizer, manager: InferenceManager, cancellation: CoreMLCancellation) {
        self.promptFamily = promptFamily; self.contextLength = config.contextLength; self.batchSize = config.batchSize; self.tokenizer = tokenizer; self.manager = manager; self.cancellation = cancellation
    }
    static func load(spec: CoreMLModelSpec, folder: URL, cancellation: CoreMLCancellation) async throws -> NativeCoreMLDriver {
        let config = try YAMLConfig.load(from: folder.appending(path: "meta.yaml").path)
        try spec.runtimeConfiguration.validate(.init(
            version: config.configVersion, contextLength: config.contextLength, batchSize: config.batchSize,
            numChunks: config.numChunks, modelPrefix: config.modelPrefix, splitLMHead: config.splitLMHead,
            argmaxInModel: config.argmaxInModel, slidingWindow: config.slidingWindow,
            updateMaskPrefill: config.updateMaskPrefill, prefillDynamicSlice: config.prefillDynamicSlice,
            vocabSize: config.vocabSize, lmHeadChunkSizes: config.lmHeadChunkSizes))
        try cancellation.check()
        let tokenizer = try await LegatoANEMLL.Tokenizer(modelPath: folder.path, template: spec.promptFamily.rawValue, debugLevel: 0)
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
        return .init(config: config, promptFamily: spec.promptFamily, tokenizer: tokenizer, manager: manager, cancellation: cancellation)
    }
    func tokens(instructions: String, examples: [LLMExample], prompt: String) async throws -> [Int] {
        try cancellation.check()
        let rendered = CoreMLPrompt.render(instructions: instructions, examples: examples, prompt: prompt, family: promptFamily)
        let tokens = tokenizer.rawTokens(rendered)
        let canonical = try tokenizer.canonicalChatTokens(messages: CoreMLPrompt.messages(instructions: instructions, examples: examples, prompt: prompt), thinking: false)
        guard tokens == canonical else { throw LLMError.failed("The installed checkpoint chat template differs from the supported \(promptFamily.rawValue) format.") }
        return tokens
    }
    func encode(_ text: String) async throws -> [Int] {
        try cancellation.check()
        return tokenizer.rawTokens(text)
    }
    func generate(tokens: [Int], outputLimit: Int) async throws -> CoreMLGeneration {
        try await generate(tokens: tokens, reusingPrefix: 0, outputLimit: outputLimit)
    }
    /// `reusingPrefix` is the backend's promise about `manager`'s state (see the vendored
    /// `InferenceManager.generateResponse(reusingPrefix:)`); 0 always starts from a fresh state.
    func generate(tokens: [Int], reusingPrefix: Int, outputLimit: Int) async throws -> CoreMLGeneration {
        let cancellation = cancellation
        let result = try await manager.generateResponse(initialTokens: tokens, temperature: 0, maxTokens: outputLimit, eosTokens: tokenizer.eosTokenIds, tokenizer: tokenizer, onToken: nil, onWindowShift: { cancellation.cancel() }, reusingPrefix: reusingPrefix)
        try cancellation.check()
        return .init(text: tokenizer.decode(tokens: result.0, skipSpecialTokens: true), stopReason: result.2,
                     tokens: result.0, prefilled: tokens.count - reusingPrefix, prefillSeconds: result.1)
    }
}
