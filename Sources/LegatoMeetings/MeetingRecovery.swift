import Foundation

/// Finds meetings the app died in the middle of.
public enum MeetingRecovery {
    /// Marks every meeting still `recording` as `interrupted` (its duration becomes the end of its last
    /// saved segment, if later) and returns their ids: the meetings that need the after-stop chain
    /// (post-pass, m4a, summary), which the caller queues. Meetings in any other state are left alone, so a
    /// second run returns nothing.
    public static func run(store: MeetingStore) async throws -> [UUID] {
        var queued: [UUID] = []
        for var meeting in try await store.meetings() where meeting.state == .recording {
            let lastEnd = try await store.segments(for: meeting.id).map(\.end).max() ?? 0
            meeting.duration = max(meeting.duration, lastEnd)
            meeting.state = .interrupted
            try await store.update(meeting)
            queued.append(meeting.id)
        }
        return queued
    }
}
