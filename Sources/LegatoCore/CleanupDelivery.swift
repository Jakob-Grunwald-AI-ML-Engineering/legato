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
    /// Each finished phrase (a final segment) is cleaned in the background while the next one is spoken, and
    /// replaces its raw text in the field while the field still shows it there; at the end only the phrases
    /// not cleaned yet are. A phrase the user typed around keeps its raw text.
    case live

    /// Whether the text streams into the field while it is spoken.
    public var streamsIntoField: Bool { self != .hold }
}
