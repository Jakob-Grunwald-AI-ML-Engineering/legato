import Foundation

/// Shared by the app's settings and the keyboard extension. No field text is retained.
public enum EmojiKeyboardBehavior {
    public static let preferenceKey = "keyboardEmojiSystemSwitcher"

    public static func usesSystemSwitcher(in defaults: UserDefaults) -> Bool {
        defaults.object(forKey: preferenceKey) as? Bool ?? false
    }

    public static func setUsesSystemSwitcher(_ enabled: Bool, in defaults: UserDefaults) {
        defaults.set(enabled, forKey: preferenceKey)
    }

    public static func offersLocalPanel(numeric: Bool, secure: Bool, contentType: String?) -> Bool {
        !numeric && !secure && !AutoFillHandoff.offersAction(contentType: contentType)
    }
}
