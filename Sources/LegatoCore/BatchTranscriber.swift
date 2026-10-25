import Foundation

/// A speech model that transcribes a finished recording (a meeting post-pass), as opposed to a
/// ``DictationEngine`` that works while the user speaks.
public protocol BatchTranscriber: Sendable {
    /// Stable identifier, recorded next to the transcript.
    var id: String { get }

    /// Transcribes `samples`: 16 kHz mono Float32 (``BatchAudio/sampleRate``).
    ///
    /// Returns final events in time order, one per sentence or pause-separated segment, each with a
    /// `range` in seconds from the start of `samples`. Ranges never overlap. Silence yields `[]`.
    ///
    /// - Throws: `DictationError.assetsNotInstalled` when the model is missing.
    func transcribe(samples: [Float], stream: TranscriptEvent.Stream) async throws -> [TranscriptEvent]
}

public enum BatchAudio {
    /// The sample rate every ``BatchTranscriber`` expects.
    public static let sampleRate: Double = 16_000
}
