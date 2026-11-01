import Foundation

/// Composer's host-side microphone retention preference. Reading it never starts capture.
public enum ComposerMicrophonePreference {
    public static let keepActiveKey = "composer.keepMicrophoneActive"

    public static func keepActive(in defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: keepActiveKey) as? Bool ?? true
    }

    public static func setKeepActive(_ value: Bool, in defaults: UserDefaults = .standard) {
        defaults.set(value, forKey: keepActiveKey)
    }
}
