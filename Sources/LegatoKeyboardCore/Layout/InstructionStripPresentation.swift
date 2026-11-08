import Foundation

/// What the word row shows while instruction mode has something to say (`InstructionStrip`, the walk of the field, the
/// magic key being on): one line of text and the buttons that go with it. nil: the row shows words.
public struct InstructionStripPresentation: Equatable, Sendable {
    public enum Kind: String, Sendable, Equatable {
        /// The key is on: the live instruction transcript.
        case listening
        /// The keyboard walks the field.
        case reading
        /// The model works on the instruction.
        case running
        /// The result is in the field: Accept and Undo.
        case result
        case undone
        /// Nothing changed: the message, Retry, and Undo when the field may hold a partial edit.
        case failed
    }

    public var kind: Kind
    /// The row's line: the transcript while listening, else a short status. Live text keeps its end in view.
    public var text: String
    public var showsAccept: Bool
    public var showsUndo: Bool
    public var showsRetry: Bool

    public init(kind: Kind, text: String, showsAccept: Bool = false, showsUndo: Bool = false, showsRetry: Bool = false) {
        self.kind = kind; self.text = text; self.showsAccept = showsAccept; self.showsUndo = showsUndo; self.showsRetry = showsRetry
    }

    /// Whether `text` is words being spoken (its end matters) rather than a status line.
    public var isTranscript: Bool { kind == .listening && !text.isEmpty && text != Self.listeningPrompt }

    public static let listeningPrompt = "Say what to change…"
    public static let readingText = "Reading the text…"

    /// The row for the app's strip, the keyboard's own walk and the key's state; nil when none has anything to show.
    public init?(strip: InstructionStrip?, isReadingField: Bool, magic: MagicToggle) {
        if isReadingField { self.init(kind: .reading, text: Self.readingText); return }
        let transcript = strip?.transcript.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let message = strip?.message?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        switch strip?.phase ?? .idle {
        case .idle:
            guard magic.isOn else { return nil }
            self.init(kind: .listening, text: Self.listeningPrompt)
        case .listening:
            self.init(kind: .listening, text: transcript.isEmpty ? Self.listeningPrompt : transcript)
        case .reading:
            self.init(kind: .reading, text: Self.readingText)
        case .running:
            self.init(kind: .running, text: message ?? "Working on it…")
        case .result:
            self.init(kind: .result, text: message ?? "Done.", showsAccept: true, showsUndo: strip?.canUndo ?? false)
        case .undone:
            self.init(kind: .undone, text: message ?? "Undone.")
        case .failed:
            self.init(kind: .failed, text: message ?? "That didn't work.", showsUndo: strip?.canUndo ?? false, showsRetry: true)
        }
    }

    /// The intent a keystroke sends for what the row shows: the result is kept (`accept`), a failure is let go
    /// (`dismiss`); nothing for a row that is still working.
    public var keystrokeAction: InstructionIntent.Action? {
        switch kind {
        case .result, .undone: .accept
        case .failed: .dismiss
        case .listening, .reading, .running: nil
        }
    }

    /// What VoiceOver reads for the row's text.
    public var spokenText: String {
        switch kind {
        case .listening: isTranscript ? "Instruction: \(text)" : "Listening for an instruction"
        case .reading, .running, .result, .undone, .failed: text
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
