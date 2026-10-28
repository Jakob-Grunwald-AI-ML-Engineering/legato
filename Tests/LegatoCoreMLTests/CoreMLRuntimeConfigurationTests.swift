import Testing
@testable import LegatoCoreML

struct CoreMLRuntimeConfigurationTests {
    @Test func qwen06UsesThePublishedLUT8CheckpointConfiguration() throws {
        let spec = try #require(CoreMLModels.spec(id: "coreml-qwen3-0.6b-lut8"))
        let config = spec.runtimeConfiguration
        #expect(spec.manifestResource == "qwen3-0.6b")
        #expect(spec.promptFamily == .qwen3)
        #expect(config.version == "0.3.4")
        #expect(config.contextLength == 4_096)
        #expect(config.batchSize == 64)
        #expect(config.numChunks == 1)
        #expect(config.modelPrefix == "qwen")
        #expect(config.splitLMHead == 16)
        #expect(config.argmaxInModel == false)
        #expect(config.slidingWindow == nil)
        #expect(config.updateMaskPrefill == false)
        #expect(config.prefillDynamicSlice == false)
        #expect(config.vocabSize == nil)
        #expect(config.lmHeadChunkSizes == nil)
    }

    @Test func gemmaPreservesRotationArgmaxVocabularyAndHeadChunks() throws {
        let spec = try #require(CoreMLModels.spec(id: "coreml-gemma3-1b-lut6"))
        let config = spec.runtimeConfiguration
        #expect(spec.manifestResource == "gemma3-1b")
        #expect(spec.promptFamily == .gemma3)
        #expect(config.version == "0.3.5")
        #expect(config.contextLength == 4_096)
        #expect(config.batchSize == 64)
        #expect(config.numChunks == 1)
        #expect(config.modelPrefix == "gemma3")
        #expect(config.splitLMHead == 16)
        #expect(config.argmaxInModel)
        #expect(config.slidingWindow == 512)
        #expect(config.updateMaskPrefill == false)
        #expect(config.prefillDynamicSlice)
        #expect(config.vocabSize == 262_144)
        #expect(config.lmHeadChunkSizes == Array(repeating: 16_384, count: 16))
    }

    @Test(arguments: ["version", "context", "batch", "chunks", "prefix", "head", "argmax", "sliding", "mask", "dynamic", "vocab", "headChunks"])
    func rejectsEveryUnsupportedNativeConfigurationField(_ changed: String) {
        let actual = CoreMLRuntimeConfiguration(
            version: changed == "version" ? "0.3.5" : "0.3.4",
            contextLength: changed == "context" ? 2_048 : 4_096,
            batchSize: changed == "batch" ? 32 : 64,
            numChunks: changed == "chunks" ? 2 : 1,
            modelPrefix: changed == "prefix" ? "gemma3" : "qwen",
            splitLMHead: changed == "head" ? 8 : 16,
            argmaxInModel: changed == "argmax", slidingWindow: changed == "sliding" ? 512 : nil,
            updateMaskPrefill: changed == "mask", prefillDynamicSlice: changed == "dynamic",
            vocabSize: changed == "vocab" ? 151_936 : nil,
            lmHeadChunkSizes: changed == "headChunks" ? Array(repeating: 9_496, count: 16) : nil)
        #expect(throws: CoreMLInstallError.invalidManifest) { try CoreMLRuntimeConfiguration.qwen3_0_6b.validate(actual) }
    }

    @Test(arguments: CoreMLModels.specs)
    func acceptsEachPinnedConfiguration(_ spec: CoreMLModelSpec) throws {
        try spec.runtimeConfiguration.validate(spec.runtimeConfiguration)
    }
}
