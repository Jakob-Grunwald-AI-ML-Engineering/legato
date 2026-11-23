import ActivityKit
import Foundation
import LegatoCore

extension DictationAttributes.ContentState {
    init(_ content: DictationActivityContent) {
        self.init(
            startedAt: content.startedAt,
            tail: content.tail,
            phase: Phase(rawValue: content.phase.rawValue) ?? .held)
    }
}

/// Owns the system activity and its state observation for the current keyboard microphone hold.
@MainActor
final class ActivityKitClient {
    private var activityID: String?
    private var dismissalObserver: Task<Void, Never>?

    func request(
        _ content: DictationActivityContent, holdID: String, onDismissal: @escaping @MainActor () async -> Void
    ) async throws {
        // A previous process may have been killed mid-run; don't leave its activity behind.
        await Self.endAll()
        let activity: Activity<DictationAttributes>
        do {
            activity = try Activity.request(
                attributes: DictationAttributes(holdID: holdID),
                content: ActivityContent(state: .init(content), staleDate: nil),
                pushType: nil)
        } catch {
            #if DEBUG
            E2E.log("activity.request.failed error=\(E2E.quote(String(describing: error)))")
            #endif
            throw error
        }
        activityID = activity.id
        dismissalObserver = Task { [weak self] in
            let states = activity.activityStateUpdates
            if activity.activityState != .dismissed {
                for await state in states where state == .dismissed { break }
            }
            guard !Task.isCancelled, self?.activityID == activity.id, activity.activityState == .dismissed else { return }
            await onDismissal()
        }
        #if DEBUG
        E2E.log("activity.request phase=\(content.phase.rawValue) tail=\(E2E.quote(content.tail)) live=\(Activity<DictationAttributes>.activities.count)")
        #endif
    }

    func update(_ content: DictationActivityContent, staleDate: Date?) async {
        guard let id = activityID else { return }
        await Self.update(id: id, ActivityContent(state: .init(content), staleDate: staleDate))
        #if DEBUG
        E2E.log("activity.update phase=\(content.phase.rawValue) tail=\(E2E.quote(content.tail)) stale=\(staleDate != nil)")
        #endif
    }

    func dismiss() async {
        guard let id = activityID else { return }
        activityID = nil
        dismissalObserver?.cancel()
        dismissalObserver = nil
        await Self.dismiss(id: id)
        #if DEBUG
        E2E.log("activity.dismiss live=\(Activity<DictationAttributes>.activities.count)")
        #endif
    }

    /// The recording intent continues to own the activity that invoked it.
    func transfer() -> Activity<DictationAttributes>? {
        guard let activityID, let activity = Activity<DictationAttributes>.activities.first(where: {
            $0.id == activityID && $0.activityState == .active
        }) else { return nil }
        dismissalObserver?.cancel()
        dismissalObserver = nil
        self.activityID = nil
        return activity
    }

    nonisolated private static func dismiss(id: String) async {
        await Activity<DictationAttributes>.activities.first { $0.id == id }?.end(nil, dismissalPolicy: .immediate)
    }

    nonisolated private static func endAll() async {
        for activity in Activity<DictationAttributes>.activities {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }

    nonisolated private static func update(id: String, _ content: ActivityContent<DictationAttributes.ContentState>) async {
        await Activity<DictationAttributes>.activities.first { $0.id == id }?.update(content)
    }
}
