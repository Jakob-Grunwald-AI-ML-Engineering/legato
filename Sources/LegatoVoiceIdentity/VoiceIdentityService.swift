// CAM++ feature normalization follows FluidAudio CampPlusEmbedder (Apache-2.0).
import Foundation
import CoreML
import CryptoKit

public enum VoiceIdentityError: LocalizedError, Sendable {
    case setupRequired, invalidEnrollment, invalidModel, corruptDownload
    public var errorDescription: String? {
        switch self {
        case .setupRequired: "Set up Only My Voice in Settings, or turn it off before dictating."
        case .invalidEnrollment: "Record at least eight seconds of clear speech to create your voice profile."
        case .invalidModel: "The voice model could not run. Replace your voice profile in Settings, or turn Only My Voice off."
        case .corruptDownload: "The voice model download failed verification. Try setup again."
        }
    }
}

public enum VoiceIsolationSettings {
    public static var enabled: Bool {
        get { UserDefaults.standard.bool(forKey: "voiceIsolation.enabled") }
        set { UserDefaults.standard.set(newValue, forKey: "voiceIsolation.enabled") }
    }
    public static var hasProfile: Bool { FileManager.default.fileExists(atPath: VoiceIdentityService.defaultRoot.appendingPathComponent("profile.json").path) }
}

/// Embeddings stay on this device; enrollment audio is never persisted or uploaded.
public actor VoiceIdentityService {
    public static let shared = VoiceIdentityService()
    public static let modelRevision = "f316edbc70d9023a94aaf8965538aba4330dc28e"
    public static var defaultRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Legato/VoiceIdentity", isDirectory: true)
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "LegatoKit", isDirectory: true)
    }
    private struct Profile: Codable { let revision: String; let embedding: [Float] }
    private struct Asset: Decodable { let path: String; let sha256: String }
    private let root: URL
    private var preprocessor: MLModel?
    private var model: MLModel?
    private var profile: [Float]?
    public init(root: URL = VoiceIdentityService.defaultRoot) { self.root = root }
    public var hasProfile: Bool { FileManager.default.fileExists(atPath: root.appendingPathComponent("profile.json").path) }

    /// Explicit setup only. Pinned files are hash checked before use. No download on ordinary dictation.
    public func prepareModels() async throws {
        let manifest = try JSONDecoder().decode([Asset].self, from: Data(contentsOf: Bundle.module.url(forResource: "ModelAssets", withExtension: "json")!))
        for asset in manifest {
            try Task.checkCancellation()
            let destination = root.appendingPathComponent(asset.path)
            if let existing = try? Data(contentsOf: destination), Self.digest(existing) == asset.sha256 { continue }
            let url = URL(string: "https://huggingface.co/FluidInference/campplus-coreml/resolve/\(Self.modelRevision)/\(asset.path)")!
            let (data, response) = try await URLSession.shared.data(from: url)
            guard (response as? HTTPURLResponse)?.statusCode == 200, Self.digest(data) == asset.sha256 else { throw VoiceIdentityError.corruptDownload }
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: destination, options: .atomic)
        }
        try loadModels()
    }
    private static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private func loadModels() throws {
        if preprocessor != nil, model != nil { return }
        let configuration = MLModelConfiguration(); configuration.computeUnits = .cpuOnly
        do {
            preprocessor = try MLModel(contentsOf: root.appendingPathComponent("CamPlusPreprocessor_v2.mlmodelc"), configuration: configuration)
            model = try MLModel(contentsOf: root.appendingPathComponent("CamPlusPlus_v2.mlmodelc"), configuration: configuration)
        } catch { throw VoiceIdentityError.setupRequired }
    }
    public func enroll(samples: [Float]) async throws {
        guard samples.count >= 8 * 16000, samples.count <= 60 * 16000,
              samples.allSatisfy(\.isFinite), samples.reduce(Float(0), { $0 + $1 * $1 }) / Float(samples.count) > 0.00001 else { throw VoiceIdentityError.invalidEnrollment }
        try Task.checkCancellation()
        try loadModels()
        let embedding = try embed(samples)
        try Task.checkCancellation()
        let data = try JSONEncoder().encode(Profile(revision: Self.modelRevision, embedding: embedding))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let destination = root.appendingPathComponent("profile.json")
        try Task.checkCancellation()
        try data.write(to: destination, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        profile = embedding
    }
    public func deleteProfile() async throws {
        let destination = root.appendingPathComponent("profile.json")
        if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
        profile = nil; VoiceIsolationSettings.enabled = false
    }
    public func requireReady() throws {
        try loadModels()
        let stored = try? JSONDecoder().decode(Profile.self, from: Data(contentsOf: root.appendingPathComponent("profile.json")))
        guard let stored, stored.revision == Self.modelRevision, stored.embedding.count == 192,
              stored.embedding.allSatisfy(\.isFinite) else { throw VoiceIdentityError.setupRequired }
        profile = stored.embedding
    }
    /// Each stream freezes enrollment identity, so profile replacement takes effect on its next take.
    public func makeMatcher() throws -> @Sendable ([Float]) async throws -> Float {
        try requireReady()
        guard let profile else { throw VoiceIdentityError.setupRequired }
        return { samples in try await self.similarity(samples: samples, against: profile) }
    }
    public func similarity(samples: [Float]) throws -> Float {
        guard let profile else { throw VoiceIdentityError.setupRequired }
        return try similarity(samples: samples, against: profile)
    }
    private func similarity(samples: [Float], against profile: [Float]) throws -> Float {
        let vector = try embed(samples)
        guard vector.count == profile.count else { throw VoiceIdentityError.invalidModel }
        return zip(profile, vector).reduce(0) { $0 + $1.0 * $1.1 }
    }
    private func embed(_ samples: [Float]) throws -> [Float] {
        guard let preprocessor, let model, samples.count >= 5600 else { throw VoiceIdentityError.invalidModel }
        let wave = try MLMultiArray(shape: [1, NSNumber(value: samples.count)], dataType: .float32)
        let pointer = wave.dataPointer.assumingMemoryBound(to: Float.self)
        for i in samples.indices { pointer[i] = samples[i] * 32768 }
        let result = try preprocessor.prediction(from: MLDictionaryFeatureProvider(dictionary: ["waveform": MLFeatureValue(multiArray: wave)]))
        guard let features = result.featureValue(for: "features")?.multiArrayValue, features.shape.count == 3 else { throw VoiceIdentityError.invalidModel }
        let frames = features.shape[1].intValue, bands = features.shape[2].intValue
        guard frames > 0 else { throw VoiceIdentityError.invalidModel }
        for band in 0..<bands {
            var mean = 0.0
            for frame in 0..<frames { mean += features[[0, NSNumber(value: frame), NSNumber(value: band)]].doubleValue }
            mean /= Double(frames)
            for frame in 0..<frames {
                let index = [NSNumber(value: 0), NSNumber(value: frame), NSNumber(value: band)]
                features[index] = NSNumber(value: features[index].doubleValue - mean)
            }
        }
        let resultVector = try model.prediction(from: MLDictionaryFeatureProvider(dictionary: ["feats": MLFeatureValue(multiArray: features)]))
        guard let array = resultVector.featureValue(for: "embedding")?.multiArrayValue else { throw VoiceIdentityError.invalidModel }
        let vector = (0..<array.count).map { array[$0].floatValue }
        let norm = sqrt(vector.reduce(Float(0)) { $0 + $1 * $1 })
        guard norm.isFinite, norm > 0 else { throw VoiceIdentityError.invalidModel }
        return vector.map { $0 / norm }
    }
}
