import Foundation

/// One step that turns a raw transcript into better text (inverse text normalization, LLM cleanup).
///
/// A processor may throw or return text unchanged; the pipeline that runs it treats both as "no change".
public protocol TranscriptPostProcessor: Sendable {
    /// Stable identifier, for logs and tests.
    var id: String { get }

    /// Returns the improved text for `text`, which is spoken in `locale`. Honors task cancellation.
    func process(_ text: String, locale: Locale) async throws -> String

    /// Whether the run that starts now cleans each committed segment while it is still being spoken
    /// (`CleanupDelivery.live`). Read once per run, when it starts. Default false: the session runs
    /// ``process(_:locale:)`` once on the whole text when the run stops.
    var cleansSegmentsLive: Bool { get }

    /// Cleans one committed segment of a live run (or, `atStop`, the segments still raw when it stopped).
    /// `context` is the cleaned text that came before it, its end only; the result replaces `text` alone.
    /// Default: ``process(_:locale:)``.
    func processSegment(_ text: String, context: String, locale: Locale, atStop: Bool) async throws -> String
}

extension TranscriptPostProcessor {
    public var cleansSegmentsLive: Bool { false }

    public func processSegment(_ text: String, context: String, locale: Locale, atStop: Bool) async throws -> String {
        try await process(text, locale: locale)
    }
}
