import Foundation

public enum AppleSpeechError: Error, Sendable, Equatable {
    /// No SpeechTranscriber locale is equivalent to the requested one (identifier attached).
    case unsupportedLocale(String)
    /// The system reports no audio format compatible with the transcriber.
    case noAnalyzerFormat
    /// The locale could not be reserved even after releasing the oldest reservation.
    case reservationFailed(String)
    /// `transcribe` / `finish` without a successful `prepare`.
    case notPrepared
}
