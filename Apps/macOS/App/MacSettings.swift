import Foundation
import LegatoAppServices
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
    /// Types dictation straight into the focused field; the panel `hotkey` stays agent-only. Right ⌥ unless the
    /// panel shortcut already is that key (Right ⌘ was the single pre-offshoot dictation key and is the panel's now).
    var dictationHotkey: HotkeySpec? {
        didSet {
            if let dictationHotkey, let data = try? JSONEncoder().encode(dictationHotkey) { defaults.set(data, forKey: "dictationHotkey") }
            else { defaults.set(true, forKey: "dictationHotkeyCleared"); defaults.removeObject(forKey: "dictationHotkey") }
            if dictationHotkey != nil { defaults.removeObject(forKey: "dictationHotkeyCleared") }
        }
    }
    var gestureMode: HotkeyGesture.Mode { didSet { defaults.set(gestureMode.rawValue, forKey: "gestureMode") } }
    /// When dictated text is written: once per take (on stop, or after a pause) or line by line. The pipeline reads
    /// the same keys live from the standard defaults.
    var dictationSend: DictationSendSetting.Mode { didSet { defaults.set(dictationSend.rawValue, forKey: DictationSendSetting.modeKey) } }
    var dictationPause: Double { didSet { defaults.set(DictationSendSetting.clampedPause(dictationPause), forKey: DictationSendSetting.pauseKey) } }
    var insertionMode: FieldWriter.Mode { didSet { defaults.set(insertionMode.rawValue, forKey: "insertionMode") } }
    /// Types a take in word by word (Accessibility, or key events in paste-only apps); off inserts at once and pastes.
    var typewriter: Bool { didSet { defaults.set(typewriter, forKey: "typewriterInsertion") } }
    var restoreClipboard: Bool { didSet { defaults.set(restoreClipboard, forKey: "restoreClipboard") } }
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let panel = defaults.data(forKey: "hotkey").flatMap { try? JSONDecoder().decode(HotkeySpec.self, from: $0) } ?? .modifier(.rightCommand)
        hotkey = panel
        dictationHotkey = Self.initialDictationHotkey(defaults, panel: panel)
        gestureMode = defaults.string(forKey: "gestureMode").flatMap(HotkeyGesture.Mode.init(rawValue:)) ?? .hybrid
        dictationSend = DictationSendSetting.mode(in: defaults)
        dictationPause = DictationSendSetting.pause(in: defaults)
        insertionMode = defaults.string(forKey: "insertionMode").flatMap(FieldWriter.Mode.init(rawValue:)) ?? .streamCommitted
        typewriter = defaults.object(forKey: "typewriterInsertion") as? Bool ?? true
        restoreClipboard = defaults.object(forKey: "restoreClipboard") as? Bool ?? true
    }
    private static func initialDictationHotkey(_ defaults: UserDefaults, panel: HotkeySpec?) -> HotkeySpec? {
        if let spec = defaults.data(forKey: "dictationHotkey").flatMap({ try? JSONDecoder().decode(HotkeySpec.self, from: $0) }) { return spec }
        if defaults.bool(forKey: "dictationHotkeyCleared") { return nil }
        let preferred = HotkeySpec.modifier(.rightOption)
        return panel.map { preferred.conflicts(with: $0) } == true ? nil : preferred
    }
}
