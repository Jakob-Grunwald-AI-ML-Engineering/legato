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
    /// `.live`: the `n` of the newest `HostState.revision` handled (applied, skipped or dropped; never retried).
    public var revisionHandled: Int = 0
    /// `.live`: a revision was skipped because the field no longer ended with what it showed for the run (the
    /// user edited it): the field is the user's, later revisions are skipped too, and the final text is not
    /// confirmed. A sent boundary starts afresh.
    public var revisionSkipped: Bool = false
    /// `.live`: the `n` of the revision the field shows (0: none, raw text).
    public var shownRevision: Int = 0
    /// `.live`: the field shows `revisedText` for `committed` from `sentBase` to `revisedEnd`, then the raw
    /// text up to `committedCount`.
    public var revisedEnd: Int = 0
    public var revisedText: String = ""
    /// `.live`: where the last sent boundary is in `committed` (0: none). The field was cleared (a message
    /// sent) when it showed the run's text up to here; the app is told so through this cursor.
    public var sentBase: Int = 0
    /// `.live`: the revision the field showed at that boundary (0: raw text).
    public var sentShownRevision: Int = 0
    /// `.live`: the tentative text the field showed after the committed text when it was cleared: it went with
    /// the message. Until the committed text after `sentBase` shows where it ends (`SentTentative`), nothing of
    /// the run is typed; then the boundary moves past it and this is emptied.
    public var sentTentative: String = ""
    /// `.live`: how many sent boundaries the run had; the app hears of each one once.
    public var sentCount: Int = 0

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

    private enum CodingKeys: String, CodingKey {
        case runID, documentID, committedCount, volatile, needsSeparator, finalApplied, finalReplaced
        case revisionHandled, revisionSkipped, shownRevision, revisedEnd, revisedText, sentBase, sentShownRevision
        case sentTentative, sentCount
    }

    /// A cursor saved before a field existed decodes with its default.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        runID = try c.decode(String.self, forKey: .runID)
        documentID = try c.decode(String.self, forKey: .documentID)
        committedCount = try c.decode(Int.self, forKey: .committedCount)
        volatile = try c.decode(String.self, forKey: .volatile)
        needsSeparator = try c.decode(Bool.self, forKey: .needsSeparator)
        finalApplied = try c.decode(Bool.self, forKey: .finalApplied)
        finalReplaced = try c.decodeIfPresent(Bool.self, forKey: .finalReplaced)
        revisionHandled = try c.decodeIfPresent(Int.self, forKey: .revisionHandled) ?? 0
        revisionSkipped = try c.decodeIfPresent(Bool.self, forKey: .revisionSkipped) ?? false
        shownRevision = try c.decodeIfPresent(Int.self, forKey: .shownRevision) ?? 0
        revisedEnd = try c.decodeIfPresent(Int.self, forKey: .revisedEnd) ?? 0
        revisedText = try c.decodeIfPresent(String.self, forKey: .revisedText) ?? ""
        sentBase = try c.decodeIfPresent(Int.self, forKey: .sentBase) ?? 0
        sentShownRevision = try c.decodeIfPresent(Int.self, forKey: .sentShownRevision) ?? 0
        sentTentative = try c.decodeIfPresent(String.self, forKey: .sentTentative) ?? ""
        sentCount = try c.decodeIfPresent(Int.self, forKey: .sentCount) ?? 0
    }
}
