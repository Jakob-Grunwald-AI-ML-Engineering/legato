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

    public init(
        stream: Stream = .mic, text: String, isFinal: Bool, range: Range<TimeInterval>? = nil, speaker: String? = nil,
        isGap: Bool = false
    ) {
        self.stream = stream
        self.text = text
        self.isFinal = isFinal
        self.range = range
        self.speaker = speaker
        self.isGap = isGap
    }
}
