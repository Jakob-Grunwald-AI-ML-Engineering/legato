import FluidAudio
import Foundation
import LegatoCore
import LegatoModels

/// How many speakers the after-meeting diarizer should expect. All nil: let the model decide.
public struct DiarizationHints: Sendable, Equatable {
    public var numSpeakers: Int?
    public var minSpeakers: Int?
    public var maxSpeakers: Int?

    public init(numSpeakers: Int? = nil, minSpeakers: Int? = nil, maxSpeakers: Int? = nil) {
        self.numSpeakers = numSpeakers
        self.minSpeakers = minSpeakers
        self.maxSpeakers = maxSpeakers
    }
}

/// Runs the offline diarization pipeline over 16 kHz mono audio.
protocol OfflineDiarizationRunner: Sendable {
    func run(audio: [Float], hints: DiarizationHints) async throws -> DiarizationResult
}

/// Matches the user's enrolled voice to a diarizer cluster by cosine similarity of speaker embeddings.
enum EnrollmentMatcher {
    /// The least cosine similarity that counts as the same voice.
    static let threshold: Float = 0.7

    static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        guard !a.isEmpty, a.count == b.count else { return 0 }
        var dot: Float = 0, normA: Float = 0, normB: Float = 0
        for index in a.indices {
            dot += a[index] * b[index]
            normA += a[index] * a[index]
            normB += b[index] * b[index]
        }
        let norm = (normA * normB).squareRoot()
        return norm > 0 ? dot / norm : 0
    }

    /// The cluster closest to `enrollment` at or above ``threshold``; ties go to the smaller id.
    static func bestMatch(enrollment: [Float], clusters: [String: [Float]], threshold: Float = threshold) -> String? {
        var best: (id: String, score: Float)?
        for id in clusters.keys.sorted() {
            let score = cosine(enrollment, clusters[id] ?? [])
            guard score >= threshold else { continue }
            if best == nil || score > best!.score { best = (id, score) }
        }
        return best?.id
    }
}

/// Speaker labels for a finished recording, from FluidAudio's offline pipeline (segmentation, embeddings and
/// clustering over the whole audio). Cluster ids are the pipeline's own, `S1`, `S2`, …
///
/// With the user's enrolment sample it also finds which cluster is the user: the sample goes through the same
/// pipeline, and the cluster whose embedding is closest to the sample's main speaker, at cosine 0.7 or more, is "You".
public final class OfflineSpeakerDiarizer: EnrollmentBatchDiarizer {
    private let runner: any OfflineDiarizationRunner
    private let hints: DiarizationHints

    /// A diarizer over the model installed as `modelID` in `models`.
    public init(models: ModelManager, modelID: String = FluidAudioModels.diarizerOfflineID, hints: DiarizationHints = DiarizationHints()) {
        self.runner = FluidOfflineRunner(models: models, modelID: modelID)
        self.hints = hints
    }

    init(runner: any OfflineDiarizationRunner, hints: DiarizationHints = DiarizationHints()) {
        self.runner = runner
        self.hints = hints
    }

    public func diarize(samples: [Float]) async throws -> [SpeakerTurn] {
        try await diarize(samples: samples, enrollment: nil).turns
    }

    public func diarize(samples: [Float], enrollment: [Float]?) async throws -> BatchDiarization {
        guard !samples.isEmpty else { return BatchDiarization(turns: []) }
        let result: DiarizationResult
        do {
            result = try await runner.run(audio: samples, hints: hints)
        } catch OfflineDiarizationError.noSpeechDetected {
            return BatchDiarization(turns: [])
        }
        let turns = Self.turns(from: result)
        guard let enrollment, !enrollment.isEmpty, !turns.isEmpty else { return BatchDiarization(turns: turns) }
        let you = await match(enrollment: enrollment, in: result)
        return BatchDiarization(turns: turns, youCluster: you)
    }

    /// Runs the enrolment sample (one speaker) through the pipeline and finds its voice among the clusters.
    private func match(enrollment: [Float], in result: DiarizationResult) async -> String? {
        let clusters = Self.clusterEmbeddings(result)
        guard !clusters.isEmpty else { return nil }
        // A sample that yields no voice (too short, silent) is no match, not a failed meeting.
        guard let sample = try? await runner.run(audio: enrollment, hints: DiarizationHints(numSpeakers: 1)),
            let main = Self.mainSpeakerEmbedding(sample)
        else { return nil }
        return EnrollmentMatcher.bestMatch(enrollment: main, clusters: clusters)
    }

    static func turns(from result: DiarizationResult) -> [SpeakerTurn] {
        result.segments
            .filter { $0.endTimeSeconds > $0.startTimeSeconds }
            .sorted { ($0.startTimeSeconds, $0.speakerId) < ($1.startTimeSeconds, $1.speakerId) }
            .map { SpeakerTurn(speaker: $0.speakerId, start: TimeInterval($0.startTimeSeconds), end: TimeInterval($0.endTimeSeconds)) }
    }

    /// One embedding per cluster: the pipeline's speaker database, else the mean of the cluster's segment embeddings.
    private static func clusterEmbeddings(_ result: DiarizationResult) -> [String: [Float]] {
        if let database = result.speakerDatabase, !database.isEmpty { return database }
        return Dictionary(grouping: result.segments, by: \.speakerId).compactMapValues { mean(of: $0.map(\.embedding)) }
    }

    /// The embedding of whoever speaks most in the sample.
    private static func mainSpeakerEmbedding(_ result: DiarizationResult) -> [Float]? {
        let speech = Dictionary(grouping: result.segments, by: \.speakerId).mapValues { $0.reduce(0) { $0 + $1.durationSeconds } }
        guard let main = speech.max(by: { ($0.value, $1.key) < ($1.value, $0.key) })?.key else { return nil }
        return clusterEmbeddings(result)[main]
    }

    private static func mean(of vectors: [[Float]]) -> [Float]? {
        guard let first = vectors.first, vectors.allSatisfy({ $0.count == first.count }) else { return nil }
        var sum = [Float](repeating: 0, count: first.count)
        for vector in vectors { for index in vector.indices { sum[index] += vector[index] } }
        return sum.map { $0 / Float(vectors.count) }
    }
}

/// The real pipeline: loads the three models once, on first use, and builds a manager per run so the
/// speaker-count hints apply. Dropping the diarizer frees the models.
private final class FluidOfflineRunner: OfflineDiarizationRunner {
    private let models: ModelManager
    private let modelID: String
    private let loaded = LoadedModels()

    init(models: ModelManager, modelID: String) {
        self.models = models
        self.modelID = modelID
    }

    func run(audio: [Float], hints: DiarizationHints) async throws -> DiarizationResult {
        let loadedModels = try await loaded.get { [models, modelID] in
            try await EngineSupport.requireInstalled(models: models, id: modelID)
            FluidAudioModels.pinRevisions()
            return try await OfflineDiarizerModels.load(from: models.root, configuration: FluidAudioCompute.configuration())
        }
        var config = OfflineDiarizerConfig.default
        config.clustering.numSpeakers = hints.numSpeakers
        config.clustering.minSpeakers = hints.minSpeakers
        config.clustering.maxSpeakers = hints.maxSpeakers
        let manager = OfflineDiarizerManager(config: config)
        manager.initialize(models: loadedModels)
        return try await manager.process(audio: audio)
    }

    private actor LoadedModels {
        private var task: Task<OfflineDiarizerModels, any Error>?

        func get(_ load: @escaping @Sendable () async throws -> OfflineDiarizerModels) async throws -> OfflineDiarizerModels {
            if let task { return try await task.value }
            let started = Task { try await load() }
            task = started
            do {
                return try await started.value
            } catch {
                task = nil
                throw error
            }
        }
    }
}
