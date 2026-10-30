import Foundation

/// One step that turns a raw transcript into better text (inverse text normalization, LLM cleanup).
///
/// A processor may throw or return text unchanged; the pipeline that runs it treats both as "no change".
public protocol TranscriptPostProcessor: Sendable {
    /// Stable identifier, for logs and tests.
    var id: String { get }

    /// Returns the improved text for `text`, which is spoken in `locale`. Honors task cancellation.
    func process(_ text: String, locale: Locale) async throws -> String

    /// Acquires this run's fixed processing resources before capture, for every delivery mode.
    func runStarts() async throws
    /// Relinquishes run resources on every exit, including a failed or cancelled start.
    func runEnds() async
}

extension TranscriptPostProcessor {
    public func runStarts() async throws {}
    public func runEnds() async {}
}
