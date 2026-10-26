import Foundation

/// Captures a hotkey from raw key events: a lone modifier (pressed and released with nothing
/// else), or a key with modifiers. Escape cancels. Pure; fed by the tap while the recorder is open.
///
/// Modifier keys are tracked by key code, never by flag alone: with Left ⌘ down, a flagsChanged
/// for Right ⌘ (key code 54) still carries the command flag, and only the key code says which
/// key moved.
public struct HotkeyRecorderLogic: Sendable {
    public enum Outcome: Sendable, Equatable {
        case none
        case preview(String)
        case captured(HotkeySpec)
        case cancelled
    }

    private static let counted: ModifierFlags = [.shift, .control, .option, .command, .function]
    /// F1...F12 may be used bare.
    private static let functionKeys: Set<UInt16> = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111]

    /// Physical modifier keys currently down, from their own flagsChanged events.
    private var down: Set<ModifierKey> = []
    private var candidate: ModifierKey?
    private var spoiled = false

    public init() {}

    public mutating func feed(_ event: KeyEvent) -> Outcome {
        var held = event.flags.intersection(Self.counted)
        switch event.kind {
        case .keyUp:
            return .none
        case .keyDown:
            // Arrow and F-keys carry fn by themselves; keep it only if the fn key itself is down.
            if ModifierFlags.carriesImplicitFunction(keyCode: event.keyCode), !down.contains(.function) {
                held.remove(.function)
            }
            if event.keyCode == 53, held.isEmpty { return .cancelled }
            guard !held.isEmpty || Self.functionKeys.contains(event.keyCode) else { return .none }
            return .captured(.combo(keyCode: event.keyCode, modifiers: held))
        case .flagsChanged:
            guard let key = ModifierKey(keyCode: event.keyCode) else { return .none }
            if !event.flags.contains(key.flag) {
                // Its flag is clear: this key and its same-flag twin are both up.
                down = down.filter { $0.flag != key.flag }
            } else if down.contains(key) {
                down.remove(key) // released while its twin keeps the flag on
                return .none
            } else {
                down.insert(key)
                if down.count == 1, candidate == nil, !spoiled {
                    candidate = key
                    return .preview(key.displayName)
                }
                candidate = nil
                spoiled = true
                return .preview("Press a key to finish")
            }
            if let candidate, candidate == key {
                self.candidate = nil
                return .captured(.modifier(candidate))
            }
            if down.isEmpty { spoiled = false }
            return .none
        }
    }
}
