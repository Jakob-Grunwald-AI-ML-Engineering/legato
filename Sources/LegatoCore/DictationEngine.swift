import Foundation

/// A speech-to-text backend. One locale per session; `nil` means "auto" (engine decides).
public protocol DictationEngine: Sendable {
    /// Stable identifier recorded in history entries.
    var id: String { get }

    /// Downloads the model for `locale`. Emits progress in 0...1 and finishes when done.
    func installAssets(locale: Locale?) -> AsyncStream<Double>

    /// Verifies assets are installed and warms the engine up. Returns the audio format the engine wants.
    /// - Throws: `DictationError.assetsNotInstalled` when the model is missing.
    func prepare(locale: Locale?) async throws -> AudioFormatSpec

    /// Transcribes `input` until it finishes. The returned stream ends once all results are delivered.
    func transcribe(_ input: AsyncStream<AudioChunk>) -> AsyncThrowingStream<TranscriptEvent, Error>

    /// Finalizes pending audio so remaining results are delivered.
    func finish() async throws
}
