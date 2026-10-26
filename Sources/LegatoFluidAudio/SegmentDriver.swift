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
    private var fed = 0
    private var base = 0
    private var hasText = false

    private static let sampleRate = 16_000

    init(endpointer: SilenceEndpointer, mapper: PartialEventMapper, clamp: LanguageClamp) {
        self.endpointer = endpointer
        self.mapper = mapper
        self.clamp = clamp
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

    private mutating func commitSegment(_ backend: some StreamingBackend, _ emit: (TranscriptEvent) -> Void) async throws {
        clamp.observe(detected: await backend.detectedLanguage())
        let text = try await backend.commit()
        let rate = Double(Self.sampleRate)
        let range = (Double(base) / rate)..<(Double(fed) / rate)
        for event in mapper.commit(text, range: range) { emit(event) }
        base = fed
        hasText = false
        endpointer.reset()
        if let hint = clamp.segmentBoundary() { await backend.applyLanguage(hint) }
    }
}
