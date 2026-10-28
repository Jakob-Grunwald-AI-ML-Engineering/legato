import Foundation
import LegatoCore

/// The model side of a streaming run: feeds samples, exposes the cumulative partial, and commits a segment.
protocol StreamingBackend: Sendable {
    /// Feeds 16 kHz mono samples.
    func process(_ samples: [Float]) async throws
    /// The cumulative partial text of the open segment.
    func partial() async -> String
    /// Finishes the open segment, returns its text and resets the model for the next one.
    func commit() async throws -> String
    /// The language tag the model reports for the open segment (for example "en-US"), if any.
    func detectedLanguage() async -> String?
    /// Switches the language hint between segments.
    func applyLanguage(_ hint: String) async
}

/// Runs one dictation session over a ``StreamingBackend``: partials as volatile events, a segment
/// committed (final event with its range) at each long silence and once more at the end of the input.
struct SegmentDriver {
    private var endpointer: SilenceEndpointer
    private var mapper: PartialEventMapper
    private var clamp: LanguageClamp
    private let languageUpdates: LiveLanguageUpdates?
    private var languageRevision = 0
    private var fed = 0
    private var base = 0
    private var hasText = false

    private static let sampleRate = 16_000

    init(endpointer: SilenceEndpointer, mapper: PartialEventMapper, clamp: LanguageClamp, languageUpdates: LiveLanguageUpdates? = nil) {
        self.endpointer = endpointer
        self.mapper = mapper
        self.clamp = clamp
        self.languageUpdates = languageUpdates
    }

    /// Consumes `input` until it ends or the task is cancelled, emitting events as they happen.
    /// - Throws: ``FluidAudioEngineError/unsupportedFormat`` for a chunk that is not 16 kHz mono, or the backend's error.
    mutating func run(
        _ input: AsyncStream<AudioChunk>, backend: some StreamingBackend, emit: (TranscriptEvent) -> Void
    ) async throws {
        for await chunk in input {
            guard chunk.format.sampleRate == Double(Self.sampleRate), chunk.format.channelCount == 1 else {
                throw FluidAudioEngineError.unsupportedFormat
            }
            guard !chunk.samples.isEmpty else { continue }
            // While idle, apply a selection before the first samples of the next phrase.
            if !endpointer.heardSpeech && !hasText { _ = await applyLanguageUpdate(backend) }
            fed += chunk.samples.count
            try await backend.process(chunk.samples)

            let text = await backend.partial()
            hasText = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if let event = mapper.partial(text) {
                emit(event)
                clamp.observe(detected: await backend.detectedLanguage())
            }
            if endpointer.feed(chunk.samples, hasText: hasText) {
                try await commitSegment(backend, emit)
            }
        }
        // The input ended (or the consumer left): flush what is still open, unless nobody is listening.
        guard !Task.isCancelled else { return }
        if fed > base, hasText || endpointer.heardSpeech {
            try await commitSegment(backend, emit)
        }
    }

    /// Only the driver touches the backend: language updates cannot interleave with processing or reset.
    private mutating func applyLanguageUpdate(_ backend: some StreamingBackend) async -> Bool {
        guard let update = languageUpdates?.newer(than: languageRevision) else { return false }
        languageRevision = update.revision
        clamp = LanguageClamp(preferred: update.preferred)
        await backend.applyLanguage(clamp.hint)
        return true
    }

    private mutating func commitSegment(_ backend: some StreamingBackend, _ emit: (TranscriptEvent) -> Void) async throws {
        clamp.observe(detected: await backend.detectedLanguage())
        let text = try await backend.commit()
        let rate = Double(Self.sampleRate)
        let range = (Double(base) / rate)..<(Double(fed) / rate)
        for event in mapper.commit(text, range: range) { emit(event) }
        base = fed
        hasText = false
        endpointer.reset()
        if !(await applyLanguageUpdate(backend)), let hint = clamp.segmentBoundary() {
            await backend.applyLanguage(hint)
        }
    }
}
