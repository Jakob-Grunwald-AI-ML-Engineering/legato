import Foundation
import LegatoKeyboardCore

/// The typing settings the app writes (Settings > Keyboard) and the keyboard reads, in the App Group.
/// Both default to on; the keyboard additionally needs Full Access to use them.
struct KeyboardPreferences: Equatable {
    static let hapticsKey = "keyboardHaptics"
    static let clicksKey = "keyboardClicks"

    var haptics = true
    var clicks = true

    static func load() -> KeyboardPreferences {
        guard let defaults = UserDefaults(suiteName: LinkChannel.appGroupID) else { return KeyboardPreferences() }
        return KeyboardPreferences(
            haptics: defaults.object(forKey: hapticsKey) as? Bool ?? true,
            clicks: defaults.object(forKey: clicksKey) as? Bool ?? true)
    }
}
