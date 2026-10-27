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

/// Reads a finished (or leftover) meeting recording as Float32 16 kHz mono windows, for the post-pass.
public protocol AudioSampleReader: Sendable {
    /// Length of `stream`'s recording in seconds.
    func duration(of stream: TranscriptEvent.Stream) async throws -> TimeInterval

    /// The samples of `stream` within `range` (seconds from the start), clamped to the recording.
    func samples(of stream: TranscriptEvent.Stream, in range: Range<TimeInterval>) async throws -> [Float]
}

/// One stretch of a single speaker's voice, as a diarizer reports it.
///
/// `speaker` is the diarizer's own cluster id while it is fresh from the model, and a person id
/// (`P1`, `P2`, …) once the meeting has mapped it.
public struct SpeakerTurn: Sendable, Equatable, Codable {
    public var speaker: String
    /// Seconds from the start of the audio the diarizer was given.
    public var start: TimeInterval
    public var end: TimeInterval

    public init(speaker: String, start: TimeInterval, end: TimeInterval) {
        self.speaker = speaker
        self.start = start
        self.end = end
    }

    public var duration: TimeInterval { max(0, end - start) }
}

/// Tells speakers apart while audio streams in (the live mix of a meeting).
///
/// Feeding is serial. An implementation may lag behind the audio by about a second, and may revise its most
/// recent turns, so ``turns()`` always answers with every turn so far.
public protocol SpeakerDiarizer: Sendable {
    /// Teaches the diarizer one known voice (the user's enrolment sample: 16 kHz mono Float32) and returns the
    /// cluster id its turns will carry.
    func enroll(samples: [Float]) async throws -> String

    /// Appends audio. Chunks are in the recording rate (16 kHz mono) and arrive in time order.
    func feed(_ chunk: AudioChunk) async throws

    /// Every turn found so far, in time order.
    func turns() async -> [SpeakerTurn]

    /// Ends the audio and returns the final turns.
    func finish() async throws -> [SpeakerTurn]
}

/// Tells speakers apart in a finished recording (the after-meeting pass).
public protocol BatchDiarizer: Sendable {
    /// Turns of `samples`: 16 kHz mono Float32 (``BatchAudio/sampleRate``), in time order.
    func diarize(samples: [Float]) async throws -> [SpeakerTurn]
}
