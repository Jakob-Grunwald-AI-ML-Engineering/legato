// CAM++ feature normalization follows FluidAudio CampPlusEmbedder (Apache-2.0).
import Foundation
import CoreML
import CryptoKit

public enum VoiceIdentityError: LocalizedError, Sendable {
    case setupRequired, invalidEnrollment, invalidModel, corruptDownload
    public var errorDescription: String? {
        switch self {
        case .setupRequired: "Set up your voice in Settings, or turn Reduce background voices off before dictating."
        case .invalidEnrollment: "Too little speech was heard. Read the sentences aloud clearly, then try again."
        case .invalidModel: "The voice model could not run. Record your voice again in Settings, or turn Reduce background voices off."
        case .corruptDownload: "The voice model download failed verification. Try setup again."
        }
    }
}

public enum VoiceIsolationSettings {
    public static var enabled: Bool {
        get { UserDefaults.standard.bool(forKey: "voiceIsolation.enabled") }
        set { UserDefaults.standard.set(newValue, forKey: "voiceIsolation.enabled") }
    }
    /// Keep each setup and setting recording on this device for testing. Off: audio stays in memory and is discarded.
    public static var keepRecordings: Bool {
        get { UserDefaults.standard.bool(forKey: "voiceIsolation.keepRecordings") }
        set { UserDefaults.standard.set(newValue, forKey: "voiceIsolation.keepRecordings") }
    }
    /// Where the next setting recording starts in the sentence rotation (`VoiceReadingScript.setting`).
    public static var promptCursor: Int {
        get { UserDefaults.standard.integer(forKey: "voiceIsolation.promptCursor") }
        set { UserDefaults.standard.set(newValue, forKey: "voiceIsolation.promptCursor") }
    }
    /// A saved voice: the profile set, or a single profile saved before profile sets (migrated on first load).
    public static var hasProfile: Bool { VoiceIdentityService.hasStoredProfile(at: VoiceIdentityService.defaultRoot) }
}

/// Owns the user's voice: the pinned CAM++ model, the hidden profiles (one per setting and microphone route, in
/// `profiles.json`), kept test recordings and matching. Embeddings stay on this device; recording audio is saved only
/// while "Keep recordings for testing" is on, and is never uploaded.
public actor VoiceIdentityService {
    public static let shared = VoiceIdentityService()
    public static let modelRevision = "f316edbc70d9023a94aaf8965538aba4330dc28e"
    public static var defaultRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Legato/VoiceIdentity", isDirectory: true)
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "LegatoKit", isDirectory: true)
    }
    public static let profilesName = "profiles.json"
    static let legacyProfileName = "profile.json"
    public static func hasStoredProfile(at root: URL) -> Bool {
        FileManager.default.fileExists(atPath: root.appendingPathComponent(profilesName).path)
            || FileManager.default.fileExists(atPath: root.appendingPathComponent(legacyProfileName).path)
    }
    private struct Asset: Decodable { let path: String; let sha256: String }
    private let root: URL
    private var preprocessor: MLModel?
    private var model: MLModel?
    private var profiles: VoiceProfileSet?
    public init(root: URL = VoiceIdentityService.defaultRoot) { self.root = root }
    public var hasProfile: Bool { Self.hasStoredProfile(at: root) }
    public nonisolated var profilesURL: URL { root.appendingPathComponent(Self.profilesName) }
    public nonisolated var recordings: VoiceRecordingStore {
        VoiceRecordingStore(root: root.appendingPathComponent("Recordings", isDirectory: true))
    }

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

    // MARK: Profiles

    /// The saved voice; empty when there is none. A single profile from before profile sets becomes the Alone setting
    /// (route unknown) and is rewritten as `profiles.json`, so nobody has to record again.
    public func profileSet() throws -> VoiceProfileSet {
        if let profiles { return profiles }
        let loaded: VoiceProfileSet
        if let data = try? Data(contentsOf: profilesURL) {
            loaded = try VoiceJSON.decoder.decode(VoiceProfileSet.self, from: data)
        } else if let data = try? Data(contentsOf: root.appendingPathComponent(Self.legacyProfileName)),
                  let migrated = VoiceProfileSet.migrating(legacy: data, date: Self.creationDate(root.appendingPathComponent(Self.legacyProfileName))) {
            try save(migrated)
            try? FileManager.default.removeItem(at: root.appendingPathComponent(Self.legacyProfileName))
            loaded = migrated
        } else { loaded = VoiceProfileSet() }
        profiles = loaded
        return loaded
    }
    private static func creationDate(_ url: URL) -> Date {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.creationDate] as? Date) ?? Date()
    }
    private func save(_ set: VoiceProfileSet) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Task.checkCancellation()
        try VoiceJSON.encoder.encode(set).write(to: profilesURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: profilesURL.path)
        profiles = set
    }

    /// Saves the voice of `situation` on `route` from the reading parts of one recording (the quiet pauses are not
    /// passed in). The same setting on the same route replaces its profile; another route adds one.
    /// `keeping` is the whole recording for "Keep recordings for testing": it is kept only when its profile is
    /// saved, so a rejected, failed or cancelled recording leaves nothing behind.
    @discardableResult
    public func enroll(reading segments: [[Float]], situation: VoiceSituation, route: VoiceInputRoute,
                       keeping recording: (samples: [Float], sidecar: VoiceRecordingSidecar)? = nil,
                       date: Date = Date()) throws -> VoiceProfile {
        try save(embedding: readingEmbedding(segments), situation: situation, route: route, keeping: recording, date: date)
    }
    /// The voice of one recording's reading parts, not saved yet. Throws ``VoiceIdentityError/invalidEnrollment`` for
    /// too little speech.
    public func readingEmbedding(_ segments: [[Float]]) throws -> [Float] {
        let total = segments.reduce(0) { $0 + $1.count }
        let energy = segments.reduce(Float(0)) { sum, segment in segment.reduce(sum) { $0 + $1 * $1 } } / Float(max(1, total))
        guard total >= 8 * 16000, segments.allSatisfy({ $0.allSatisfy(\.isFinite) }), energy > 0.00001 else { throw VoiceIdentityError.invalidEnrollment }
        try Task.checkCancellation()
        try loadModels()
        let embedding = try profileEmbedding(segments)
        try Task.checkCancellation()
        return embedding
    }
    /// Saves a ``readingEmbedding(_:)`` as the profile of `situation` on `route`, as ``enroll(reading:situation:route:keeping:date:)`` does.
    @discardableResult
    public func save(embedding: [Float], situation: VoiceSituation, route: VoiceInputRoute,
                     keeping recording: (samples: [Float], sidecar: VoiceRecordingSidecar)? = nil,
                     date: Date = Date()) throws -> VoiceProfile {
        try Task.checkCancellation()
        let profile = VoiceProfile(situationID: situation.id, situationName: situation.name, route: route, embedding: embedding,
                                   date: date, revision: Self.modelRevision, recordingID: recording?.sidecar.id)
        var set = try profileSet()
        set.upsert(profile)
        let kept = try recording.map { try recordings.save(samples: $0.samples, sidecar: $0.sidecar) }
        do { try save(set) } catch {
            if let kept { try? FileManager.default.removeItem(at: kept) }
            throw error
        }
        return profile
    }
    /// One quiet-room recording as the Alone setting, route unknown (the pre-setup entry point).
    public func enroll(samples: [Float]) async throws {
        try enroll(reading: [samples], situation: .alone, route: .unknown)
    }
    @discardableResult
    public func addSituation(named name: String) throws -> VoiceSituation? {
        var set = try profileSet()
        guard let situation = set.addSituation(named: name) else { return nil }
        try save(set)
        return situation
    }
    public func deleteSituation(id: String) throws {
        var set = try profileSet()
        set.removeSituation(id: id)
        try save(set)
    }
    /// "Delete voice": every profile, the user's own settings and every kept recording. Turns the option off.
    public func deleteProfile() async throws {
        for name in [Self.profilesName, Self.legacyProfileName] {
            let url = root.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        }
        try recordings.deleteAll()
        profiles = nil; VoiceIsolationSettings.enabled = false
    }

    // MARK: Matching

    public func requireReady() throws {
        try loadModels()
        profiles = nil
        guard !(try profileSet()).matchable(revision: Self.modelRevision).isEmpty else { throw VoiceIdentityError.setupRequired }
    }
    /// Each stream freezes the profiles it started with, so a new recording takes effect on the next take.
    /// The score is the best cosine over all profiles.
    public func makeMatcher() throws -> @Sendable ([Float]) async throws -> Float {
        try requireReady()
        return try matcher(for: profileSet())
    }
    /// The production matcher over an explicit profile set (the Mac replay tool passes the exported one).
    public func matcher(for set: VoiceProfileSet) throws -> @Sendable ([Float]) async throws -> Float {
        let embeddings = set.matchable(revision: Self.modelRevision)
        guard !embeddings.isEmpty else { throw VoiceIdentityError.setupRequired }
        return { samples in try await self.bestScore(samples: samples, against: embeddings) }
    }
    /// The best match of `samples` against the saved voice ("is this me").
    public func similarity(samples: [Float]) throws -> Float {
        let embeddings = try profileSet().matchable(revision: Self.modelRevision)
        guard !embeddings.isEmpty else { throw VoiceIdentityError.setupRequired }
        return try bestScore(samples: samples, against: embeddings)
    }
    /// The normalized CAM++ embedding of 16 kHz mono samples (at least 0.35 s). Needs `prepareModels()` first,
    /// not a profile. Callers that compare voices keep the vectors in memory only.
    public func embedding(samples: [Float]) throws -> [Float] {
        if preprocessor == nil || model == nil { try loadModels() }
        return try embed(samples)
    }
    private func bestScore(samples: [Float], against embeddings: [[Float]]) throws -> Float {
        if preprocessor == nil || model == nil { try loadModels() }
        let vector = try embed(samples)
        guard let score = VoiceProfileSet.bestScore(vector, among: embeddings) else { throw VoiceIdentityError.invalidModel }
        return score
    }
    /// The mean of ten-second window embeddings over all reading parts, normalized: long recordings stay within the
    /// window length the model was measured on (spike #242), and every part counts by its length.
    private func profileEmbedding(_ segments: [[Float]]) throws -> [Float] {
        let window = 10 * 16000, minimum = 3 * 16000
        var sum: [Float] = [], weight: Float = 0
        for segment in segments {
            var start = 0
            while start < segment.count {
                var end = min(segment.count, start + window)
                // A short tail joins the window before it instead of being embedded alone.
                if segment.count - end < minimum { end = segment.count }
                let piece = Array(segment[start..<end])
                start = end
                guard piece.count >= minimum || (segment.count < minimum && piece.count >= 5600) else { continue }
                let vector = try embed(piece), w = Float(piece.count)
                if sum.isEmpty { sum = [Float](repeating: 0, count: vector.count) }
                guard vector.count == sum.count else { throw VoiceIdentityError.invalidModel }
                for i in vector.indices { sum[i] += vector[i] * w }
                weight += w
            }
        }
        guard weight > 0 else { throw VoiceIdentityError.invalidEnrollment }
        let norm = sqrt(sum.reduce(Float(0)) { $0 + $1 * $1 })
        guard norm.isFinite, norm > 0 else { throw VoiceIdentityError.invalidModel }
        return sum.map { $0 / norm }
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
