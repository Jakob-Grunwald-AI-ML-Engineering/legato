import Foundation

/// Where a meeting's audio is recorded, one file per stream. Implemented by the audio layer.
///
/// Chunks arrive at the recording rate (16 kHz mono); the recorder finalizes its files in ``finish()``.
/// A meeting with several sources also writes the `.mixed` stream (what the live engine heard); with one
/// source that source's recording is the mix and `.mixed` is never written.
public protocol MeetingAudioSink: Sendable {
    /// Appends `chunk` to `stream`'s recording.
    func write(_ chunk: AudioChunk, stream: TranscriptEvent.Stream) async throws

    /// Appends `seconds` of silence to `stream`'s recording, keeping both streams on one timeline
    /// while a stream is muted.
    func writeSilence(seconds: TimeInterval, stream: TranscriptEvent.Stream) async throws

    /// Flushes and closes every stream's recording.
    func finish() async throws
}
