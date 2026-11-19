import Foundation
import LegatoKeyboardCore

/// The typing settings the app writes (Settings > Keyboard) and the keyboard reads, in the App Group.
/// Haptics and clicks default to on; the keyboard additionally needs Full Access to use them.
struct KeyboardPreferences: Equatable {
    static let hapticsKey = "keyboardHaptics"
    static let clicksKey = "keyboardClicks"

    var haptics = true
    var clicks = true
    var automaticAutoFill = AutoFillHandoff.defaultEnabled
    var emojiSystemSwitcher = false
    /// Settings > Keyboard > Dictation key (`DictationKeySide`); right by default.
    var dictationKeySide = DictationKeySide.standard

    /// The extension owns its last layout (minimised or full). Local defaults work with or without Full Access.
    /// Only a boolean is retained, never document text.
    static func expansionPersistence() -> KeyboardExpansionPersistence {
        KeyboardExpansionPersistence(defaults: .standard)
    }

    /// The dictation key's hint counter, kept by the extension like its last layout.
    static func dictationKeyHints() -> DictationKeyHints {
        DictationKeyHints(defaults: .standard)
    }

    static func load() -> KeyboardPreferences {
        guard let defaults = UserDefaults(suiteName: LinkChannel.appGroupID) else { return KeyboardPreferences() }
        return KeyboardPreferences(
            haptics: defaults.object(forKey: hapticsKey) as? Bool ?? true,
            clicks: defaults.object(forKey: clicksKey) as? Bool ?? true,
            automaticAutoFill: defaults.object(forKey: AutoFillHandoff.preferenceKey) as? Bool ?? AutoFillHandoff.defaultEnabled,
            emojiSystemSwitcher: EmojiKeyboardBehavior.usesSystemSwitcher(in: defaults),
            dictationKeySide: DictationKeySide.stored(in: defaults))
    }
}
