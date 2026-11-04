import Foundation

/// What one person said in a row: consecutive segments of one speaker, read as one paragraph.
public struct MeetingTurn: Sendable, Equatable, Identifiable {
    /// The first segment's id.
    public var id: UUID
    public var speaker: PersonID?
    /// The first segment's start.
    public var start: TimeInterval
    public var end: TimeInterval
    public var text: String
}

public enum MeetingTurns {
    /// Joins consecutive segments of one speaker into a turn (their texts with a space, the first start kept). The stored
    /// segments are not changed. A segment without a speaker is a turn of its own (older meetings have none to compare).
    /// Each time in `breaks` (the start of a gap, a muted or a paused range) ends the turn it falls in: no turn spans it.
    public static func merge(_ segments: [MeetingSegment], breakingAt breaks: [TimeInterval] = []) -> [MeetingTurn] {
        var turns: [MeetingTurn] = []
        var previous: MeetingSegment?
        for segment in segments.enumerated().sorted(by: { ($0.element.start, $0.offset) < ($1.element.start, $1.offset) }).map(\.element) {
            if let last = previous, let speaker = segment.speaker, speaker == last.speaker,
                !breaks.contains(where: { $0 > last.start && $0 <= segment.start })
            {
                turns[turns.count - 1].text += " " + segment.text
                turns[turns.count - 1].end = max(turns[turns.count - 1].end, segment.end)
            } else {
                turns.append(MeetingTurn(id: segment.id, speaker: segment.speaker, start: segment.start, end: segment.end, text: segment.text))
            }
            previous = segment
        }
        return turns
    }
}
