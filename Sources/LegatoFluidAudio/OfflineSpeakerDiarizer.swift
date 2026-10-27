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
    /// The pipeline over a recording on disk, read as it goes (memory-mapped, converted to 16 kHz).
    func run(file: URL, hints: DiarizationHints) async throws -> DiarizationResult
    /// The same, reporting `(chunksProcessed, totalChunks)` as it goes.
    func run(file: URL, hints: DiarizationHints, progress: (@Sendable (Int, Int) -> Void)?) async throws -> DiarizationResult
}

extension OfflineDiarizationRunner {
    func run(file: URL, hints: DiarizationHints, progress: (@Sendable (Int, Int) -> Void)?) async throws -> DiarizationResult {
        try await run(file: file, hints: hints)
    }
}

/// Speaker labels for a finished recording, from FluidAudio's offline pipeline (segmentation, embeddings and
/// clustering over the whole audio). Cluster ids are the pipeline's own, `S1`, `S2`, …
public final class OfflineSpeakerDiarizer: BatchDiarizer {
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
        guard !samples.isEmpty else { return [] }
        do {
            return Self.turns(from: try await runner.run(audio: samples, hints: hints))
        } catch OfflineDiarizationError.noSpeechDetected {
            return []
        }
    }

    public func diarize(file: URL) async throws -> [SpeakerTurn] {
        try await diarize(file: file, progress: nil)
    }

    public func diarize(file: URL, progress: (@Sendable (Double) -> Void)?) async throws -> [SpeakerTurn] {
        do {
            var report: (@Sendable (Int, Int) -> Void)?
            if let progress {
                report = { @Sendable (done: Int, total: Int) -> Void in
                    if total > 0 { progress(min(1, Double(done) / Double(total))) }
                }
            }
            return Self.turns(from: try await runner.run(file: file, hints: hints, progress: report))
        } catch OfflineDiarizationError.noSpeechDetected {
            return []
        }
    }

    static func turns(from result: DiarizationResult) -> [SpeakerTurn] {
        result.segments
            .filter { $0.endTimeSeconds > $0.startTimeSeconds }
            .sorted { ($0.startTimeSeconds, $0.speakerId) < ($1.startTimeSeconds, $1.speakerId) }
            .map { SpeakerTurn(speaker: $0.speakerId, start: TimeInterval($0.startTimeSeconds), end: TimeInterval($0.endTimeSeconds)) }
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
        try await manager(hints).process(audio: audio)
    }

    func run(file: URL, hints: DiarizationHints) async throws -> DiarizationResult {
        try await run(file: file, hints: hints, progress: nil)
    }

    func run(file: URL, hints: DiarizationHints, progress: (@Sendable (Int, Int) -> Void)?) async throws -> DiarizationResult {
        try await manager(hints).process(file, progressCallback: progress)
    }

    private func manager(_ hints: DiarizationHints) async throws -> OfflineDiarizerManager {
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
        return manager
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
