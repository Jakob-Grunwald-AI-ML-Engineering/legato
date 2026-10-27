import Foundation

/// One thing the user is told about: a start that failed, what a recording is doing without a model, what a
/// processing step skipped.
public struct MeetingNotice: Sendable, Equatable, Identifiable {
    /// Why a notice exists, which decides when it goes away.
    public enum Kind: Sendable, Equatable {
        /// A start that failed or was cancelled; gone when the next start begins.
        case start
        /// About the recording as it runs (the mic is raw, speakers are downloading); gone when the recording ends.
        case live
        /// What the heavy steps skipped or failed; replaced by the next run's.
        case processing
        /// The result of something the user asked for (Regenerate, Claude, export).
        case action
    }

    public let id: Int
    public let kind: Kind
    /// The meeting it is about; nil for one about the app (a start that failed has no meeting).
    public let meetingID: UUID?
    public let text: String
}

/// The notices of the Meetings window, per meeting, each dismissible and removed when it stops being true.
public struct MeetingNotices: Sendable, Equatable {
    public private(set) var all: [MeetingNotice] = []
    private var nextID = 0

    public init() {}

    /// Adds a notice unless the same text is already there for that meeting and kind.
    public mutating func post(_ text: String, kind: MeetingNotice.Kind, meeting: UUID?) {
        guard !all.contains(where: { $0.kind == kind && $0.meetingID == meeting && $0.text == text }) else { return }
        all.append(MeetingNotice(id: nextID, kind: kind, meetingID: meeting, text: text))
        nextID += 1
    }

    /// Replaces every notice of `kind` for that meeting by `texts` (none clears them): what was true last time is not
    /// necessarily true now.
    public mutating func set(_ texts: [String], kind: MeetingNotice.Kind, meeting: UUID?) {
        clear(kind: kind, meeting: meeting)
        for text in texts { post(text, kind: kind, meeting: meeting) }
    }

    public mutating func dismiss(_ id: Int) { all.removeAll { $0.id == id } }

    public mutating func clear(kind: MeetingNotice.Kind, meeting: UUID?) {
        all.removeAll { $0.kind == kind && $0.meetingID == meeting }
    }

    /// Takes back one notice by its text, for one that is true only for a while (the mic could not restart).
    public mutating func remove(text: String, kind: MeetingNotice.Kind, meeting: UUID?) {
        all.removeAll { $0.kind == kind && $0.meetingID == meeting && $0.text == text }
    }

    /// A meeting went away: so did what was said about it.
    public mutating func removeMeeting(_ id: UUID) { all.removeAll { $0.meetingID == id } }

    /// The notices about one meeting, oldest first.
    public func notices(for meeting: UUID) -> [MeetingNotice] { all.filter { $0.meetingID == meeting } }

    /// The notices about the app itself (no meeting), oldest first.
    public var global: [MeetingNotice] { all.filter { $0.meetingID == nil } }

    public var latestGlobal: MeetingNotice? { global.last }
}
