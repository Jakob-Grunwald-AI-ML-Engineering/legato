// Weights: pyannote/segmentation-3.0 (MIT License, Copyright (c) 2023 CNRS; upstream revision e66f3d3b), as the Core ML
// conversion `pyannote_segmentation.mlmodelc` by Fluid Inference in huggingface.co/FluidInference/speaker-diarization-coreml.
// That repository is mixed-licence: its NOTICE.md puts only the Community-1 artefacts (Segmentation, FBank, Embedding,
// PLDA) under CC-BY-4.0 and lists this legacy file under its upstream MIT licence. The MIT notice:
//
//   Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated
//   documentation files (the "Software"), to deal in the Software without restriction, including without limitation the
//   rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit
//   persons to whom the Software is furnished to do so, subject to the following conditions: The above copyright notice
//   and this permission notice shall be included in all copies or substantial portions of the Software.
//   THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND.
import CoreML
import CryptoKit
import Foundation

public enum SpeakerSegmentationError: LocalizedError, Sendable, Equatable {
    case corruptDownload(String)
    case invalidModel

    public var errorDescription: String? {
        switch self {
        case .corruptDownload(let path): "The speaker model download failed verification (\(path))."
        case .invalidModel: "The speaker model could not run."
        }
    }
}

/// pyannote segmentation-3.0 as Core ML: for 10 s of 16 kHz mono audio, which of up to three local speakers talk in each
/// of 589 frames (~17 ms), overlap included (powerset classes: nobody, one of three, or two of them).
///
/// The weights are downloaded from a pinned Hugging Face revision when first needed, checked against SHA-256 hashes, and
/// cached under Application Support; nothing is downloaded again while the cached files match.
public actor SpeakerSegmentationModel {
    public static let repository = "FluidInference/speaker-diarization-coreml"
    public static let revision = "7eab74f3463c736418d0eb10296261ae581146c9"
    static let modelName = "pyannote_segmentation.mlmodelc"
    /// Every file of the compiled model and its SHA-256 (the Hugging Face LFS ids at `revision`, checked on download).
    static let assets: [(path: String, sha256: String)] = [
        ("analytics/coremldata.bin", "b379db0541b35344a34bb7540783ae704c11599bbed5aa8bbbda11c20ad215ee"),
        ("coremldata.bin", "4a450ea1b053b9eb7eef0cab6971018076600840c7e246d064e7c5387f456c98"),
        ("metadata.json", "44e1fa36d6abafacf688beccad99f7569394248d8bb41545829997c67668c08c"),
        ("model.mil", "97f2dec6f83e80bf4247b98e13c2dde19f92c05820ef08068bbf554488d70bdd"),
        ("weights/weight.bin", "0266f4ad4d843ecf31ef9220ad6b80616b3ec64a4404b64f3ea0371554e236ec"),
    ]

    public static let sampleRate: Double = 16_000
    public static let windowSamples = 160_000
    public static var windowSeconds: TimeInterval { Double(windowSamples) / sampleRate }
    public static let frameCount = 589
    /// SincNet's hop and receptive field, seconds: frame `i` covers `i * frameStep ..< i * frameStep + frameDuration`.
    public static let frameStep: TimeInterval = 270 / 16_000
    public static let frameDuration: TimeInterval = 991 / 16_000
    /// The local speakers of each powerset class, in pyannote's order.
    public static let powerset: [[Int]] = [[], [0], [1], [2], [0, 1], [0, 2], [1, 2]]

    public static var defaultRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Legato/Models/pyannote-segmentation-3.0", isDirectory: true)
    }

    private let root: URL
    private var model: MLModel?

    public init(root: URL = SpeakerSegmentationModel.defaultRoot) { self.root = root }

    private var modelURL: URL {
        root.appendingPathComponent(Self.revision, isDirectory: true).appendingPathComponent(Self.modelName, isDirectory: true)
    }

    /// Downloads what is missing or does not match, then loads the model.
    public func prepare() async throws {
        if model != nil { return }
        for asset in Self.assets {
            try Task.checkCancellation()
            let destination = modelURL.appendingPathComponent(asset.path)
            if let existing = try? Data(contentsOf: destination), Self.digest(existing) == asset.sha256 { continue }
            let url = URL(string: "https://huggingface.co/\(Self.repository)/resolve/\(Self.revision)/\(Self.modelName)/\(asset.path)")!
            let (data, response) = try await URLSession.shared.data(from: url)
            guard (response as? HTTPURLResponse)?.statusCode == 200, Self.digest(data) == asset.sha256 else {
                throw SpeakerSegmentationError.corruptDownload(asset.path)
            }
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: destination, options: .atomic)
        }
        let configuration = MLModelConfiguration()
        // No GPU: an app in the background may not use it.
        configuration.computeUnits = .cpuAndNeuralEngine
        do { model = try MLModel(contentsOf: modelURL, configuration: configuration) } catch { throw SpeakerSegmentationError.invalidModel }
    }

    /// The powerset class (an index into ``powerset``) of each frame of a 10 s window; shorter input is padded with silence.
    public func classes(of window: [Float]) throws -> [UInt8] {
        guard let model else { throw SpeakerSegmentationError.invalidModel }
        let input = try MLMultiArray(shape: [1, 1, NSNumber(value: Self.windowSamples)], dataType: .float32)
        let pointer = input.dataPointer.assumingMemoryBound(to: Float.self)
        let count = min(window.count, Self.windowSamples)
        window.withUnsafeBufferPointer { pointer.update(from: $0.baseAddress!, count: count) }
        if count < Self.windowSamples { (pointer + count).initialize(repeating: 0, count: Self.windowSamples - count) }
        let result = try model.prediction(from: MLDictionaryFeatureProvider(dictionary: ["audio": MLFeatureValue(multiArray: input)]))
        guard let output = result.featureValue(for: "segments")?.multiArrayValue, output.shape.count == 3,
            output.shape[2].intValue == Self.powerset.count
        else { throw SpeakerSegmentationError.invalidModel }
        let frames = output.shape[1].intValue
        let (frameStride, classStride) = (output.strides[1].intValue, output.strides[2].intValue)
        var classes = [UInt8](repeating: 0, count: frames)
        // Log-probabilities (or logits): the largest is the class, either way.
        switch output.dataType {
        case .float32:
            let values = output.dataPointer.assumingMemoryBound(to: Float.self)
            for f in 0..<frames {
                var best = 0
                for c in 1..<Self.powerset.count where values[f * frameStride + c * classStride] > values[f * frameStride + best * classStride] { best = c }
                classes[f] = UInt8(best)
            }
        default:
            for f in 0..<frames {
                var best = 0, bestValue = -Double.infinity
                for c in 0..<Self.powerset.count {
                    let value = output[[0, NSNumber(value: f), NSNumber(value: c)]].doubleValue
                    if value > bestValue { (best, bestValue) = (c, value) }
                }
                classes[f] = UInt8(best)
            }
        }
        return classes
    }

    private static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}
