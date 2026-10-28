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
            /// The text waits for the Insert and Copy buttons.
            case result
            /// Terminal: the text was typed into the Legato keyboard's field.
            case inserted
            /// An Insert found no Legato keyboard acting; the buttons stay.
            case insertFailed
            /// Terminal: the text is on the clipboard.
            case copied
            /// Terminal: tapping the activity opens the app, which copies the last transcript.
            case tapToCopy
            /// Terminal: nothing usable came out of the run.
            case failed

            var isRunning: Bool { self == .starting || self == .listening }
            /// The activity shows the Insert and Copy buttons (mirrors `DictationPhase.offersResultActions`).
            var offersResultActions: Bool { self == .result || self == .insertFailed }
        }

        var startedAt: Date
        /// The end of the text so far, sized for the activity.
        var tail: String
        var phase: Phase
    }

    /// Opened by tapping an activity in the `tapToCopy` phase; the app copies the last transcript.
    static let copyLastURL = URL(string: "\(RuntimeIdentity.current.urlScheme)://copy-last")!
}
