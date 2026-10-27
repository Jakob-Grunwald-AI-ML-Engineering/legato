import Foundation

/// How a cleaned-up transcript reaches a text field that the raw text was streamed into while it was spoken.
public enum CleanupDelivery: String, Sendable, Equatable, CaseIterable, Codable {
    /// Swap the streamed text for the cleaned text in one edit; when the field no longer ends with the
    /// streamed text, leave it and put the cleaned text on the clipboard.
    case replace
    /// The field keeps the streamed text; the cleaned text goes to the clipboard.
    case clipboard
    /// Nothing streams into the field while listening; the cleaned text is inserted when the run ends.
    case hold
    /// Rolling cleanup while speaking: after each finished phrase the whole dictated text so far is cleaned
    /// again from the raw text (so a later "no wait, Thursday" can fix an earlier phrase) and replaces what
    /// the field shows for the run, while the field still ends with it; a final pass runs at the end. Once
    /// the user edits the run's text it stays as it is (the cleaned text goes to the clipboard); a cleared
    /// field (a sent message) closes the text before it.
    case live

    /// Whether the text streams into the field while it is spoken.
    public var streamsIntoField: Bool { self != .hold }
}
