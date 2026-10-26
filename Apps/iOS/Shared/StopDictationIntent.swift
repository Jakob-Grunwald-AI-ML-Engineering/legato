import AppIntents
import Foundation

/// The Live Activity's Stop button: ends the running dictation and does nothing otherwise. Unlike
/// `ToggleDictationIntent` it can never start one, so a tap on a stale or already finished activity is
/// harmless.
///
/// `LiveActivityIntent` makes `perform()` run in the app process, never in the widget process that
/// triggered it. Not an `AudioRecordingIntent`: it records nothing. This file compiles into the app and the
/// widget extension; the app-only part sits inside `#if APP_TARGET`, and the widget copy refuses to run.
struct StopDictationIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Stop dictation"
    static let description = IntentDescription("Stops the running dictation. Does nothing when none is running.")
    static let isDiscoverable = false

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult {
        #if APP_TARGET
        await AppController.shared.stopIfRunning()
        #else
        guard Self.runsInApp else { throw ToggleDictationError.appRequired }
        #endif
        return .result()
    }

    private static var runsInApp: Bool {
        #if APP_TARGET
        true
        #else
        false
        #endif
    }
}
