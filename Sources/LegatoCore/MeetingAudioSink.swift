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

    /// Turns of the recording at `file` (a CAF or m4a), in time order. The file is read from disk as needed,
    /// never held in memory whole, so a long meeting costs no more memory than a short one.
    func diarize(file: URL) async throws -> [SpeakerTurn]
}

/// Whether a ``MicEnhancer`` is cleaning the mic or has handed the raw mic through.
public enum MicEnhancerState: Sendable, Equatable {
    /// The model is cleaning the mic.
    case active
    /// The model failed or fell behind; the raw mic passes through. The app can tell the user.
    case fellBack(MicEnhancerFallback)
}

/// Why a ``MicEnhancer`` stopped cleaning the mic.
public enum MicEnhancerFallback: Sendable, Equatable {
    /// More than a second of audio was waiting for the model (or for the reference).
    case lagging
    /// The model threw; the message is for display.
    case failed(String)
}

/// Cleans the meeting microphone: echo cancellation against a reference (what the speakers played), noise
/// suppression and dereverberation.
///
/// Everything is 16 kHz mono Float32 on the meeting mixer's clock: sample `i` of the mic and sample `i` of the
/// reference are the same instant, and sample `i` out is the cleaned sample `i` in. Calls are serial.
public protocol MicEnhancer: Sendable {
    /// Appends `mic` and its `reference` (nil: no reference, as on iOS, which denoises only) and returns the
    /// cleaned samples now ready, in order. The model delays its output by a few milliseconds, so this may
    /// return fewer samples than were fed; ``flush()`` returns the rest. Never throws: on trouble the raw mic
    /// passes through (see ``state()``), still in order and without gaps.
    func enhance(mic: [Float], reference: [Float]?) async -> [Float]

    /// Returns every sample fed but not yet returned and ends the stream.
    func flush() async -> [Float]

    /// Whether the enhancer is still cleaning.
    func state() async -> MicEnhancerState

    /// Loads the model now, before any audio, so the first samples do not queue up behind the load. A model
    /// that cannot load falls back here (see ``state()``). Optional: the first ``enhance(mic:reference:)`` loads it too.
    func prepare() async
}

extension MicEnhancer {
    public func prepare() async {}
}
