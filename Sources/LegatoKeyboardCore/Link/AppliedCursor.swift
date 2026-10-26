import Foundation

/// What the keyboard has put into the field for the current run (`link.applied`). The keyboard
/// persists it, so a restarted keyboard process continues instead of typing the run again, and the
/// app reads `finalApplied` to decide whether the clipboard is still needed.
public struct AppliedCursor: Codable, Sendable, Equatable {
    public var runID: String
    /// The `documentIdentifier` of the field this run is bound to.
    public var documentID: String
    /// How many characters of `HostState.committed` are in the field.
    public var committedCount: Int
    /// The tentative text currently in the field after the committed part (a leading separator
    /// included), exactly as inserted.
    public var volatile: String
    /// The next insert needs a space in front unless the field already ends in whitespace (set after
    /// the user typed into the run's text).
    public var needsSeparator: Bool
    /// The run's final text is in the field.
    public var finalApplied: Bool
    /// Whether the streamed text was swapped for the host's `finalText` (`HostDelivery.replace`): true once
    /// swapped, false when the field no longer ended with it (never retried), nil when no swap was due.
    public var finalReplaced: Bool?

    public init(
        runID: String, documentID: String, committedCount: Int = 0, volatile: String = "",
        needsSeparator: Bool = false, finalApplied: Bool = false
    ) {
        self.runID = runID
        self.documentID = documentID
        self.committedCount = committedCount
        self.volatile = volatile
        self.needsSeparator = needsSeparator
        self.finalApplied = finalApplied
    }
}
