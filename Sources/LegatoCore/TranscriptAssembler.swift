import Foundation

public struct TranscriptEvent: Sendable, Equatable {
    /// Where the audio came from. `.mixed` is the sum of a meeting's sources, which the one live engine hears.
    public enum Stream: String, Sendable, Equatable, Codable { case mic, system, mixed }

    public var stream: Stream
    public var text: String
    public var isFinal: Bool
    /// Time range in the audio, in seconds, when the engine provides one.
    public var range: Range<TimeInterval>?

    public init(stream: Stream = .mic, text: String, isFinal: Bool, range: Range<TimeInterval>? = nil) {
        self.stream = stream
        self.text = text
        self.isFinal = isFinal
        self.range = range
    }
}

/// Instructions for a text sink (Accessibility streaming, `textDocumentProxy`) — no diffing needed.
public enum TranscriptEdit: Sendable, Equatable {
    /// Append `delta` permanently.
    case commit(delta: String)
    /// Replace the currently shown volatile (tentative) text; empty string clears it.
    case replaceVolatile(String)
    /// Replace an earlier committed span with its cleaned text (live cleanup). Positions are in the raw
    /// committed text, which itself never changes.
    case revise(TranscriptRevision)
}

/// A committed span replaced after the fact: live cleanup swaps a segment's raw text for its cleaned text.
///
/// Revisions of a run never overlap and arrive in order of `start`. Positions count characters of the
/// run's raw committed text (everything the `.commit` edits appended), so they stay valid however many
/// revisions came before.
public struct TranscriptRevision: Sendable, Equatable, Codable {
    /// Where the span starts in the raw committed text, in characters.
    public var start: Int
    /// The span's raw text, as it was committed (one segment, or at the stop the segments still raw).
    public var raw: String
    /// What replaces it: the cleaned text, with the raw span's leading and trailing whitespace kept.
    public var text: String

    public init(start: Int, raw: String, text: String) {
        self.start = start
        self.raw = raw
        self.text = text
    }

    /// Where the span ends in the raw committed text.
    public var end: Int { start + raw.count }

    /// The revision of `raw` at `start` to `cleaned` (trimmed), keeping `raw`'s surrounding whitespace.
    public static func cleaning(_ raw: String, at start: Int, to cleaned: String) -> TranscriptRevision {
        let lead = String(raw.prefix(while: \.isWhitespace))
        let trail = String(raw.reversed().prefix(while: \.isWhitespace).reversed())
        return TranscriptRevision(start: start, raw: raw, text: lead + cleaned + trail)
    }
}

public struct TranscriptAssembler: Sendable {
    public private(set) var committedText = ""
    public private(set) var volatileText = ""

    public init() {}

    /// Volatile results replace the current volatile text. A final clears the volatile text
    /// (`replaceVolatile("")`, only if one was shown) and commits its text.
    public mutating func apply(_ event: TranscriptEvent) -> [TranscriptEdit] {
        var edits: [TranscriptEdit] = []
        if event.isFinal {
            if !volatileText.isEmpty {
                volatileText = ""
                edits.append(.replaceVolatile(""))
            }
            if !event.text.isEmpty {
                committedText += event.text
                edits.append(.commit(delta: event.text))
            }
        } else if event.text != volatileText {
            volatileText = event.text
            edits.append(.replaceVolatile(event.text))
        }
        return edits
    }
}
