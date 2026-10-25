import AVFAudio
import Foundation
import LegatoCore
import Speech
import Synchronization

/// On-device transcription with `SpeechAnalyzer` / `SpeechTranscriber` (iOS 26 / macOS 26).
/// Lifted from the keyboard spike. One locale per session; `nil` means the device locale.
public final class AppleSpeechEngine: DictationEngine {
    public let id = "apple-speech"

    private struct Run {
        let transcriber: SpeechTranscriber
        let analyzer: SpeechAnalyzer
        let format: AVAudioFormat
        var input: AsyncStream<AnalyzerInput>.Continuation?
        /// `analyzer.start`; `finish()` waits for it so it never finalizes an analyzer that has not begun.
        var started: Task<Void, Error>?
    }

    private let run = Mutex<Run?>(nil)

    public init() {}

    // MARK: Assets

    public func installAssets(locale: Locale?) -> AsyncStream<Double> {
        AsyncStream { continuation in
            let task = Task {
                do {
                    let resolved = try await Self.resolve(locale)
                    try await Self.reserve(resolved)
                    let transcriber = Self.makeTranscriber(resolved)
                    if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                        let progress = request.progress
                        let poll = Task {
                            while !Task.isCancelled {
                                continuation.yield(progress.fractionCompleted)
                                try? await Task.sleep(for: .milliseconds(250))
                            }
                        }
                        defer { poll.cancel() }
                        try await request.downloadAndInstall()
                    }
                } catch {
                    // The stream carries progress only; a failed install is visible to the
                    // caller as a stream that ends below 1.0 and a following `prepare` error.
                }
                if !Task.isCancelled { continuation.yield(1.0) }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: Prepare

    public func prepare(locale: Locale?) async throws -> AudioFormatSpec {
        let resolved = try await Self.resolve(locale)
        try await Self.reserve(resolved)
        let transcriber = Self.makeTranscriber(resolved)
        guard await AssetInventory.status(forModules: [transcriber]) == .installed else {
            throw DictationError.assetsNotInstalled
        }
        // Explicit priority: the default can inherit a low priority from an intent/background task.
        let analyzer = SpeechAnalyzer(modules: [transcriber], options: .init(priority: .userInitiated, modelRetention: .lingering))
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw AppleSpeechError.noAnalyzerFormat
        }
        // Resources load lazily by default; preheat so the first buffers are analyzed live.
        try await analyzer.prepareToAnalyze(in: format)
        run.withLock { $0 = Run(transcriber: transcriber, analyzer: analyzer, format: format, input: nil) }
        return AudioFormatSpec(sampleRate: format.sampleRate, channelCount: 1)
    }

    // MARK: Transcribe

    public func transcribe(_ input: AsyncStream<AudioChunk>) -> AsyncThrowingStream<TranscriptEvent, Error> {
        AsyncThrowingStream { continuation in
            guard let prepared = run.withLock({ $0 }) else {
                continuation.finish(throwing: AppleSpeechError.notPrepared)
                return
            }
            let (analyzerInput, analyzerContinuation) = AsyncStream.makeStream(of: AnalyzerInput.self)
            let started = Task { try await prepared.analyzer.start(inputSequence: analyzerInput) }
            run.withLock {
                $0?.input = analyzerContinuation
                $0?.started = started
            }

            let feeder = Task {
                for await chunk in input {
                    if let buffer = PCMPacker.buffer(from: chunk, format: prepared.format) {
                        analyzerContinuation.yield(AnalyzerInput(buffer: buffer))
                    }
                }
                analyzerContinuation.finish()
            }
            let task = Task {
                do {
                    try await started.value
                    var spacer = PhraseSpacer()
                    for try await result in prepared.transcriber.results {
                        let text = spacer.apply(String(result.text.characters), isFinal: result.isFinal)
                        let range = Self.seconds(result.range)
                        continuation.yield(TranscriptEvent(stream: .mic, text: text, isFinal: result.isFinal, range: range))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
                feeder.cancel()
            }
            continuation.onTermination = { _ in
                feeder.cancel()
                task.cancel()
            }
        }
    }

    // MARK: Finish

    public func finish() async throws {
        guard let current = run.withLock({ $0 }) else { throw AppleSpeechError.notPrepared }
        try await current.started?.value
        // The analyzer input ends when the caller's chunk stream ends (the feeder drains it first);
        // finishing it here could drop chunks still queued.
        try await current.analyzer.finalizeAndFinishThroughEndOfInput()
        run.withLock { $0 = nil }
    }

    // MARK: Helpers

    private static func resolve(_ locale: Locale?) async throws -> Locale {
        try await LocaleResolver.resolve(requested: locale) { await SpeechTranscriber.supportedLocale(equivalentTo: $0) }
    }

    private static func makeTranscriber(_ locale: Locale) -> SpeechTranscriber {
        // .progressiveTranscription = volatile + fast results; without it nothing arrives until finalize.
        SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
    }

    /// Reserves `locale`; at the reservation cap, releases the oldest reservation and retries once.
    private static func reserve(_ locale: Locale) async throws {
        if (try? await AssetInventory.reserve(locale: locale)) == true { return }
        let reserved = await AssetInventory.reservedLocales
        if reserved.contains(where: { $0.identifier == locale.identifier }) { return }
        if let oldest = reserved.first {
            _ = await AssetInventory.release(reservedLocale: oldest)
        }
        do {
            guard try await AssetInventory.reserve(locale: locale) else {
                throw AppleSpeechError.reservationFailed(locale.identifier)
            }
        } catch let error as AppleSpeechError {
            throw error
        } catch {
            throw AppleSpeechError.reservationFailed(locale.identifier)
        }
    }

    private static func seconds(_ range: CMTimeRange) -> Range<TimeInterval>? {
        let start = range.start.seconds
        let end = range.end.seconds
        guard start.isFinite, end.isFinite, start <= end else { return nil }
        return start..<end
    }
}
