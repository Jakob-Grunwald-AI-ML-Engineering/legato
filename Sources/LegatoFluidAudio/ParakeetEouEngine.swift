import AVFAudio
import FluidAudio
import Foundation
import LegatoCore
import LegatoModels
import Synchronization

/// Live dictation with Parakeet EOU (FluidAudio): English only, small and fast, partials while speaking and
/// a final segment after `silenceMs` of silence. The model's own end-of-utterance signal is not used, so
/// both streaming engines share one endpointing rule.
///
/// `prepare` throws ``DictationError/assetsNotInstalled`` unless the model is installed in `models`. The loaded
/// model is shared (see ``EouModelCache``), so only the first engine to prepare pays the load and later
/// engines and sessions only reset it.
public final class ParakeetEouEngine: DictationEngine {
    public let id: String

    private let chunk: EouChunk
    private let silenceMs: Int
    private let rmsThreshold: Float
    private let models: ModelManager
    private let modelID: String
    private let run = Mutex<EngineRun<EouBackend>?>(nil)

    public init(
        chunk: EouChunk = .ms160,
        silenceMs: Int = 1200,
        rmsThreshold: Float = 0.004,
        models: ModelManager,
        modelID: String? = nil
    ) {
        self.chunk = chunk
        self.silenceMs = silenceMs
        self.rmsThreshold = rmsThreshold
        self.models = models
        self.modelID = modelID ?? FluidAudioModels.eouID(chunk)
        self.id = FluidAudioModels.eouID(chunk)
    }

    public func installAssets(locale: Locale?) -> AsyncStream<Double> {
        EngineSupport.installAssets(models: models, id: modelID)
    }

    public func prepare(locale: Locale?) async throws -> AudioFormatSpec {
        try await EngineSupport.requireInstalled(models: models, id: modelID)
        let folder = ParakeetEouInstaller(chunk: chunk).installFolder(root: await models.root)
        let manager = try await EouModelCache.shared.manager(at: folder, chunk: chunk)
        await manager.reset()
        let box = PartialBox()
        await manager.setPartialCallback { box.set($0) }
        run.withLock {
            $0 = EngineRun(backend: EouBackend(manager: manager, box: box), clamp: LanguageClamp(preferred: []))
        }
        return EngineSupport.audioFormat
    }

    public func transcribe(_ input: AsyncStream<AudioChunk>) -> AsyncThrowingStream<TranscriptEvent, any Error> {
        AsyncThrowingStream { continuation in
            guard let prepared = run.withLock({ $0 }) else {
                continuation.finish(throwing: FluidAudioEngineError.notPrepared)
                return
            }
            let silenceMs = self.silenceMs
            let rmsThreshold = self.rmsThreshold
            let task = Task {
                do {
                    var driver = SegmentDriver(
                        endpointer: SilenceEndpointer(silenceMs: silenceMs, rmsThreshold: rmsThreshold),
                        mapper: PartialEventMapper(),
                        clamp: prepared.clamp)
                    try await driver.run(input, backend: prepared.backend) { continuation.yield($0) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            run.withLock { $0?.task = task }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func finish() async throws {
        guard let current = run.withLock({ $0 }) else { throw FluidAudioEngineError.notPrepared }
        await current.task?.value
        run.withLock { $0 = nil }
    }
}

/// Parakeet EOU's streaming manager behind the ``StreamingBackend`` seam.
struct EouBackend: StreamingBackend {
    let manager: StreamingEouAsrManager
    let box: PartialBox

    func process(_ samples: [Float]) async throws {
        guard let buffer = Self.buffer(samples) else { return }
        _ = try await manager.process(audioBuffer: buffer.value)
    }

    func partial() async -> String { box.get() }

    func commit() async throws -> String {
        let text = try await manager.finish()
        await manager.reset()
        box.set("")
        return text
    }

    func detectedLanguage() async -> String? { nil }

    func applyLanguage(_ hint: String) async {}

    /// `AVAudioPCMBuffer` is not Sendable; this one is built here and handed straight to the manager.
    private struct Handoff: @unchecked Sendable { let value: AVAudioPCMBuffer }

    private static func buffer(_ samples: [Float]) -> Handoff? {
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false),
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
            let channel = buffer.floatChannelData?[0]
        else { return nil }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { channel.update(from: $0.baseAddress!, count: samples.count) }
        return Handoff(value: buffer)
    }
}
