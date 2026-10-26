import FluidAudio
import Foundation
import LegatoCore
import LegatoModels

/// Loaded Parakeet batch models, shared across calls and transcribers, keyed by folder.
actor ParakeetModelCache {
    static let shared = ParakeetModelCache()

    private var loads: [String: Task<AsrModels, any Error>] = [:]

    func models(at folder: URL, version: AsrModelVersion) async throws -> AsrModels {
        let key = folder.standardizedFileURL.path
        if let existing = loads[key] { return try await existing.value }
        let load = Task {
            try await AsrModels.load(from: folder, configuration: FluidAudioCompute.configuration(), version: version)
        }
        loads[key] = load
        do {
            return try await load.value
        } catch {
            loads[key] = nil
            throw error
        }
    }

    func evictAll() { loads.removeAll() }
}

/// Releases every cached Parakeet batch model, for example on a memory warning.
public func releaseCachedParakeetModels() async {
    await ParakeetModelCache.shared.evictAll()
}

/// Batch transcription with Parakeet TDT v3 or Ultra (FluidAudio): a finished 16 kHz mono recording in,
/// sentence-sized final events with ranges out. Segments end at `.`, `?`, `!` or a pause over 0.8 s.
///
/// Throws ``DictationError/assetsNotInstalled`` unless the model is installed in `models`.
public final class ParakeetTranscriber: BatchTranscriber {
    public let id: String

    private let model: ParakeetBatchModel
    private let models: ModelManager
    private let modelID: String

    public init(model: ParakeetBatchModel, models: ModelManager, modelID: String? = nil) {
        self.model = model
        self.models = models
        let defaultID = model == .v3 ? FluidAudioModels.parakeetV3ID : FluidAudioModels.parakeetUltraID
        self.modelID = modelID ?? defaultID
        self.id = defaultID
    }

    public func transcribe(samples: [Float], stream: TranscriptEvent.Stream) async throws -> [TranscriptEvent] {
        guard !samples.isEmpty else { return [] }
        try await EngineSupport.requireInstalled(models: models, id: modelID)
        let folder = ParakeetBatchInstaller(model: model).installFolder(root: await models.root)
        let loaded = try await ParakeetModelCache.shared.models(at: folder, version: model.version)

        let manager = AsrManager(config: .default, models: loaded)
        var decoderState = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
        // The model rejects clips under its minimum length; pad them with silence, keep ranges to the real audio.
        let minimum = ASRConstants.minimumRequiredSamples(forSampleRate: Int(BatchAudio.sampleRate))
        let padded = samples.count >= minimum ? samples : samples + [Float](repeating: 0, count: minimum - samples.count)
        let result = try await manager.transcribe(padded, decoderState: &decoderState)

        let duration = Double(samples.count) / BatchAudio.sampleRate
        let tokens = (result.tokenTimings ?? []).map { TimedToken(text: $0.token, start: $0.startTime, end: min($0.endTime, duration)) }
        let events = SegmentGrouper.group(tokens, stream: stream)
        if !events.isEmpty { return events }

        // No usable token timings: one event for the whole recording.
        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? [] : [TranscriptEvent(stream: stream, text: text, isFinal: true, range: 0..<duration)]
    }
}

