import Foundation
import LegatoCore

/// Decides who said what from diarizer turns. Pure.
///
/// - A segment goes to the speaker whose turns overlap it most; no overlap means nobody yet.
/// - The best turns are the after-meeting (offline) ones when there are any, else the live ones.
/// - The live diarizer lags about a second, so the turns of the last few seconds are revised as new audio
///   arrives: ``relabelRecent(_:turns:now:window:)`` re-assigns only the segments that ended within
///   ``recentWindow`` seconds, and older segments are final.
/// - The after-meeting pass has clusters of its own; ``mapOffline(_:onto:directory:)`` maps each onto the
///   person it overlaps most, so names and merges survive, and gives an unmatched cluster a new person.
public enum SpeakerAssigner {
    /// How far back from the newest audio a live relabel reaches, in seconds.
    public static let recentWindow: TimeInterval = 3

    // MARK: Segments

    /// The speaker with the most overlap with `start..<end`; the earliest turn wins a tie. A span with no length
    /// takes the turn it falls in.
    public static func speaker(start: TimeInterval, end: TimeInterval, turns: [SpeakerTurn]) -> String? {
        if end <= start {
            return turns.first { $0.start <= start && start < $0.end }?.speaker
        }
        var overlap: [String: TimeInterval] = [:]
        var firstSeen: [String: Int] = [:]
        for (index, turn) in turns.enumerated() {
            let shared = min(end, turn.end) - max(start, turn.start)
            guard shared > 0 else { continue }
            overlap[turn.speaker, default: 0] += shared
            if firstSeen[turn.speaker] == nil { firstSeen[turn.speaker] = index }
        }
        return overlap.max { a, b in
            a.value != b.value ? a.value < b.value : firstSeen[a.key]! > firstSeen[b.key]!
        }?.key
    }

    /// Offline turns when there are any, else live ones.
    public static func bestTurns(live: [SpeakerTurn], offline: [SpeakerTurn]?) -> [SpeakerTurn] {
        if let offline, !offline.isEmpty { return offline }
        return live
    }

    /// Every segment with the speaker `turns` give it (nobody where they are silent).
    public static func assign(_ segments: [MeetingSegment], turns: [SpeakerTurn]) -> [MeetingSegment] {
        segments.map { segment in
            var labelled = segment
            labelled.speaker = speaker(start: segment.start, end: segment.end, turns: turns)
            return labelled
        }
    }

    /// Re-assigns the segments that ended in the last `window` seconds before `now`; the rest stay as they are.
    /// A recent segment the turns say nothing about keeps its label.
    public static func relabelRecent(
        _ segments: [MeetingSegment], turns: [SpeakerTurn], now: TimeInterval, window: TimeInterval = recentWindow
    ) -> [MeetingSegment] {
        segments.map { segment in
            guard segment.end >= now - window else { return segment }
            var labelled = segment
            labelled.speaker = speaker(start: segment.start, end: segment.end, turns: turns) ?? segment.speaker
            return labelled
        }
    }

    // MARK: Offline clusters

    /// `offline` turns (cluster ids) as turns of persons: each cluster becomes the person of `existing` turns
    /// (person ids) it overlaps most, or a new person added to `directory` when none overlaps.
    public static func mapOffline(
        _ offline: [SpeakerTurn], onto existing: [SpeakerTurn], directory: inout SpeakerDirectory
    ) -> [SpeakerTurn] {
        var mapping: [String: PersonID] = [:]
        for cluster in Array(Set(offline.map(\.speaker))).sorted() {
            var overlap: [PersonID: TimeInterval] = [:]
            for turn in offline where turn.speaker == cluster {
                for known in existing {
                    let shared = min(turn.end, known.end) - max(turn.start, known.start)
                    if shared > 0 { overlap[known.speaker, default: 0] += shared }
                }
            }
            if let best = overlap.max(by: { ($0.value, $1.key) < ($1.value, $0.key) })?.key, directory.speakers[best] != nil {
                mapping[cluster] = best
            }
        }
        // New persons in order of first appearance, so ids follow the conversation.
        var result: [SpeakerTurn] = []
        for turn in offline.sorted(by: { $0.start < $1.start }) {
            if mapping[turn.speaker] == nil { mapping[turn.speaker] = directory.add() }
        }
        for turn in offline {
            var mapped = turn
            mapped.speaker = mapping[turn.speaker] ?? turn.speaker
            result.append(mapped)
        }
        return result
    }
}
