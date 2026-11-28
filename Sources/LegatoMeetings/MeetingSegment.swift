import Foundation
import LegatoCore

/// One finished span of a meeting transcript.
public struct MeetingSegment: Sendable, Equatable, Codable, Identifiable {
    public var id: UUID
    /// `.mixed`: one live engine hears the sum of the meeting's sources.
    public var stream: TranscriptEvent.Stream
    public var text: String
    /// Seconds from the start of the meeting.
    public var start: TimeInterval
    public var end: TimeInterval
    /// Who spoke: a person id of the meeting's ``Meeting/speakers``. Nil when the engine gave no speaker.
    public var speaker: PersonID?
    /// The segment's words with their meeting times, when the engine gave them; nil for meetings saved before they
    /// were kept (no key in `segments.jsonl`). The speaker cleanup reassigns and splits by them.
    public var words: [TranscriptWord]?

    public init(
        id: UUID = UUID(), stream: TranscriptEvent.Stream = .mixed, text: String, start: TimeInterval, end: TimeInterval,
        speaker: PersonID? = nil, words: [TranscriptWord]? = nil
    ) {
        self.id = id
        self.stream = stream
        self.text = text
        self.start = start
        self.end = end
        self.speaker = speaker
        self.words = words
    }
}
