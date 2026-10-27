import ActivityKit
import Foundation

/// The Live Activity of a recording meeting. Compiled into the app and the widget extension, so it must not
/// import LegatoKit.
struct MeetingActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable, Sendable {
        enum Phase: String, Codable, Hashable, Sendable {
            case recording
            /// The user muted the microphone: silence is recorded.
            case muted
            /// A call or another app has the microphone; the meeting resumes when it is free.
            case interrupted
            /// Stopped; the recording is being saved.
            case saving
        }

        /// When the meeting began; the activity counts up from it.
        var startedAt: Date
        var phase: Phase
    }

    /// Tapping the activity opens the Meetings screen.
    static let openURL = URL(string: "legato://meetings")!
}
