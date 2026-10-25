import ActivityKit
import Foundation
import LegatoCore

extension DictationAttributes.ContentState {
    init(_ content: DictationActivityContent) {
        self.init(
            startedAt: content.startedAt,
            tail: content.tail,
            phase: Phase(rawValue: content.phase.rawValue) ?? .failed)
    }
}

/// The Live Activity port. `Activity` is not safe to send between actors, so only its `id` is kept and
/// every call looks the activity up again inside the nonisolated helper that awaits it.
@MainActor
final class ActivityKitClient: ActivityClient {
    /// How long a finished activity stays on the Lock Screen. `tapToCopy` needs time to be tapped.
    private static let dismissAfter: TimeInterval = 8
    private static let tapToCopyDismissAfter: TimeInterval = 30

    private var activityID: String?

    func request(_ content: DictationActivityContent) async throws {
        // A previous process may have been killed mid-run; don't leave its activity behind.
        await Self.endAll()
        let activity: Activity<DictationAttributes>
        do {
            activity = try Activity.request(
                attributes: DictationAttributes(),
                content: ActivityContent(state: .init(content), staleDate: nil),
                pushType: nil)
        } catch {
            #if DEBUG
            E2E.log("activity.request.failed error=\(E2E.quote(String(describing: error)))")
            #endif
            throw error
        }
        activityID = activity.id
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

    func end(_ content: DictationActivityContent) async {
        guard let id = activityID else { return }
        activityID = nil
        let after = content.phase == .tapToCopy ? Self.tapToCopyDismissAfter : Self.dismissAfter
        await Self.end(
            id: id,
            ActivityContent(state: .init(content), staleDate: nil),
            dismissAt: Date().addingTimeInterval(after))
        #if DEBUG
        E2E.log("activity.end phase=\(content.phase.rawValue) tail=\(E2E.quote(content.tail))")
        #endif
    }

    nonisolated private static func endAll() async {
        for activity in Activity<DictationAttributes>.activities {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }

    nonisolated private static func update(id: String, _ content: ActivityContent<DictationAttributes.ContentState>) async {
        await Activity<DictationAttributes>.activities.first { $0.id == id }?.update(content)
    }

    nonisolated private static func end(
        id: String, _ content: ActivityContent<DictationAttributes.ContentState>, dismissAt: Date
    ) async {
        await Activity<DictationAttributes>.activities.first { $0.id == id }?
            .end(content, dismissalPolicy: .after(dismissAt))
    }
}
