import AVFAudio
import Foundation
import LegatoCore
import OSLog
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

    private let vocabulary: (any VocabularyHintProvider)?

    private static let log = Logger(subsystem: "app.legato", category: "AppleSpeechEngine")

    /// - Parameter vocabulary: supplies hints (up to 50, for ``HintSink/appleSpeech``) set as the analyzer's
    ///   contextual strings; none, or a failure to set them, means unbiased recognition.
    public init(vocabulary: (any VocabularyHintProvider)? = nil) {
        self.vocabulary = vocabulary
    }

    /// The hint provider this engine was built with.
    public var vocabularyProvider: (any VocabularyHintProvider)? { vocabulary }

    // MARK: Assets

    public func installAssets(locale: Locale?) -> AsyncStream<Double> {
        AssetInstallProgress.stream {
            let resolved = try await Self.resolve(locale)
            try await Self.reserve(resolved)
            let transcriber = Self.makeTranscriber(resolved)
            guard let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) else { return nil }
            return AssetInstall(progress: request.progress, run: { try await request.downloadAndInstall() })
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
        await applyVocabulary(to: analyzer)
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
                let packer = PCMStreamPacker(format: prepared.format)
                for await chunk in input {
                    if let buffer = packer.buffer(from: chunk) {
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

    /// Best-effort: a failure is logged and the dictation runs unbiased.
    private func applyVocabulary(to analyzer: SpeechAnalyzer) async {
        guard let vocabulary else { return }
        let strings = await AppleSpeechVocabulary.contextualStrings(from: vocabulary)
        guard !strings.isEmpty else { return }
        let context = AnalysisContext()
        context.contextualStrings[.general] = strings
        do {
            try await analyzer.setContext(context)
        } catch {
            Self.log.error("setContext failed, continuing unbiased: \(Self.describe(error), privacy: .public)")
        }
    }

    /// An error as it may be logged: its type, domain and code, never its description, which could echo
    /// dictated text.
    static func describe(_ error: any Error) -> String {
        let ns = error as NSError
        return "\(type(of: error)) \(ns.domain) \(ns.code)"
    }

    private static func resolve(_ locale: Locale?) async throws -> Locale {
        try await LocaleResolver.resolve(requested: locale) { await SpeechTranscriber.supportedLocale(equivalentTo: $0) }
    }

    private static func makeTranscriber(_ locale: Locale) -> SpeechTranscriber {
        // .progressiveTranscription = volatile + fast results; without it nothing arrives until finalize.
        SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
    }

    /// Reserves `locale`; at the reservation cap, releases the oldest reservation first.
    private static func reserve(_ locale: Locale) async throws {
        try await LocaleReservation.reserve(
            locale,
            maximum: AssetInventory.maximumReservedLocales,
            reserved: { await AssetInventory.reservedLocales },
            attempt: { try await AssetInventory.reserve(locale: $0) },
            release: { await AssetInventory.release(reservedLocale: $0) })
    }

    private static func seconds(_ range: CMTimeRange) -> Range<TimeInterval>? {
        let start = range.start.seconds
        let end = range.end.seconds
        guard start.isFinite, end.isFinite, start <= end else { return nil }
        return start..<end
    }
}
