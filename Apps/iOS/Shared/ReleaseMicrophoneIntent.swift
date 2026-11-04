import AppIntents
import Foundation

/// The held-microphone Live Activity's Release button: lets go of the background microphone.
///
/// A `LiveActivityIntent`, so `perform()` runs in the app process like `StopDictationIntent`; the widget copy
/// of this file refuses to run. Release is idempotent: a tap on a stale activity does nothing.
struct ReleaseMicrophoneIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Release microphone"
    static let description = IntentDescription("Stops Legato from holding the microphone in the background.")
    static let isDiscoverable = false

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult {
        #if APP_TARGET
        await AppController.shared.releaseMicrophone()
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
