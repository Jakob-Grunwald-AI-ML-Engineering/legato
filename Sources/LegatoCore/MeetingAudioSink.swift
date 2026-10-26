import Foundation

/// Where a meeting's audio is recorded, one file per stream. Implemented by the audio layer.
///
/// Chunks arrive at the recording rate (16 kHz mono); the recorder finalizes its files in ``finish()``.
public protocol MeetingAudioSink: Sendable {
    /// Appends `chunk` to `stream`'s recording.
    func write(_ chunk: AudioChunk, stream: TranscriptEvent.Stream) async throws

    /// Appends `seconds` of silence to `stream`'s recording, keeping both streams on one timeline
    /// while a stream is muted.
    func writeSilence(seconds: TimeInterval, stream: TranscriptEvent.Stream) async throws

    /// Flushes and closes every stream's recording.
    func finish() async throws
}

/// Reads a finished (or leftover) meeting recording as Float32 16 kHz mono windows, for the post-pass.
public protocol AudioSampleReader: Sendable {
    /// Length of `stream`'s recording in seconds.
    func duration(of stream: TranscriptEvent.Stream) async throws -> TimeInterval

    /// The samples of `stream` within `range` (seconds from the start), clamped to the recording.
    func samples(of stream: TranscriptEvent.Stream, in range: Range<TimeInterval>) async throws -> [Float]
}
