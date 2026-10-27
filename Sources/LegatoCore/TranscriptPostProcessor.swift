import Foundation

/// One step that turns a raw transcript into better text (inverse text normalization, LLM cleanup).
///
/// A processor may throw or return text unchanged; the pipeline that runs it treats both as "no change".
public protocol TranscriptPostProcessor: Sendable {
    /// Stable identifier, for logs and tests.
    var id: String { get }

    /// Returns the improved text for `text`, which is spoken in `locale`. Honors task cancellation.
    func process(_ text: String, locale: Locale) async throws -> String

    /// Whether the run that starts now cleans its text while it is still being spoken
    /// (`CleanupDelivery.live`: rolling passes over the run's whole raw text). Read once per run, when it
    /// starts. Default false: the session runs ``process(_:locale:)`` once on the whole text when the run stops.
    var cleansSegmentsLive: Bool { get }

    /// One rolling pass of a live run (or, `atStop`, its final pass): cleans `text`, the run's raw text (all
    /// of it, or past the length cap its trailing window). `context`: the cleaned text before `text` that stays
    /// as it is (frozen past the cap), empty for a whole-text pass; read-only, never part of the result.
    /// Default: ``process(_:locale:)``, its outcome unknown beyond the text.
    func cleanLivePass(_ text: String, context: String, locale: Locale, atStop: Bool) async throws -> LivePassResult

    /// How long the stop of a live run may spend on cleanup in all: the pass in flight and the final pass
    /// together. Past it the session cancels them and keeps the newest published text and the raw tail.
    /// Read at the stop. Default nil: no limit beyond the processor's own.
    var liveStopTimeLimit: Duration? { get }

    /// A run that cleans live starts now (called once, before its first pass), so a processor can sum up
    /// what the run's passes did. Default: nothing.
    func liveRunStarts()
}

extension TranscriptPostProcessor {
    public var cleansSegmentsLive: Bool { false }

    public var liveStopTimeLimit: Duration? { nil }

    public func liveRunStarts() {}

    public func cleanLivePass(_ text: String, context: String, locale: Locale, atStop: Bool) async throws -> LivePassResult {
        LivePassResult(text: try await process(text, locale: locale))
    }
}
