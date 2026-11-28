import Foundation
import LegatoCore

/// The word times of a meeting's live segments as its Room log recorded them (`asr.segment` events), for meetings saved
/// before the segments kept them. Read-only. The meeting step and the replay command both fill segments from it,
/// so they judge the same words.
public enum RoomLogWords {
    public struct Entry {
        public var start: TimeInterval
        public var words: [TranscriptWord]
    }

    public static func read(_ url: URL) -> [Entry] {
        guard let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8) else { return [] }
        var entries: [Entry] = []
        for line in text.split(separator: "\n") where line.contains("\"asr.segment\"") {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                object["channel"] as? String == "asr.segment", let origin = object["tOrigin"] as? Double,
                let payload = object["payload"] as? [String: Any], let words = payload["words"] as? [[String: Any]],
                let metadata = payload["metadata"] as? [String: Any], let timings = metadata["timings"] as? [[String: Any]]
            else { continue }
            let texts = words.compactMap { $0["text"] as? String }
            let times = timings.map { (start: $0["t0"] as? Double, end: $0["t1"] as? Double) }
            guard texts.count == words.count, let placed = TranscriptWord.placed(texts, relative: times, origin: origin) else { continue }
            entries.append(Entry(start: origin, words: placed))
        }
        return entries
    }

    /// The logged words of `segment`: same start (within a millisecond) and the same text.
    public static func match(_ segment: MeetingSegment, in entries: [Entry]) -> [TranscriptWord]? {
        let text = segment.text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return entries.first { abs($0.start - segment.start) < 0.001 && $0.words.map(\.text).joined(separator: " ") == text }?.words
    }

    /// Gives every segment without word times the logged ones of `folder`'s Room log (`log/room.jsonl`), when they match.
    /// Returns how many segments got words.
    @discardableResult
    public static func fill(_ segments: inout [MeetingSegment], folder: URL) -> Int {
        guard segments.contains(where: { $0.words == nil }) else { return 0 }
        let logged = read(folder.appendingPathComponent("log/room.jsonl"))
        guard !logged.isEmpty else { return 0 }
        var filled = 0
        for index in segments.indices where segments[index].words == nil {
            if let words = match(segments[index], in: logged) {
                segments[index].words = words
                filled += 1
            }
        }
        return filled
    }
}
