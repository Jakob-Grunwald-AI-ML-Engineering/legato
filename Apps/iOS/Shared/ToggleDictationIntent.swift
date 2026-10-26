import AppIntents
import Foundation

/// The one dictation action: starts a dictation, or stops the running one. Used by the Action Button
/// (App Shortcut), the Control Center control and the Live Activity stop button.
///
/// `AudioRecordingIntent` makes the system treat it as a recording start that must show a Live
/// Activity. `LiveActivityIntent` makes `perform()` run in the app process, never in the widget
/// process that triggered it. `.foreground(.dynamic)` lets `perform()` ask for the foreground, which it
/// does in two cases: onboarding is needed, or a start would have to record next to other audio (or the
/// system refused a background start). iOS only allows that from the foreground, so the intent brings
/// the app forward and starts there, ducking the other audio. Otherwise a dictation never leaves the
/// background.
///
/// Returns a `DictationState`, so a Shortcut can branch on it. The Action Button, the control and the
/// Live Activity ignore it.
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
    func perform() async throws -> some IntentResult & ReturnsValue<DictationState> {
        guard Self.runsInApp else { throw ToggleDictationError.appRequired }
        var state = DictationState.failed
        #if APP_TARGET
        var outcome = await AppController.shared.toggle()
        if case .needsForeground(let reason) = outcome {
            // Other audio plays, or the system refused a background start: nothing was started and
            // nothing is left behind. Come to the foreground and press again, once.
            guard systemContext.currentMode.canContinueInForeground else {
                throw ToggleDictationError.foregroundRequired
            }
            try await continueInForeground(alwaysConfirm: false)
            outcome = await AppController.shared.toggle(afterForegroundHop: reason)
        }
        switch outcome {
        case .needsOnboarding:
            // The other foreground hop: something must be set up first.
            guard systemContext.currentMode.canContinueInForeground else {
                throw ToggleDictationError.setupRequired
            }
            try await continueInForeground(alwaysConfirm: false)
            state = .needsSetup
        case .needsForeground: state = .failed // still refused after the hop; no second hop
        case .started: state = .started
        case .stopped: state = .stopped
        case .failed: state = .failed
        case .busy: state = .busy
        }
        #endif
        return .result(value: state)
    }
}

/// What a press did, as a Shortcuts value: "If Dictation State is Stopped".
enum DictationState: String, AppEnum {
    /// Listening now; the next press stops.
    case started
    /// The run is over (text copied, or nothing was recognized, or a start was cancelled).
    case stopped
    /// Not started: Legato needs setup (permission, Live Activities or the speech model).
    case needsSetup
    /// The start failed.
    case failed
    /// A stop was already wrapping up; this press did nothing.
    case busy

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Dictation State")
    static let caseDisplayRepresentations: [DictationState: DisplayRepresentation] = [
        .started: "Started",
        .stopped: "Stopped",
        .needsSetup: "Needs setup",
        .failed: "Failed",
        .busy: "Busy",
    ]
}

enum ToggleDictationError: Error, CustomLocalizedStringResourceConvertible {
    /// `perform()` ran outside the app process (the widget copy of this file).
    case appRequired
    /// Dictation can't start until the user finishes setup in the app, and the app can't be opened here.
    case setupRequired
    /// Dictation can't start next to other audio from the background, and the app can't be brought forward here.
    case foregroundRequired

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .appRequired: "Legato must run in the app."
        case .setupRequired: "Open Legato to finish setup."
        case .foregroundRequired: "Open Legato to dictate while audio is playing."
        }
    }
}
