import Foundation
import LegatoAppServices
import LegatoMac
import Observation

@MainActor @Observable final class MacSettings {
    static let defaultDictationHotkey = HotkeySpec.modifier(.rightOption)
    private let defaults: UserDefaults
    var hotkey: HotkeySpec? { didSet { save(hotkey, key: "hotkey") } }
    var dictationHotkey: HotkeySpec? { didSet { save(dictationHotkey, key: "dictationHotkey") } }
    private var composerBindings: [MacComposerShortcut: HotkeySpec] = [:]

    func binding(for action: MacComposerShortcut) -> HotkeySpec? {
        if action == .magic { return hotkey }
        guard let binding = composerBindings[action],
              binding != hotkey, binding != dictationHotkey else { return nil }
        return binding
    }

    func setBinding(_ binding: HotkeySpec?, for action: MacComposerShortcut) {
        if let binding, !action.accepts(binding) { return }
        if action == .magic { hotkey = binding; return }
        composerBindings[action] = binding
        save(binding, key: Self.composerKey(action))
    }

    func resetBinding(for action: MacComposerShortcut) {
        setBinding(action.defaultBinding, for: action)
        let key = action == .magic ? "hotkey" : Self.composerKey(action)
        defaults.removeObject(forKey: key)
        defaults.removeObject(forKey: key + "Cleared")
    }

    private static func composerKey(_ action: MacComposerShortcut) -> String { "composer.shortcut.\(action)" }

    private func save(_ binding: HotkeySpec?, key: String) {
        if let binding, let data = try? JSONEncoder().encode(binding) {
            defaults.set(data, forKey: key)
            defaults.removeObject(forKey: key + "Cleared")
        } else {
            defaults.set(true, forKey: key + "Cleared")
            defaults.removeObject(forKey: key)
        }
    }

    private static func load(_ key: String, from defaults: UserDefaults, fallback: HotkeySpec?) -> HotkeySpec? {
        if let data = defaults.data(forKey: key), let spec = try? JSONDecoder().decode(HotkeySpec.self, from: data) { return spec }
        return defaults.bool(forKey: key + "Cleared") ? nil : fallback
    }
    var gestureMode: HotkeyGesture.Mode { didSet { defaults.set(gestureMode.rawValue, forKey: "gestureMode") } }
    /// Types a take in word by word (Accessibility, or key events in paste-only apps); off inserts at once and pastes.
    var typewriter: Bool { didSet { defaults.set(typewriter, forKey: "typewriterInsertion") } }
    var restoreClipboard: Bool { didSet { defaults.set(restoreClipboard, forKey: "restoreClipboard") } }
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let magic = Self.load("hotkey", from: defaults, fallback: MacComposerShortcut.magic.defaultBinding)
        hotkey = magic
        let dictationDefault = Self.defaultDictationHotkey
        dictationHotkey = Self.load("dictationHotkey", from: defaults, fallback: magic == dictationDefault ? nil : dictationDefault)
        gestureMode = defaults.string(forKey: "gestureMode").flatMap(HotkeyGesture.Mode.init(rawValue:)) ?? .hybrid
        typewriter = defaults.object(forKey: "typewriterInsertion") as? Bool ?? true
        restoreClipboard = defaults.object(forKey: "restoreClipboard") as? Bool ?? true
        for action in MacComposerShortcut.chordActions {
            let binding = Self.load(Self.composerKey(action), from: defaults, fallback: action.defaultBinding)
            if let binding, action.accepts(binding) { composerBindings[action] = binding }
        }
    }
}
