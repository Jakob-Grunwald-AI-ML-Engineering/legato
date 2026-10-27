import ActivityKit
import Foundation

/// The meeting's Live Activity: requested before the audio session activates (iOS wants one next to a
/// recording that keeps going in the background), updated when the meeting mutes or is interrupted, ended
/// when it stops. `Activity` is not safe to send between actors, so only its `id` is kept.
@MainActor
final class MeetingActivityClient {
    private var activityID: String?

    /// - Throws: when Live Activities are off or the system refuses; the meeting then records without one.
    func request(startedAt: Date) async throws {
        await Self.endAll() // a previous process may have been killed mid-meeting
        let state = MeetingActivityAttributes.ContentState(startedAt: startedAt, phase: .recording)
        let activity = try Activity.request(
            attributes: MeetingActivityAttributes(),
            content: ActivityContent(state: state, staleDate: nil),
            pushType: nil)
        activityID = activity.id
        #if DEBUG
        E2E.log("meeting.activity.request live=\(Activity<MeetingActivityAttributes>.activities.count)")
        #endif
    }

    func update(startedAt: Date, phase: MeetingActivityAttributes.ContentState.Phase) async {
        guard let id = activityID else { return }
        let state = MeetingActivityAttributes.ContentState(startedAt: startedAt, phase: phase)
        await Self.update(id: id, ActivityContent(state: state, staleDate: nil))
        #if DEBUG
        E2E.log("meeting.activity.update phase=\(phase.rawValue)")
        #endif
    }

    func end(startedAt: Date) async {
        guard let id = activityID else { return }
        activityID = nil
        let state = MeetingActivityAttributes.ContentState(startedAt: startedAt, phase: .saving)
        await Self.end(id: id, ActivityContent(state: state, staleDate: nil))
        #if DEBUG
        E2E.log("meeting.activity.end live=\(Activity<MeetingActivityAttributes>.activities.count)")
        #endif
    }

    nonisolated private static func endAll() async {
        for activity in Activity<MeetingActivityAttributes>.activities {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }

    nonisolated private static func update(id: String, _ content: ActivityContent<MeetingActivityAttributes.ContentState>) async {
        await Activity<MeetingActivityAttributes>.activities.first { $0.id == id }?.update(content)
    }

    nonisolated private static func end(id: String, _ content: ActivityContent<MeetingActivityAttributes.ContentState>) async {
        await Activity<MeetingActivityAttributes>.activities.first { $0.id == id }?.end(content, dismissalPolicy: .immediate)
    }
}
