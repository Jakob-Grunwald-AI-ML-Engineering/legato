import ActivityKit
import AppIntents
import Foundation

struct SessionAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var startedAt: Date
    }
}

/// The one action: first run starts audio session + Live Activity + engine + dictation, second run
/// stops them all and hands the audio session back to other apps.
///
/// AudioRecordingIntent: the system treats it as a recording-starting intent that must show a Live
/// Activity. LiveActivityIntent: perform() runs in the app process, never in the widget/keyboard
/// process that triggered it. `.foreground(.dynamic)` lets perform() ask for the app to come to the
/// foreground (`continueInForeground`) when no keyboard is there to receive the text.
struct ToggleDictationIntent: AudioRecordingIntent, LiveActivityIntent {
    static let title: LocalizedStringResource = "Toggle dictation"
    static let description = IntentDescription("Starts dictation, or stops it when already running.")
    static var supportedModes: IntentModes { [.background, .foreground(.dynamic)] }

    @Parameter(title: "Source", default: "action-button/shortcut")
    var source: String

    init() {}
    init(source: String) { self.source = source }

    @MainActor
    func perform() async throws -> some IntentResult {
        #if APP_TARGET
        let mode = systemContext.currentMode
        SpikeLog.write("intent", "ToggleDictationIntent.perform() source=\(source) in APP process; mode=\(mode.debugDescription) canContinueInForeground=\(mode.canContinueInForeground)")
        let outcome = try await SessionController.shared.toggle(source: source)
        if case .started(.scratch) = outcome {
            if mode.canContinueInForeground {
                do {
                    try await continueInForeground(alwaysConfirm: false)
                    SpikeLog.write("intent", "continueInForeground returned (app should be foreground)")
                } catch {
                    SpikeLog.write("intent", "continueInForeground FAILED: \(describe(error))")
                }
            } else {
                SpikeLog.write("intent", "scratch branch but canContinueInForeground == false; app stays in background")
            }
        }
        #else
        SpikeLog.write("intent", "ToggleDictationIntent.perform() source=\(source) ran in a NON-app process (unexpected)")
        #endif
        return .result()
    }
}

func describe(_ error: Error) -> String {
    let e = error as NSError
    var cc = ""
    if e.code > 0xFFFF, let u = UInt32(exactly: e.code) {
        let bytes = [24, 16, 8, 0].map { UInt8((u >> UInt32($0)) & 0xFF) }
        if bytes.allSatisfy({ $0 >= 0x20 && $0 < 0x7F }) { cc = " '\(String(decoding: bytes, as: UTF8.self))'" }
    }
    return "\(e.domain) code=\(e.code)\(cc) \(e.localizedDescription) [\(error)]"
}
