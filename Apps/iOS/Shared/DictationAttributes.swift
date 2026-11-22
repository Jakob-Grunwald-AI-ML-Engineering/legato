#if APP_TARGET
import LegatoKeyboardCore
#endif
import ActivityKit
import Foundation

/// The Live Activity of one dictation. Compiled into the app and the widget extension, so it must not
/// import LegatoKit: `ContentState` mirrors LegatoCore's `DictationActivityContent`, and the app maps
/// between the two (`ActivityKitClient`).
struct DictationAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable, Sendable {
        /// Mirrors `DictationPhase` (same raw values).
        enum Phase: String, Codable, Hashable, Sendable {
            case starting, listening, finishing
            /// The app only holds the microphone; no take runs.
            case held
            /// Capture is being restored; the microphone is not ready yet.
            case recovering
            var isRunning: Bool { self == .starting || self == .listening }
        }

        var startedAt: Date
        /// The end of the text so far, sized for the activity.
        var tail: String
        var phase: Phase
    }

    /// Associates controls with the microphone hold that created them. Optional for activities from earlier builds.
    var holdID: String?
}
