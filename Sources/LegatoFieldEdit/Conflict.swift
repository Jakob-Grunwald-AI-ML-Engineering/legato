import Foundation

/// Why an edit was handed back to its source instead of being written.
public struct Conflict: Sendable, Hashable, Codable {
    public enum Reason: String, Sendable, Hashable, Codable {
        /// A landed step replaced text the edit's range touches.
        case overlap
        /// The edit touches owned text the user changed.
        case ownerTainted
        /// The field does not hold the edit's expected text.
        case expectMismatch
        /// The write was issued but the next host read does not show it.
        case verifyFailed
        /// The field lost focus or was replaced.
        case focusLost
        /// The edit's range is not in the current window, or its base is not a version this queue can map from
        /// (another queue instance, pruned history, a write that was rolled back, a version not reached yet).
        case outOfWindow
        /// The executor could not write (Mac AX fault); the write was aborted before it ran.
        case writeFailed
        /// The executor could not read the field to check or verify the write.
        case unreadable
    }

    public var reason: Reason
    /// The landed step that caused it, when there is one.
    public var intervening: EditStep?
    public var byUser: Bool
    /// For the source (the agent's prompt): set when the user caused the conflict.
    public var note: String?

    public init(_ reason: Reason, intervening: EditStep? = nil, byUser: Bool = false) {
        self.reason = reason
        self.intervening = intervening
        self.byUser = byUser
        note = byUser ? Self.userNote : nil
    }

    public static let userNote = "The user changed this text; treat their wording as final and do not edit it again."
}

/// What happened to a submitted transaction.
public enum QueueEvent: Sendable, Hashable {
    /// Written and confirmed by a host read.
    case applied(UUID, version: FieldVersion)
    /// Overtaken by the same owner's own newer edit; the source re-plans (no user note).
    case superseded(UUID, by: UUID)
    case conflict(UUID, Conflict)
}
