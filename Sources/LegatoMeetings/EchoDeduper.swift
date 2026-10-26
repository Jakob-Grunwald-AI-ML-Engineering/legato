import Foundation
import LegatoCore

/// Marks mic segments that are the speakers' words picked up again by the microphone.
///
/// A mic segment is an echo when at least ``overlapThreshold`` of its normalised words appear in a
/// system segment that is within ``window`` seconds of it. System segments are never echoes. Marking is
/// recomputed from scratch each time, so it can run again after segments change (a late system segment,
/// the post-pass). Echoes are flagged, never removed.
public enum EchoDeduper {
    /// Share of the mic segment's words that must be found in the system segment.
    public static let overlapThreshold = 0.8
    /// How far apart, in seconds, the two segments may be and still count as the same moment.
    public static let window: TimeInterval = 2

    public static func mark(_ segments: [MeetingSegment]) -> [MeetingSegment] {
        let system = segments.filter { $0.stream == .system }.map { (segment: $0, tokens: tokens($0.text)) }
        return segments.map { segment in
            var marked = segment
            marked.echo = segment.stream == .mic && isEcho(segment, of: system)
            return marked
        }
    }

    private static func isEcho(_ mic: MeetingSegment, of system: [(segment: MeetingSegment, tokens: [String])]) -> Bool {
        let words = tokens(mic.text)
        guard !words.isEmpty else { return false }
        return system.contains { other in
            guard mic.start <= other.segment.end + window, mic.end >= other.segment.start - window else { return false }
            var available = Dictionary(other.tokens.map { ($0, 1) }, uniquingKeysWith: +)
            var matched = 0
            for word in words where available[word, default: 0] > 0 {
                available[word, default: 0] -= 1
                matched += 1
            }
            return Double(matched) / Double(words.count) >= overlapThreshold
        }
    }

    private static func tokens(_ text: String) -> [String] {
        text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }
}
