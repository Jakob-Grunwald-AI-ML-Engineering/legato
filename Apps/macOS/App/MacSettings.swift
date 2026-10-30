import Foundation
import LegatoMac
import Observation

@MainActor @Observable final class MacSettings {
    private let defaults: UserDefaults
    var hotkey: HotkeySpec? {
        didSet {
            if let hotkey, let data = try? JSONEncoder().encode(hotkey) { defaults.set(data, forKey: "hotkey") }
            else { defaults.removeObject(forKey: "hotkey") }
        }
    }
    var gestureMode: HotkeyGesture.Mode { didSet { defaults.set(gestureMode.rawValue, forKey: "gestureMode") } }
    var insertionMode: FieldWriter.Mode { didSet { defaults.set(insertionMode.rawValue, forKey: "insertionMode") } }
    var restoreClipboard: Bool { didSet { defaults.set(restoreClipboard, forKey: "restoreClipboard") } }
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        hotkey = defaults.data(forKey: "hotkey").flatMap { try? JSONDecoder().decode(HotkeySpec.self, from: $0) } ?? .modifier(.rightCommand)
        gestureMode = defaults.string(forKey: "gestureMode").flatMap(HotkeyGesture.Mode.init(rawValue:)) ?? .hybrid
        insertionMode = defaults.string(forKey: "insertionMode").flatMap(FieldWriter.Mode.init(rawValue:)) ?? .streamCommitted
        restoreClipboard = defaults.object(forKey: "restoreClipboard") as? Bool ?? true
    }
}
