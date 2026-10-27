import Foundation
import LegatoCore

/// One finished span of a meeting transcript.
public struct MeetingSegment: Sendable, Equatable, Codable, Identifiable {
    public enum Origin: String, Sendable, Equatable, Codable {
        /// From the live engine while the meeting ran.
        case live
        /// From the accuracy pass after the meeting.
        case postPass
    }

    public var id: UUID
    /// `.mixed` for a meeting with one live engine on the mix. Meetings from before that have `.mic` (the user)
    /// and `.system` (everyone else).
    public var stream: TranscriptEvent.Stream
    public var text: String
    /// Seconds from the start of the meeting.
    public var start: TimeInterval
    public var end: TimeInterval
    public var origin: Origin
    /// The mic picked up the speakers: ``EchoDeduper`` found the same words on the system stream.
    /// Echoes are kept but hidden, so they can be recovered.
    public var echo: Bool
    /// Who spoke: a person id of the meeting's ``Meeting/speakers``. Nil until a diarizer has attributed the
    /// segment, and for every segment of a meeting from before speakers existed.
    public var speaker: PersonID?

    public init(
        id: UUID = UUID(), stream: TranscriptEvent.Stream, text: String, start: TimeInterval, end: TimeInterval,
        origin: Origin = .live, echo: Bool = false, speaker: PersonID? = nil
    ) {
        self.id = id
        self.stream = stream
        self.text = text
        self.start = start
        self.end = end
        self.origin = origin
        self.echo = echo
        self.speaker = speaker
    }
}
