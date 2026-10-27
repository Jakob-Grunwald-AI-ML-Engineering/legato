import FluidAudio
import Foundation
import LegatoCore
import LegatoModels

/// One stretch of one Sortformer speaker slot, as the model reports it.
struct SortformerSlotSegment: Sendable, Equatable {
    var slot: Int
    var start: TimeInterval
    var end: TimeInterval
}

/// The Sortformer model as the diarizer drives it. The real one wraps FluidAudio's (not thread-safe)
/// `SortformerDiarizer`; the diarizer actor is its only caller.
protocol SortformerBackend: Sendable {
    /// Appends 16 kHz mono audio.
    func feed(_ samples: [Float]) throws
    /// Every segment so far, settled and still open.
    func segments() -> [SortformerSlotSegment]
    /// Ends the audio and settles the open segments.
    func finish() throws
}

/// Live speaker labels from FluidAudio's streaming Sortformer (palettized build, at most 4 speakers, a new
/// result about every 480 ms, a second or so behind the audio).
///
/// Cluster ids are the model's slots, `S0`…`S3`. The model loads on first use, so building one is free; it
/// needs the live speakers model installed. Feeding is serial.
public actor SortformerSpeakerDiarizer: SpeakerDiarizer {
    /// The cluster id of a Sortformer slot (`S2` for slot 2).
    public static func clusterID(slot: Int) -> String { "S\(slot)" }

    private let load: @Sendable () async throws -> any SortformerBackend
    private var backend: (any SortformerBackend)?
    private var finished = false

    /// A diarizer over the model installed as `modelID` in `models`.
    public init(models: ModelManager, modelID: String = FluidAudioModels.sortformerID) {
        self.load = {
            try await EngineSupport.requireInstalled(models: models, id: modelID)
            return try await FluidSortformerBackend.load(root: models.root)
        }
    }

    init(backend: any SortformerBackend) {
        self.load = { backend }
    }

    init(loading load: @escaping @Sendable () async throws -> any SortformerBackend) {
        self.load = load
    }

    public func feed(_ chunk: AudioChunk) async throws {
        guard chunk.format == EngineSupport.audioFormat else { throw FluidAudioEngineError.unsupportedFormat }
        let backend = try await ready()
        guard !chunk.samples.isEmpty else { return }
        try backend.feed(chunk.samples)
    }

    public func turns() async -> [SpeakerTurn] {
        guard let backend else { return [] }
        return Self.turns(from: backend.segments())
    }

    public func finish() async throws -> [SpeakerTurn] {
        let backend = try await ready()
        if !finished {
            finished = true
            try backend.finish()
        }
        return Self.turns(from: backend.segments())
    }

    private func ready() async throws -> any SortformerBackend {
        if let backend { return backend }
        let loaded = try await load()
        // A second call that waited on the load finds the first one's backend and drops its own.
        if let backend { return backend }
        backend = loaded
        return loaded
    }

    /// Segments as turns: in time order, one id per slot, empty ones dropped.
    static func turns(from segments: [SortformerSlotSegment]) -> [SpeakerTurn] {
        segments
            .filter { $0.end > $0.start }
            .sorted { ($0.start, $0.slot) < ($1.start, $1.slot) }
            .map { SpeakerTurn(speaker: clusterID(slot: $0.slot), start: $0.start, end: $0.end) }
    }
}

/// FluidAudio's `SortformerDiarizer` behind ``SortformerBackend``. The class is not thread-safe; the
/// diarizer actor is the only thing that ever calls it.
final class FluidSortformerBackend: SortformerBackend, @unchecked Sendable {
    /// The palettized build: about 100 MB on disk, the one that runs on every Legato device.
    static let config = SortformerConfig(precision: .palettized)

    private let diarizer: SortformerDiarizer

    private init(diarizer: SortformerDiarizer) { self.diarizer = diarizer }

    static func load(root: URL) async throws -> FluidSortformerBackend {
        FluidAudioModels.pinRevisions()
        let models = try await SortformerModels.loadFromHuggingFace(
            config: config, cacheDirectory: root, computeUnits: .cpuAndNeuralEngine)
        let diarizer = SortformerDiarizer(config: config)
        diarizer.initialize(models: models)
        return FluidSortformerBackend(diarizer: diarizer)
    }

    func feed(_ samples: [Float]) throws {
        _ = try diarizer.process(samples: samples)
    }

    func segments() -> [SortformerSlotSegment] {
        diarizer.timeline.speakers.values.flatMap { speaker in
            (speaker.finalizedSegments + speaker.tentativeSegments).map {
                SortformerSlotSegment(slot: speaker.index, start: TimeInterval($0.startTime), end: TimeInterval($0.endTime))
            }
        }
    }

    func finish() throws {
        _ = try diarizer.finalizeSession()
    }
}
