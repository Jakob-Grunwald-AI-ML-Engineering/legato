import Foundation
import LegatoCore

/// A stretch of a stream's audio that was replaced by silence because the user was muted.
public struct MutedRange: Sendable, Equatable, Codable {
    public var stream: TranscriptEvent.Stream
    /// Seconds from the start of the meeting.
    public var start: TimeInterval
    public var end: TimeInterval

    public init(stream: TranscriptEvent.Stream, start: TimeInterval, end: TimeInterval) {
        self.stream = stream
        self.start = start
        self.end = end
    }
}

/// A recorded meeting: what `meeting.json` holds. Segments live next to it in `segments.jsonl`.
public struct Meeting: Sendable, Equatable, Codable, Identifiable {
    public enum State: String, Sendable, Equatable, Codable {
        /// Capturing now.
        case recording
        /// Stopped; the after-stop chain (post-pass, m4a, summary) has not finished.
        case processing
        case finished
        /// The app died while recording; found by ``MeetingRecovery``.
        case interrupted
    }

    public var id: UUID
    public var title: String
    public var date: Date
    /// Seconds of audio.
    public var duration: TimeInterval
    /// The live engine's id.
    public var engineID: String
    /// The post-pass model's id, once it ran.
    public var postPassID: String?
    public var mutedRanges: [MutedRange]
    public var state: State

    public init(
        id: UUID = UUID(), title: String, date: Date, duration: TimeInterval = 0, engineID: String,
        postPassID: String? = nil, mutedRanges: [MutedRange] = [], state: State = .recording
    ) {
        self.id = id
        self.title = title
        self.date = date
        self.duration = duration
        self.engineID = engineID
        self.postPassID = postPassID
        self.mutedRanges = mutedRanges
        self.state = state
    }
}
