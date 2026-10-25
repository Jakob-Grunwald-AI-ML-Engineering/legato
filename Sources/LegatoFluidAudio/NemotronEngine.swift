import FluidAudio
import Foundation
import LegatoCore
import LegatoModels
import Synchronization

/// Loaded Nemotron models, shared across sessions and engines, keyed by model folder, so only the first
/// `prepare` per folder pays the load (and a cold Neural Engine compile if the install was cut short).
actor NemotronModelCache {
    static let shared = NemotronModelCache()

    private var loads: [String: Task<SharedNemotronMultilingualModels, any Error>] = [:]

    func models(at folder: URL) async throws -> SharedNemotronMultilingualModels {
        let key = folder.standardizedFileURL.path
        if let existing = loads[key] { return try await existing.value }
        let load = Task {
            try await StreamingNemotronMultilingualAsrManager.preloadShared(
                from: folder, configuration: FluidAudioCompute.configuration())
        }
        loads[key] = load
        do {
            return try await load.value
        } catch {
            loads[key] = nil  // a failed or cancelled load is not cached
            throw error
        }
    }

    func evictAll() { loads.removeAll() }
}

/// Releases every cached Nemotron model (about 1 GB resident each), for example on a memory warning.
public func releaseCachedNemotronModels() async {
    await NemotronModelCache.shared.evictAll()
}

/// Live dictation with Nemotron multilingual streaming (FluidAudio): partials while speaking, a final
/// segment after `silenceMs` of silence.
///
/// - `preferredLocales` wins over the session's `locale`, which only counts when none are configured. One
///   locale is that language hint; several run on `auto` and narrow to the first preferred one when the
///   detected language falls outside the set.
/// - `prepare` throws ``DictationError/assetsNotInstalled`` unless the model is installed in `models`.
public final class NemotronEngine: DictationEngine {
    public let id: String

    private let variant: NemotronVariant
    private let chunkMs: Int
    private let preferredLocales: [Locale]
    private let silenceMs: Int
    private let rmsThreshold: Float
    private let models: ModelManager
    private let modelID: String
    private let run = Mutex<EngineRun<NemotronBackend>?>(nil)

    /// - Parameters:
    ///   - variant: the Nemotron vocabulary; `.latin` is smaller and faster for de, en, fr, es, it, pt.
    ///   - chunkMs: the tier: 560, 1120 or 2240 ms. Lower is faster but loses punctuation on long runs.
    ///   - preferredLocales: the languages to expect; empty or several means `auto`.
    ///   - silenceMs: silence that ends a segment.
    ///   - rmsThreshold: chunk RMS below this counts as silence.
    ///   - models: where the model is installed from and checked.
    ///   - modelID: the catalog id of the model; defaults to the one for `variant` and `chunkMs`.
    public init(
        variant: NemotronVariant = .multilingual,
        chunkMs: Int = 1120,
        preferredLocales: [Locale] = [],
        silenceMs: Int = 1200,
        rmsThreshold: Float = 0.004,
        models: ModelManager,
        modelID: String? = nil
    ) {
        self.variant = variant
        self.chunkMs = chunkMs
        self.preferredLocales = preferredLocales
        self.silenceMs = silenceMs
        self.rmsThreshold = rmsThreshold
        self.models = models
        self.modelID = modelID ?? FluidAudioModels.nemotronID(variant, chunkMs: chunkMs)
        self.id = FluidAudioModels.nemotronID(variant, chunkMs: chunkMs)
    }

    public func installAssets(locale: Locale?) -> AsyncStream<Double> {
        EngineSupport.installAssets(models: models, id: modelID)
    }

    public func prepare(locale: Locale?) async throws -> AudioFormatSpec {
        try await EngineSupport.requireInstalled(models: models, id: modelID)
        let folder = NemotronInstaller(variant: variant, chunkMs: chunkMs).installFolder(root: await models.root)
        let shared = try await NemotronModelCache.shared.models(at: folder)

        // Per-session state only: the heavy models come from the cache.
        let manager = StreamingNemotronMultilingualAsrManager(configuration: FluidAudioCompute.configuration())
        try await manager.loadFromShared(shared)
        var clamp = LanguageClamp(preferred: LanguageClamp.preferred(configured: preferredLocales, session: locale))
        clamp.beginSession()
        await manager.setLanguage(clamp.hint)
        let box = PartialBox()
        await manager.setPartialCallback { box.set($0) }

        run.withLock { $0 = EngineRun(backend: NemotronBackend(manager: manager, box: box), clamp: clamp) }
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
        // The run ends when the caller's chunk stream ends; the driver flushes the open segment first.
        // A failure already reached the consumer through the event stream.
        await current.task?.value
        run.withLock { $0 = nil }
    }
}

/// Nemotron's streaming manager behind the ``StreamingBackend`` seam.
struct NemotronBackend: StreamingBackend {
    let manager: StreamingNemotronMultilingualAsrManager
    let box: PartialBox

    func process(_ samples: [Float]) async throws {
        _ = try await manager.process(samples: samples)
    }

    func partial() async -> String { box.get() }

    func commit() async throws -> String {
        let text = try await manager.finish()
        await manager.reset()
        box.set("")
        return text
    }

    func detectedLanguage() async -> String? { await manager.detectedLanguage() }

    func applyLanguage(_ hint: String) async { await manager.setLanguage(hint) }
}
