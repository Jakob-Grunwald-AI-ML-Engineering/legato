import Foundation

/// Finds meetings the app died in the middle of.
public enum MeetingRecovery {
    /// Marks every meeting still `recording` as `interrupted` (its duration becomes the end of its last
    /// saved segment, if later) and returns their ids: the meetings that need the after-stop chain (m4a,
    /// post-pass, speakers, and the summary when it is automatic), which the caller queues. Meetings in any
    /// other state are left alone, so a second run returns nothing.
    ///
    /// - Parameter excluding: meetings a live session owns right now; they are `recording` for a good reason
    ///   and are not touched.
    public static func run(store: MeetingStore, excluding live: Set<UUID> = []) async throws -> [UUID] {
        var queued: [UUID] = []
        for meeting in try await store.meetings() where meeting.state == .recording && !live.contains(meeting.id) {
            let lastEnd = try await store.segments(for: meeting.id).map(\.end).max() ?? 0
            try await store.update(id: meeting.id) { m in
                m.duration = max(m.duration, lastEnd)
                m.state = .interrupted
            }
            queued.append(meeting.id)
        }
        return queued
    }
}
