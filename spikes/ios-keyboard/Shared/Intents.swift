import ActivityKit
import AppIntents
import Foundation

struct SessionAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var startedAt: Date
    }
}

/// Starts the always-on mic session without opening the app.
/// Conforms to AudioRecordingIntent (the system treats it as a recording-starting intent that must
/// show a Live Activity) and LiveActivityIntent (runs perform() in the app process, never in the
/// widget/keyboard process that triggered it).
struct StartSessionIntent: AudioRecordingIntent, LiveActivityIntent {
    static let title: LocalizedStringResource = "Start Legato session"
    static let description = IntentDescription("Starts the mic session in the background, without opening the app.")
    static var supportedModes: IntentModes { .background }  // iOS 26 replacement for openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult {
        #if APP_TARGET
        SpikeLog.write("intent", "StartSessionIntent.perform() in app process")
        try await SessionController.shared.start(source: "StartSessionIntent")
        #else
        SpikeLog.write("intent", "StartSessionIntent.perform() ran in a NON-app process (unexpected)")
        #endif
        return .result()
    }
}

struct StopSessionIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Stop Legato session"
    static let description = IntentDescription("Stops the mic session.")
    static var supportedModes: IntentModes { .background }

    @MainActor
    func perform() async throws -> some IntentResult {
        #if APP_TARGET
        SpikeLog.write("intent", "StopSessionIntent.perform() in app process")
        await SessionController.shared.stop(reason: "StopSessionIntent")
        #else
        SpikeLog.write("intent", "StopSessionIntent.perform() ran in a NON-app process (unexpected)")
        #endif
        return .result()
    }
}
