import Foundation
import LegatoMac
import Observation

/// User preferences, persisted in `UserDefaults`. Everything here is read live by the controller.
@MainActor @Observable
final class MacSettings {
    private enum Key {
        static let hotkey = "hotkey"
        static let gestureMode = "gestureMode"
        static let insertionMode = "insertionMode"
        static let restoreClipboard = "restoreClipboard"
    }

    @ObservationIgnored private let defaults: UserDefaults

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

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        hotkey = defaults.data(forKey: Key.hotkey).flatMap { try? JSONDecoder().decode(HotkeySpec.self, from: $0) }
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

extension FieldWriter.Mode {
    var title: String {
        switch self {
        case .streamCommitted: "Type finished phrases as you speak"
        case .streamLive: "Type everything live"
        case .insertOnStop: "Insert when you stop"
        }
    }
}
