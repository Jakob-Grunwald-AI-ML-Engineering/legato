import Foundation
import LegatoKeyboardCore

/// The typing settings the app writes (Settings > Keyboard) and the keyboard reads, in the App Group.
/// Haptics and clicks default to on; the keyboard additionally needs Full Access to use them. The strip
/// ("Compact keyboard") defaults to off.
struct KeyboardPreferences: Equatable {
    static let hapticsKey = "keyboardHaptics"
    static let clicksKey = "keyboardClicks"
    static let stripKey = "keyboardStrip"
    /// The height experiment's starting height (points). Read in DEBUG builds only.
    static let stripHeightKey = "keyboardStripHeight"

    var haptics = true
    var clicks = true
    var automaticAutoFill = AutoFillHandoff.defaultEnabled
    var strip = false
    var stripHeight = StripHeight.standard
    static func load() -> KeyboardPreferences {
        guard let defaults = UserDefaults(suiteName: LinkChannel.appGroupID) else { return KeyboardPreferences() }
        var stored: Double?
        #if DEBUG
        stored = defaults.object(forKey: stripHeightKey) as? Double
        #endif
        return KeyboardPreferences(
            haptics: defaults.object(forKey: hapticsKey) as? Bool ?? true,
            clicks: defaults.object(forKey: clicksKey) as? Bool ?? true,
            automaticAutoFill: defaults.object(forKey: AutoFillHandoff.preferenceKey) as? Bool ?? AutoFillHandoff.defaultEnabled,
            strip: defaults.object(forKey: stripKey) as? Bool ?? false,
            stripHeight: StripHeight.resolve(stored: stored))
    }
}
