import Foundation
import LegatoCore
import LegatoModels
import Synchronization

public enum FluidAudioEngineError: Error, Sendable, Equatable {
    /// `transcribe` / `finish` without a successful `prepare`.
    case notPrepared
    /// A chunk that is not 16 kHz mono; `prepare` asks the source for that format.
    case unsupportedFormat
}

/// What the FluidAudio engines share: the model manager hand-off and the audio format they ask for.
enum EngineSupport {
    /// Every FluidAudio streaming model wants 16 kHz mono Float32.
    static let audioFormat = AudioFormatSpec(sampleRate: 16_000, channelCount: 1)

    /// Installs through the manager and maps its states to `0...1`. Finishes at `1` only if the model ends up installed.
    static func installAssets(models: ModelManager, id: String) -> AsyncStream<Double> {
        AsyncStream { continuation in
            let task = Task {
                var last = -1.0
                for await state in await models.install(id) {
                    if let fraction = InstallProgress.fraction(for: state), fraction > last {
                        last = fraction
                        continuation.yield(fraction)
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Throws `assetsNotInstalled` unless the model is fully installed (not missing, downloading, warming or failed).
    static func requireInstalled(models: ModelManager, id: String) async throws {
        guard case .installed = await models.state(of: id) else { throw DictationError.assetsNotInstalled }
    }
}

/// The latest cumulative partial, written by the model's callback and read by the feeder.
final class PartialBox: Sendable {
    private let text = Mutex("")
    func set(_ value: String) { text.withLock { $0 = value } }
    func get() -> String { text.withLock { $0 } }
}

/// The run state both engines keep between `prepare`, `transcribe` and `finish`.
struct EngineRun<Backend: StreamingBackend>: Sendable {
    let backend: Backend
    let clamp: LanguageClamp
    /// Ends when the input ends; failures reach the consumer through the event stream, not here.
    var task: Task<Void, Never>?
}
