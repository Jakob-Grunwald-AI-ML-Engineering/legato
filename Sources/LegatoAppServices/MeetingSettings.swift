import Foundation

/// The meeting settings in an injected `UserDefaults` (the App Group's on the phone, the app's on the Mac).
/// Custom summary prompt empty (the default prompt), backend Auto, voice processing on, auto-mute on.
public struct MeetingSettings: Sendable {
    // UserDefaults is documented thread-safe but not annotated Sendable.
    nonisolated(unsafe) private let defaults: UserDefaults

    private enum Key {
        static let prompt = "meeting.summaryPrompt"
        static let backend = "meeting.summaryBackend"
        static let voiceProcessing = "meeting.voiceProcessing"
        static let autoMute = "meeting.autoMute"
    }

    public init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    /// The user's own summary instructions; empty means the default prompt.
    public var customPrompt: String {
        get { defaults.string(forKey: Key.prompt) ?? "" }
        nonmutating set { defaults.set(newValue, forKey: Key.prompt) }
    }

    /// Which on-device backend writes the automatic summary. Claude is never a choice here: it is explicit,
    /// per meeting.
    public var backend: CleanupBackendChoice {
        get { defaults.string(forKey: Key.backend).flatMap(CleanupBackendChoice.init(rawValue:)) ?? .auto }
        nonmutating set { defaults.set(newValue.rawValue, forKey: Key.backend) }
    }

    /// Apple voice processing on the Mac mic, so the speakers are not heard twice. Default on.
    public var voiceProcessing: Bool {
        get { defaults.object(forKey: Key.voiceProcessing) as? Bool ?? true }
        nonmutating set { defaults.set(newValue, forKey: Key.voiceProcessing) }
    }

    /// Mac: mute "me" when the call app closes the mic. Default on.
    public var autoMute: Bool {
        get { defaults.object(forKey: Key.autoMute) as? Bool ?? true }
        nonmutating set { defaults.set(newValue, forKey: Key.autoMute) }
    }
}
