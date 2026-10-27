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
    case sortformer, diarizer, localVqe
    // Plain data (no behaviour): the tests stage files and check pins against these.
    public var folderName: String {
        switch self {
        case .nemotronMultilingual: "nemotron-multilingual"
        case .parakeetV3: "parakeet-tdt-0.6b-v3"
        case .parakeetUltra: "parakeet-ultra"
        case .parakeetEou160: "parakeet-eou-streaming/160ms"
        case .parakeetEou320: "parakeet-eou-streaming/320ms"
        case .sortformer: "sortformer"
        case .diarizer: "speaker-diarization"
        case .localVqe: "localvqe"
        }
    }
    public var remotePath: String {
        switch self {
        case .nemotronMultilingual: "FluidInference/Nemotron-3.5-ASR-Streaming-Multilingual-0.6b-CoreML"
        case .parakeetV3: "FluidInference/parakeet-tdt-0.6b-v3-coreml"
        case .parakeetUltra: "FluidInference/parakeet-ultra-coreml"
        case .parakeetEou160: "FluidInference/parakeet-realtime-eou-120m-coreml"
        case .parakeetEou320: "FluidInference/parakeet-realtime-eou-120m-coreml"
        case .sortformer: "FluidInference/diar-streaming-sortformer-coreml"
        case .diarizer: "FluidInference/speaker-diarization-coreml"
        case .localVqe: "FluidInference/localvqe-coreml"
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
    public enum OfflineDiarizer {
        public static let requiredModels: Set<String> = [
            "Segmentation.mlmodelc", "FBank.mlmodelc", "Embedding.mlmodelc", "PldaRho.mlmodelc", "plda-parameters.json",
        ]
    }
    public enum Sortformer {
        public enum ModelPrecision: String, Sendable, CaseIterable {
            case fp16, palettized
            public var subdirectory: String {
                switch self {
                case .fp16: "v3/fp16"
                case .palettized: "v3/palettized"
                }
            }
        }
        public static var defaultBundle: String { "v3/fp16/Sortformer_v2.1.mlmodelc" }
        public static func bundle(for config: SortformerConfig) -> String? {
            "\(config.precision.subdirectory)/Sortformer_v2.1.mlmodelc"
        }
    }
    public enum LocalVQE {
        public static func modelFile(variant: LocalVqeVariant, chunk: LocalVqeChunk) -> String {
            "localvqe-\(variant.rawValue)-\(variant == .v13 ? "4.8M" : "1.3M")-\(chunk.rawValue).mlmodelc"
        }
        public static func variantKey(variant: LocalVqeVariant, chunk: LocalVqeChunk) -> String {
            "\(variant.rawValue)-\(chunk.rawValue)"
        }
    }
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
        _ repo: Repo, to directory: URL, variant: String? = nil, additionalModelNames: Set<String> = [],
        progressHandler: ProgressHandler? = nil
    ) async throws {
        fatalError("stub: ModelHub.download")
    }
}

public struct SharedNemotronMultilingualModels: Sendable {}

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

// MARK: Diarization and enhancement

public struct TimedSpeakerSegment: Sendable {
    public let speakerId: String
    public let embedding: [Float]
    public let startTimeSeconds: Float
    public let endTimeSeconds: Float
    public let qualityScore: Float
    public init(speakerId: String, embedding: [Float], startTimeSeconds: Float, endTimeSeconds: Float, qualityScore: Float) {
        self.speakerId = speakerId
        self.embedding = embedding
        self.startTimeSeconds = startTimeSeconds
        self.endTimeSeconds = endTimeSeconds
        self.qualityScore = qualityScore
    }
}

public struct DiarizationResult: Sendable {
    public let segments: [TimedSpeakerSegment]
    public let speakerDatabase: [String: [Float]]?
    public init(segments: [TimedSpeakerSegment], speakerDatabase: [String: [Float]]? = nil) {
        self.segments = segments
        self.speakerDatabase = speakerDatabase
    }
}

public enum OfflineDiarizationError: Error {
    case noSpeechDetected
}

public struct OfflineDiarizerModels: Sendable {
    public static func load(from directory: URL, configuration: MLModelConfiguration) async throws -> OfflineDiarizerModels {
        fatalError("stub: OfflineDiarizerModels.load")
    }
}

public struct OfflineDiarizerConfig: Sendable {
    public struct Clustering: Sendable {
        public var numSpeakers: Int?
        public var minSpeakers: Int?
        public var maxSpeakers: Int?
    }
    public var clustering: Clustering
    public static var `default`: OfflineDiarizerConfig { fatalError("stub: OfflineDiarizerConfig.default") }
}

public final class OfflineDiarizerManager {
    public init(config: OfflineDiarizerConfig = .default) {}
    public func initialize(models: OfflineDiarizerModels) { fatalError("stub: OfflineDiarizerManager.initialize") }
    public func process(audio: [Float]) async throws -> DiarizationResult {
        fatalError("stub: OfflineDiarizerManager.process")
    }
}

public struct SortformerConfig: Sendable {
    public var precision: ModelNames.Sortformer.ModelPrecision
    public init(precision: ModelNames.Sortformer.ModelPrecision = .fp16) { self.precision = precision }
}

public struct SortformerModels {
    public static func loadFromHuggingFace(
        config: SortformerConfig, cacheDirectory: URL? = nil, computeUnits: MLComputeUnits? = nil,
        progressHandler: ProgressHandler? = nil
    ) async throws -> SortformerModels {
        fatalError("stub: SortformerModels.loadFromHuggingFace")
    }
}

public struct DiarizerSegment: Sendable {
    public var startTime: Float
    public var endTime: Float
}

public class DiarizerSpeaker {
    public var index: Int
    public var finalizedSegments: [DiarizerSegment]
    public var tentativeSegments: [DiarizerSegment]
    init() { fatalError("stub: DiarizerSpeaker") }
}

public class DiarizerTimeline {
    public var speakers: [Int: DiarizerSpeaker] { fatalError("stub: DiarizerTimeline.speakers") }
}

public struct DiarizerTimelineUpdate: Sendable {}

public final class SortformerDiarizer {
    public init(config: SortformerConfig) {}
    public var timeline: DiarizerTimeline { fatalError("stub: SortformerDiarizer.timeline") }
    public func initialize(models: SortformerModels) { fatalError("stub: SortformerDiarizer.initialize") }
    @discardableResult
    public func process(samples: [Float]) throws -> DiarizerTimelineUpdate? { fatalError("stub: SortformerDiarizer.process") }
    @discardableResult
    public func finalizeSession() throws -> DiarizerTimelineUpdate? { fatalError("stub: SortformerDiarizer.finalizeSession") }
}

public enum LocalVqeVariant: String, CaseIterable, Sendable { case v13 = "v1.3", v12 = "v1.2" }
public enum LocalVqeChunk: String, CaseIterable, Sendable { case realtime16ms = "16ms", batch256ms = "256ms" }

public struct LocalVqeConfig: Sendable {
    public var variant: LocalVqeVariant
    public var chunk: LocalVqeChunk
    public init(variant: LocalVqeVariant = .v13, chunk: LocalVqeChunk = .batch256ms, computeUnits: MLComputeUnits = .cpuOnly) {
        self.variant = variant
        self.chunk = chunk
    }
}

public actor LocalVqeStream {
    public func enhance(mic: [Float], reference: [Float]) async throws -> [Float] { fatalError("stub: LocalVqeStream.enhance") }
    public func flush() async throws -> [Float] { fatalError("stub: LocalVqeStream.flush") }
}

public actor LocalVqeManager {
    public init(config: LocalVqeConfig = LocalVqeConfig(), modelDirectory: URL) throws { fatalError("stub: LocalVqeManager.init") }
    public func makeStream() throws -> LocalVqeStream { fatalError("stub: LocalVqeManager.makeStream") }
}
