import Foundation
import LegatoAppServices
import LegatoCore
import LegatoMac
import LegatoPostProcessing
import Observation

/// User preferences, persisted in `UserDefaults`. Everything here is read live by the controller.
@MainActor @Observable
final class MacSettings {
    private enum Key {
        static let hotkey = "hotkey"
        static let muteHotkey = "meetingMuteHotkey"
        static let gestureMode = "gestureMode"
        static let insertionMode = "insertionMode"
        static let restoreClipboard = "restoreClipboard"
    }

    @ObservationIgnored private let defaults: UserDefaults
    /// The cleanup settings' storage (the same keys as on the phone); the session's post-processor reads it.
    @ObservationIgnored let cleanupStore: CleanupSettingsStore

    /// The dictation trigger; nil until the user records one (first launch).
    var hotkey: HotkeySpec? {
        didSet {
            if let hotkey, let data = try? JSONEncoder().encode(hotkey) {
                defaults.set(data, forKey: Key.hotkey)
            } else {
                defaults.removeObject(forKey: Key.hotkey)
            }
        }
    }

    /// The meeting mute toggle; nil until the user records one.
    var muteHotkey: HotkeySpec? {
        didSet {
            if let muteHotkey, let data = try? JSONEncoder().encode(muteHotkey) {
                defaults.set(data, forKey: Key.muteHotkey)
            } else {
                defaults.removeObject(forKey: Key.muteHotkey)
            }
        }
    }

    var gestureMode: HotkeyGesture.Mode {
        didSet { defaults.set(gestureMode.rawValue, forKey: Key.gestureMode) }
    }

    var insertionMode: FieldWriter.Mode {
        didSet { defaults.set(insertionMode.rawValue, forKey: Key.insertionMode) }
    }

    /// Put the previous clipboard back after a paste.
    var restoreClipboard: Bool {
        didSet { defaults.set(restoreClipboard, forKey: Key.restoreClipboard) }
    }

    // MARK: Cleanup (mirrors `cleanupStore`, observable for the UI)

    /// Clean up the text after a dictation. Off by default.
    var cleanupEnabled: Bool {
        didSet { cleanupStore.enabled = cleanupEnabled }
    }

    var cleanupDelivery: CleanupDelivery {
        didSet { cleanupStore.delivery = cleanupDelivery }
    }

    var cleanupStyle: CleanupStyle {
        didSet { cleanupStore.style = cleanupStyle }
    }

    var cleanupEmoji: MessageEmojiStyle {
        didSet { cleanupStore.emoji = cleanupEmoji }
    }

    var cleanupBackend: CleanupBackendChoice {
        didSet {
            cleanupStore.backend = cleanupBackend
            cleanupTimeoutSeconds = cleanupStore.timeoutSeconds
        }
    }

    /// Number normalization before the language model. Off by default (#22).
    var cleanupITN: Bool {
        didSet { cleanupStore.itn = cleanupITN }
    }

    /// Per-stage limit, 1 to 10 seconds.
    var cleanupTimeoutSeconds: Int {
        didSet {
            // A backend default refresh is not an explicit time-limit choice.
            if cleanupStore.timeoutSeconds != cleanupTimeoutSeconds { cleanupStore.timeoutSeconds = cleanupTimeoutSeconds }
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let cleanup = CleanupSettingsStore(defaults: defaults)
        cleanupStore = cleanup
        cleanupEnabled = cleanup.enabled
        cleanupDelivery = cleanup.delivery
        cleanupStyle = cleanup.style
        cleanupEmoji = cleanup.emoji
        cleanupBackend = cleanup.backend
        cleanupITN = cleanup.itn
        cleanupTimeoutSeconds = cleanup.timeoutSeconds
        hotkey = defaults.data(forKey: Key.hotkey).flatMap { try? JSONDecoder().decode(HotkeySpec.self, from: $0) }
        muteHotkey = defaults.data(forKey: Key.muteHotkey).flatMap { try? JSONDecoder().decode(HotkeySpec.self, from: $0) }
        gestureMode = defaults.string(forKey: Key.gestureMode).flatMap(HotkeyGesture.Mode.init(rawValue:)) ?? .hybrid
        insertionMode = defaults.string(forKey: Key.insertionMode).flatMap(FieldWriter.Mode.init(rawValue:)) ?? .streamCommitted
        restoreClipboard = defaults.object(forKey: Key.restoreClipboard) as? Bool ?? true
    }
}

extension HotkeyGesture.Mode {
    var title: String {
        switch self {
        case .hybrid: "Tap to latch, hold to talk"
        case .toggle: "Tap to start, tap to stop"
        case .hold: "Hold to talk"
        }
    }
}

extension CleanupDelivery {
    var title: String {
        switch self {
        case .replace: "Replace"
        case .clipboard: "Clipboard"
        case .hold: "Hold"
        case .live: "Live"
        }
    }

    var explanation: String {
        switch self {
        case .replace:
            "The raw text is typed while you speak and swapped for the cleaned text when you stop. If you typed after it or moved the cursor meanwhile, the field is left alone and the cleaned text goes to the clipboard."
        case .clipboard:
            "The field keeps the raw text; the cleaned text goes to the clipboard."
        case .hold:
            "Nothing is typed while you speak (the floating panel shows the live text); the cleaned text is inserted when you stop."
        case .live:
            "After each phrase the whole text so far is cleaned again and replaces what you see, so a later \"no wait, Thursday\" can fix an earlier phrase; a last pass runs when you stop. Once you edit the text it stays as you left it."
        }
    }
}

extension FieldWriter.Mode {
    var title: String {
        switch self {
        case .streamCommitted: "Type finished phrases as you speak"
        case .streamLive: "Type everything live"
        case .insertOnStop: "Insert when you stop"
        }
    }
}

#if LEGATO_INTERNAL
extension MacSettings {
    nonisolated static let debugSettingKeys: Set<String> = [
        "gestureMode", "insertionMode", "restoreClipboard", "cleanupEnabled", "cleanupDelivery",
        "cleanupStyle", "cleanupEmoji", "cleanupBackend", "cleanupITN", "cleanupTimeoutSeconds",
    ]

    /// Typed setters keep the observable model, persisted values and cleanup store in agreement.
    func setDebugSetting(_ key: String, value: String) throws {
        guard Self.debugSettingKeys.contains(key) else { throw DebugSettingError.unknownKey }
        func boolean() throws -> Bool {
            guard let result = Bool(value.lowercased()) else { throw DebugSettingError.invalidValue(key) }
            return result
        }
        func choice<T: RawRepresentable>(_ type: T.Type) throws -> T where T.RawValue == String {
            guard let result = T(rawValue: value) else { throw DebugSettingError.invalidValue(key) }
            return result
        }
        switch key {
        case "gestureMode": gestureMode = try choice(HotkeyGesture.Mode.self)
        case "insertionMode": insertionMode = try choice(FieldWriter.Mode.self)
        case "restoreClipboard": restoreClipboard = try boolean()
        case "cleanupEnabled": cleanupEnabled = try boolean()
        case "cleanupDelivery": cleanupDelivery = try choice(CleanupDelivery.self)
        case "cleanupStyle": cleanupStyle = try choice(CleanupStyle.self)
        case "cleanupEmoji": cleanupEmoji = try choice(MessageEmojiStyle.self)
        case "cleanupBackend": cleanupBackend = try choice(CleanupBackendChoice.self)
        case "cleanupITN": cleanupITN = try boolean()
        case "cleanupTimeoutSeconds":
            guard let seconds = Int(value), (1...10).contains(seconds) else { throw DebugSettingError.invalidValue(key) }
            cleanupTimeoutSeconds = seconds
        default: throw DebugSettingError.unknownKey
        }
    }
    var debugSnapshot: [String: Any] {
        ["gestureMode": gestureMode.rawValue, "insertionMode": insertionMode.rawValue,
         "restoreClipboard": restoreClipboard, "cleanupEnabled": cleanupEnabled,
         "cleanupDelivery": cleanupDelivery.rawValue, "cleanupStyle": cleanupStyle.rawValue,
         "cleanupEmoji": cleanupEmoji.rawValue, "cleanupBackend": cleanupBackend.rawValue,
         "cleanupITN": cleanupITN, "cleanupTimeoutSeconds": cleanupTimeoutSeconds]
    }
    enum DebugSettingError: Error, CustomStringConvertible {
        case unknownKey, invalidValue(String)
        var description: String {
            switch self {
            case .unknownKey: "unsupported setting key; allowed: \(MacSettings.debugSettingKeys.sorted().joined(separator: ", "))"
            case .invalidValue(let key): "invalid value for \(key)"
            }
        }
    }
}
#endif
