import Foundation

public struct TranscriptEvent: Sendable, Equatable {
    public enum Stream: String, Sendable, Equatable, Codable { case mic, system }

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
