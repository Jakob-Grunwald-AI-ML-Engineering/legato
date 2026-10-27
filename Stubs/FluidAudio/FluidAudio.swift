// CI-ONLY STUB of the `FluidAudio` module. Never shipped; used only when Package.swift runs with
// LEGATO_STUB_DEPS=1 so CI can compile and test the package without building FluidAudio.
// It declares ONLY the symbols Legato's own code and tests use, with matching signatures and no behaviour.
// When the real dependency is bumped, or Legato calls a new API from it, update this stub to match.

import AVFAudio
import CoreML
import Foundation

public struct DownloadProgress: Sendable {
    public var fractionCompleted: Double
}
public typealias ProgressHandler = @Sendable (DownloadProgress) -> Void

public enum Repo: Sendable, CaseIterable {
    case nemotronMultilingual, parakeetV3, parakeetUltra, parakeetEou160, parakeetEou320
    // Plain data (no behaviour): the tests stage files and check pins against these.
    public var folderName: String {
        switch self {
        case .nemotronMultilingual: "nemotron-multilingual"
        case .parakeetV3: "parakeet-tdt-0.6b-v3"
        case .parakeetUltra: "parakeet-ultra"
        case .parakeetEou160: "parakeet-eou-streaming/160ms"
        case .parakeetEou320: "parakeet-eou-streaming/320ms"
        }
    }
    public var remotePath: String {
        switch self {
        case .nemotronMultilingual: "FluidInference/Nemotron-3.5-ASR-Streaming-Multilingual-0.6b-CoreML"
        case .parakeetV3: "FluidInference/parakeet-tdt-0.6b-v3-coreml"
        case .parakeetUltra: "FluidInference/parakeet-ultra-coreml"
        case .parakeetEou160: "FluidInference/parakeet-realtime-eou-120m-coreml"
        case .parakeetEou320: "FluidInference/parakeet-realtime-eou-120m-coreml"
        }
    }
}

public enum StreamingChunkSize: Sendable { case ms160, ms320 }
public enum AsrModelVersion: Sendable { case v3, ultra }

public enum MLModelConfigurationUtils {
    public static func defaultConfiguration(computeUnits: MLComputeUnits) -> MLModelConfiguration {
        fatalError("stub: MLModelConfigurationUtils.defaultConfiguration")
    }
}

public enum ModelRegistry {
    nonisolated(unsafe) public static var revisionOverrides: [String: String] = [:]
}

public enum ModelNames {
    public enum NemotronMultilingualStreaming {
        public static let metadata = "metadata.json"
        public static let tokenizer = "tokenizer.json"
        public static let preprocessorFile = "preprocessor.mlmodelc"
        public static let encoderFile = "encoder.mlmodelc"
        public static let decoderFile = "decoder.mlmodelc"
        public static let jointFile = "joint.mlmodelc"
    }
    public enum ParakeetEOU {
        public static let requiredModels: Set<String> = [
            "streaming_encoder.mlmodelc", "decoder.mlmodelc", "joint_decision.mlmodelc", "vocab.json",
        ]
    }
}

public enum ModelHub {
    public static func download(
        _ repo: Repo, to directory: URL, additionalModelNames: Set<String>,
        progressHandler: ProgressHandler?
    ) async throws {
        fatalError("stub: ModelHub.download")
    }
}

public struct SharedNemotronMultilingualModels: Sendable {}

// Plain data (no behaviour): the vocabulary tests read the terms Legato builds.
public struct CustomVocabularyTerm: Sendable {
    public let text: String
    public let weight: Float?
    public let aliases: [String]?
    public init(text: String, weight: Float? = nil, aliases: [String]? = nil) {
        self.text = text
        self.weight = weight
        self.aliases = aliases
    }
}

public actor StreamingNemotronMultilingualAsrManager {
    public init(configuration: MLModelConfiguration) {}
    public static func downloadVariant(
        languageCode: String, chunkMs: Int, to directory: URL, progressHandler: ProgressHandler?
    ) async throws -> URL {
        fatalError("stub: StreamingNemotronMultilingualAsrManager.downloadVariant")
    }
    public static func preloadShared(
        from folder: URL, configuration: MLModelConfiguration
    ) async throws -> SharedNemotronMultilingualModels {
        fatalError("stub: StreamingNemotronMultilingualAsrManager.preloadShared")
    }
    public func loadFromShared(_ shared: SharedNemotronMultilingualModels) async throws {
        fatalError("stub: loadFromShared")
    }
    public func setLanguage(_ hint: String) async { fatalError("stub: setLanguage") }
    public func setCustomVocabulary(_ terms: [CustomVocabularyTerm]) async { fatalError("stub: setCustomVocabulary") }
    public func setPartialCallback(_ callback: @escaping @Sendable (String) -> Void) async {
        fatalError("stub: setPartialCallback")
    }
    public func process(samples: [Float]) async throws -> String { fatalError("stub: process(samples:)") }
    public func finish() async throws -> String { fatalError("stub: finish") }
    public func reset() async { fatalError("stub: reset") }
    public func detectedLanguage() async -> String? { fatalError("stub: detectedLanguage") }
}

public actor StreamingEouAsrManager {
    public init(configuration: MLModelConfiguration, chunkSize: StreamingChunkSize) {}
    public func loadModels(from folder: URL) async throws { fatalError("stub: loadModels") }
    public func cleanup() async { fatalError("stub: cleanup") }
    public func reset() async { fatalError("stub: reset") }
    public func setPartialCallback(_ callback: @escaping @Sendable (String) -> Void) async {
        fatalError("stub: setPartialCallback")
    }
    public func process(audioBuffer: AVAudioPCMBuffer) async throws -> String {
        fatalError("stub: process(audioBuffer:)")
    }
    public func finish() async throws -> String { fatalError("stub: finish") }
}

public struct AsrModels: Sendable {
    public static func modelsExist(at folder: URL, version: AsrModelVersion) -> Bool {
        false  // trivial value: nothing is ever installed under the stub
    }
    public static func download(
        to folder: URL, version: AsrModelVersion, progressHandler: ProgressHandler?
    ) async throws {
        fatalError("stub: AsrModels.download")
    }
    public static func load(
        from folder: URL, configuration: MLModelConfiguration, version: AsrModelVersion
    ) async throws -> AsrModels {
        fatalError("stub: AsrModels.load")
    }
}

public struct ASRConfig: Sendable {
    public static let `default` = ASRConfig()
}

public enum ASRConstants {
    public static func minimumRequiredSamples(forSampleRate sampleRate: Int) -> Int {
        fatalError("stub: ASRConstants.minimumRequiredSamples")
    }
}

public struct TdtDecoderState: Sendable {
    public static func make(decoderLayers: Int) -> TdtDecoderState { fatalError("stub: TdtDecoderState.make") }
}

public struct TokenTiming: Sendable {
    public var token: String
    public var startTime: TimeInterval
    public var endTime: TimeInterval
}

public struct ASRResult: Sendable {
    public var text: String
    public var tokenTimings: [TokenTiming]?
}

public actor AsrManager {
    public init(config: ASRConfig, models: AsrModels) {}
    public var decoderLayerCount: Int { fatalError("stub: decoderLayerCount") }
    public func transcribe(_ samples: [Float], decoderState: inout TdtDecoderState) async throws -> ASRResult {
        fatalError("stub: AsrManager.transcribe")
    }
}

public final class TextNormalizer: Sendable {
    public static let shared = TextNormalizer()
    public func normalizeSentence(_ text: String) -> String { fatalError("stub: normalizeSentence") }
}
