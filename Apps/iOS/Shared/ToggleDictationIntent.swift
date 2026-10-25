import AppIntents
import Foundation

/// The one dictation action: starts a dictation, or stops the running one. Used by the Action Button
/// (App Shortcut), the Control Center control and the Live Activity stop button.
///
/// `AudioRecordingIntent` makes the system treat it as a recording start that must show a Live
/// Activity. `LiveActivityIntent` makes `perform()` run in the app process, never in the widget
/// process that triggered it. `.foreground(.dynamic)` lets `perform()` ask for the foreground, which it
/// does only when onboarding is needed; a successful dictation never leaves the background.
///
/// This file compiles into the app and the widget extension. Everything that touches LegatoKit sits
/// inside `#if APP_TARGET`; the widget copy refuses to run.
struct ToggleDictationIntent: AudioRecordingIntent, LiveActivityIntent {
    static let title: LocalizedStringResource = "Toggle dictation"
    static let description = IntentDescription("Starts dictation, or stops it when already running.")
    static var supportedModes: IntentModes { [.background, .foreground(.dynamic)] }

    init() {}

    private static var runsInApp: Bool {
        #if APP_TARGET
        true
        #else
        false
        #endif
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        guard Self.runsInApp else { throw ToggleDictationError.appRequired }
        #if APP_TARGET
        switch await AppController.shared.toggle() {
        case .needsOnboarding:
            // The only foreground hop, and only on the error path: something must be set up first.
            guard systemContext.currentMode.canContinueInForeground else {
                throw ToggleDictationError.setupRequired
            }
            try await continueInForeground(alwaysConfirm: false)
        case .started, .stopped, .failed, .busy:
            break
        }
        #endif
        return .result()
    }
}

enum ToggleDictationError: Error, CustomLocalizedStringResourceConvertible {
    /// `perform()` ran outside the app process (the widget copy of this file).
    case appRequired
    /// Dictation can't start until the user finishes setup in the app, and the app can't be opened here.
    case setupRequired

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .appRequired: "Legato must run in the app."
        case .setupRequired: "Open Legato to finish setup."
        }
    }
}
