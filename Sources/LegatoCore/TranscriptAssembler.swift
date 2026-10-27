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
    /// Live cleanup's newest cleaned version of the run's text (`CleanupDelivery.live`): replaces what a
    /// client shows for the run from `start` on. The committed text itself never changes.
    case revise(TranscriptRevision)
}

/// Live cleanup's cleaned version of a run's dictated text: a whole-span replacement.
///
/// A rolling pass cleans the run's raw committed text from `start` (the segment base: 0, or where the last
/// sent boundary was) up to what was committed when the pass began (`raw`). A client that shows the run
/// replaces its current text for the run from `start` with `text` followed by the raw text committed after
/// `raw` (`end` on), and only while the field still ends with exactly what it shows for the run. A newer
/// revision (higher `n`) supersedes every earlier one; positions count characters of the raw committed text.
public struct TranscriptRevision: Sendable, Equatable, Codable {
    /// Counts the run's revisions from 1; a client applies only a revision newer than the one it showed.
    public var n: Int
    /// Where the cleaned span starts in the raw committed text, in characters (the segment base).
    public var start: Int
    /// The raw committed text the pass cleaned: from `start` up to what was committed when it began.
    public var raw: String
    /// What replaces it: the cleaned text, with the raw span's leading and trailing whitespace kept.
    public var text: String

    public init(n: Int, start: Int, raw: String, text: String) {
        self.n = n
        self.start = start
        self.raw = raw
        self.text = text
    }

    /// Where the span ends in the raw committed text: raw text from here on follows `text` as it is.
    public var end: Int { start + raw.count }

    /// The revision of `raw` at `start` to `cleaned` (trimmed), keeping `raw`'s surrounding whitespace.
    public static func cleaning(_ raw: String, n: Int, at start: Int, to cleaned: String) -> TranscriptRevision {
        TranscriptRevision(n: n, start: start, raw: raw, text: keepingWhitespace(of: raw, around: cleaned))
    }

    /// `cleaned` with `raw`'s leading and trailing whitespace.
    public static func keepingWhitespace(of raw: String, around cleaned: String) -> String {
        guard !raw.allSatisfy(\.isWhitespace) else { return raw }
        let lead = String(raw.prefix(while: \.isWhitespace))
        let trail = String(raw.reversed().prefix(while: \.isWhitespace).reversed())
        return lead + cleaned + trail
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
