import Foundation

public struct TranscriptEvent: Sendable, Equatable {
    /// Where the audio came from. `.mixed` is the sum of a meeting's sources, which the one live engine hears.
    public enum Stream: String, Sendable, Equatable, Codable { case mic, system, mixed }

    public var stream: Stream
    public var text: String
    public var isFinal: Bool
    /// Time range in the audio, in seconds, when the engine provides one.
    public var range: Range<TimeInterval>?
    /// Who spoke, when the engine tells speakers apart (a meeting). Labels are the engine's own and only mean
    /// something within one connection; nil for engines that do not.
    public var speaker: String?
    /// The engine heard nothing in `range`: its connection was down. `text` is empty.
    public var isGap: Bool
    /// The words of a final event with their times, when the engine gives them (a meeting); nil otherwise.
    public var words: [TranscriptWord]?

    public init(
        stream: Stream = .mic, text: String, isFinal: Bool, range: Range<TimeInterval>? = nil, speaker: String? = nil,
        isGap: Bool = false, words: [TranscriptWord]? = nil
    ) {
        self.stream = stream
        self.text = text
        self.isFinal = isFinal
        self.range = range
        self.speaker = speaker
        self.isGap = isGap
        self.words = words
    }
}

/// One word of a transcript and when it was spoken, in seconds on the timeline of its transcript (a meeting's: from
/// the meeting's start).
public struct TranscriptWord: Sendable, Equatable, Codable {
    public var text: String
    public var start: TimeInterval
    public var end: TimeInterval

    public init(text: String, start: TimeInterval, end: TimeInterval) {
        self.text = text
        self.start = start
        self.end = end
    }

    /// Words placed on a timeline from times relative to their stream (Soniox's `t0`/`t1`), where `origin` is the
    /// timeline time of the first word's start. Nil when the counts differ or any word has no time: a segment's words
    /// are timed all or none.
    public static func placed(
        _ texts: [String], relative times: [(start: TimeInterval?, end: TimeInterval?)], origin: TimeInterval
    ) -> [TranscriptWord]? {
        guard !texts.isEmpty, texts.count == times.count, let first = times[0].start else { return nil }
        var words: [TranscriptWord] = []
        words.reserveCapacity(texts.count)
        for (text, time) in zip(texts, times) {
            guard let start = time.start, let end = time.end else { return nil }
            words.append(TranscriptWord(text: text, start: origin - first + start, end: origin - first + max(start, end)))
        }
        return words
    }
}
