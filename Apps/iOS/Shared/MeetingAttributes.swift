
#if APP_TARGET
import LegatoKeyboardCore
#endif
import ActivityKit
import AppIntents
import Foundation

struct MeetingAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        enum Phase: String, Codable, Hashable { case starting, recording, stopping, interrupted }
        var phase: Phase
        var tail: String
    }
    var startedAt: Date
    static let openURL = URL(string: "\(RuntimeIdentity.current.urlScheme)://meetings")!
}

/// Stop-only: stale activities must never start another recording.
struct StopMeetingIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Stop meeting"
    static let isDiscoverable = false
    @MainActor func perform() async throws -> some IntentResult {
        #if APP_TARGET
        await AppController.shared.meetings.stop()
        #else
        throw ToggleDictationError.appRequired
        #endif
        return .result()
    }
}
