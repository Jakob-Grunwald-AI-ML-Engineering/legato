import Foundation

/// Modifier state of a key event. Bit values equal macOS's device-independent modifier flags
/// (`CGEventFlags` / `NSEvent.ModifierFlags`), so adapters convert by raw value.
public struct ModifierFlags: OptionSet, Sendable, Hashable, Codable {
    public let rawValue: UInt
    public init(rawValue: UInt) { self.rawValue = rawValue }

    public static let capsLock = ModifierFlags(rawValue: 1 << 16)
    public static let shift = ModifierFlags(rawValue: 1 << 17)
    public static let control = ModifierFlags(rawValue: 1 << 18)
    public static let option = ModifierFlags(rawValue: 1 << 19)
    public static let command = ModifierFlags(rawValue: 1 << 20)
    public static let function = ModifierFlags(rawValue: 1 << 23)
}

extension ModifierFlags {
    /// Arrow keys and F1...F12 set the fn flag by themselves.
    public static func carriesImplicitFunction(keyCode: UInt16) -> Bool {
        implicitFunctionKeys.contains(keyCode)
    }

    private static let implicitFunctionKeys: Set<UInt16> = [
        123, 124, 125, 126, // arrows
        122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, // F1...F12
    ]
}

/// A single physical modifier key, with side.
public enum ModifierKey: String, Sendable, Hashable, Codable, CaseIterable {
    case leftCommand, rightCommand, leftOption, rightOption
    case leftControl, rightControl, leftShift, rightShift, function

    /// macOS virtual key code.
    public var keyCode: UInt16 {
        switch self {
        case .rightCommand: 54
        case .leftCommand: 55
        case .rightOption: 61
        case .leftOption: 58
        case .rightControl: 62
        case .leftControl: 59
        case .rightShift: 60
        case .leftShift: 56
        case .function: 63
        }
    }

    public init?(keyCode: UInt16) {
        guard let key = ModifierKey.allCases.first(where: { $0.keyCode == keyCode }) else { return nil }
        self = key
    }

    /// The flag that is set while this key (or its other-side twin) is down.
    public var flag: ModifierFlags {
        switch self {
        case .leftCommand, .rightCommand: .command
        case .leftOption, .rightOption: .option
        case .leftControl, .rightControl: .control
        case .leftShift, .rightShift: .shift
        case .function: .function
        }
    }

    public var displayName: String {
        let symbol: String
        switch flag {
        case .command: symbol = "⌘"
        case .option: symbol = "⌥"
        case .control: symbol = "⌃"
        case .shift: symbol = "⇧"
        default: return "fn"
        }
        switch self {
        case .leftCommand, .leftOption, .leftControl, .leftShift: return "Left \(symbol)"
        default: return "Right \(symbol)"
        }
    }
}

/// A key event reduced to what hotkey matching needs.
public struct KeyEvent: Sendable, Hashable {
    public enum Kind: Sendable, Hashable { case flagsChanged, keyDown, keyUp }

    public var kind: Kind
    public var keyCode: UInt16
    public var flags: ModifierFlags

    public init(kind: Kind, keyCode: UInt16, flags: ModifierFlags) {
        self.kind = kind
        self.keyCode = keyCode
        self.flags = flags
    }
}

/// What a key event means for the trigger; feeds `HotkeyGesture`.
public enum TriggerEvent: Sendable, Equatable {
    case pressed, released, otherKeyDown
}

/// The key (or key combination) that drives dictation: a lone modifier key, told apart by side,
/// or a key plus modifiers. Matching is pure; feed the result to `HotkeyGesture`.
public enum HotkeySpec: Sendable, Hashable, Codable {
    case modifier(ModifierKey)
    case combo(keyCode: UInt16, modifiers: ModifierFlags)

    /// Modifiers that count when matching a combo; caps lock and the like are ignored.
    private static let matchedModifiers: ModifierFlags = [.shift, .control, .option, .command, .function]

    /// Classifies an event relative to the trigger; nil when it is irrelevant.
    ///
    /// - Modifier trigger: a `flagsChanged` carrying its key code is pressed while its flag is
    ///   set, released when it is clear. Any `keyDown`, or another modifier going down, is a
    ///   chord key. (A flag shared with the other side's twin, e.g. both ⌘ held, cannot be told
    ///   apart from the flag alone.)
    /// - Combo trigger: `keyDown` of the key with exactly the modifiers is pressed (auto-repeat
    ///   yields repeated presses, which the gesture ignores); `keyUp` of the key, or a required
    ///   modifier being lifted, is released; any other `keyDown` is a chord key.
    public func triggerEvent(for event: KeyEvent) -> TriggerEvent? {
        switch self {
        case .modifier(let key):
            switch event.kind {
            case .flagsChanged:
                if event.keyCode == key.keyCode {
                    return event.flags.contains(key.flag) ? .pressed : .released
                }
                if let other = ModifierKey(keyCode: event.keyCode), event.flags.contains(other.flag) {
                    return .otherKeyDown
                }
                return nil
            case .keyDown:
                return .otherKeyDown
            case .keyUp:
                return nil
            }
        case .combo(let keyCode, let modifiers):
            switch event.kind {
            case .keyDown:
                if event.keyCode == keyCode,
                   Self.eventModifiers(event, specModifiers: modifiers) == modifiers {
                    return .pressed
                }
                return .otherKeyDown
            case .keyUp:
                return event.keyCode == keyCode ? .released : nil
            case .flagsChanged:
                return event.flags.isSuperset(of: modifiers) ? nil : .released
            }
        }
    }

    /// Arrow and function keys carry the fn flag implicitly; unless the spec asks for fn, it is not
    /// part of the match.
    private static func eventModifiers(_ event: KeyEvent, specModifiers: ModifierFlags) -> ModifierFlags {
        var flags = event.flags.intersection(matchedModifiers)
        if ModifierFlags.carriesImplicitFunction(keyCode: event.keyCode), !specModifiers.contains(.function) {
            flags.remove(.function)
        }
        return flags
    }

    /// Why a recorded hotkey may be a poor choice.
    public enum Warning: Sendable, Equatable {
        /// The key would still type a character (or a symbol, with ⌥) into the focused field.
        case producesCharacter
        /// A shortcut other apps and the system rely on.
        case systemShortcut

        public var message: String {
            switch self {
            case .producesCharacter: "This key also types a character. Add ⌃ or ⌘, or pick a function key."
            case .systemShortcut: "A common system shortcut. Legato cannot stop it from also acting."
            }
        }
    }

    /// ⌘C ⌘V ⌘X ⌘Z ⌘Q ⌘W ⌘Tab ⌘Space.
    private static let systemShortcutKeys: Set<UInt16> = [8, 9, 7, 6, 12, 13, 48, 49]
    private static let nonCharacterKeys: Set<UInt16> = [51, 53]

    /// A caution for the recorder UI; nil for a lone modifier and for combos that look safe.
    public var warning: Warning? {
        guard case .combo(let keyCode, let modifiers) = self else { return nil }
        let held = modifiers.intersection(Self.matchedModifiers)
        if held == .command, Self.systemShortcutKeys.contains(keyCode) { return .systemShortcut }
        let isCharacterKey = Self.names[keyCode] != nil
            && !Self.nonCharacterKeys.contains(keyCode)
            && !ModifierFlags.carriesImplicitFunction(keyCode: keyCode)
        if isCharacterKey, held.isSubset(of: [.shift, .option]) { return .producesCharacter }
        return nil
    }

    /// For the UI, e.g. "Right ⌘" or "⌃⇧Space".
    public var displayName: String {
        switch self {
        case .modifier(let key):
            return key.displayName
        case .combo(let keyCode, let modifiers):
            var name = ""
            if modifiers.contains(.function) { name += "fn" }
            if modifiers.contains(.control) { name += "⌃" }
            if modifiers.contains(.option) { name += "⌥" }
            if modifiers.contains(.shift) { name += "⇧" }
            if modifiers.contains(.command) { name += "⌘" }
            return name + Self.keyName(keyCode)
        }
    }

    /// Names for ANSI-layout virtual key codes; the label of a layout-specific key may differ.
    private static func keyName(_ keyCode: UInt16) -> String {
        names[keyCode] ?? "Key \(keyCode)"
    }

    private static let names: [UInt16: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V", 11: "B",
        12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4",
        22: "6", 23: "5", 24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0", 30: "]", 31: "O",
        32: "U", 33: "[", 34: "I", 35: "P", 36: "↩", 37: "L", 38: "J", 39: "'", 40: "K", 41: ";",
        42: "\\", 43: ",", 44: "/", 45: "N", 46: "M", 47: ".", 48: "⇥", 49: "Space", 50: "`",
        51: "⌫", 53: "⎋", 96: "F5", 97: "F6", 98: "F7", 99: "F3", 100: "F8", 101: "F9", 103: "F11",
        109: "F10", 111: "F12", 118: "F4", 120: "F2", 122: "F1", 123: "←", 124: "→", 125: "↓", 126: "↑",
    ]
}

/// Turns the key events of a second, one-shot hotkey (the meeting mute toggle) into "it fired".
/// Independent of the dictation hotkey's `HotkeyGesture`, which it never touches.
///
/// - Combo: fires once on the key-down; auto-repeat is ignored until the key (or a required modifier) is released.
/// - Lone modifier: fires on its release, and only when no other key went down while it was held, so
///   a chord such as Right ⌥ + A does not toggle.
public struct HotkeyPressDetector: Sendable {
    public let spec: HotkeySpec
    private var isDown = false
    private var spoiled = false

    public init(spec: HotkeySpec) {
        self.spec = spec
    }

    /// Whether `event` completes a press of the hotkey.
    public mutating func feed(_ event: KeyEvent) -> Bool {
        guard let trigger = spec.triggerEvent(for: event) else { return false }
        switch (spec, trigger) {
        case (.combo, .pressed):
            defer { isDown = true }
            return !isDown
        case (.modifier, .pressed):
            isDown = true
            spoiled = false
            return false
        case (.modifier, .otherKeyDown):
            if isDown { spoiled = true }
            return false
        case (.modifier, .released):
            defer { reset() }
            return isDown && !spoiled
        case (.combo, .released):
            isDown = false
            return false
        case (.combo, .otherKeyDown):
            return false
        }
    }

    /// Forget a press in progress (key events were lost).
    public mutating func reset() {
        isDown = false
        spoiled = false
    }
}

extension HotkeySpec {
    /// Two hotkeys that one key press would both trigger; the recorder refuses such a pair.
    public func conflicts(with other: HotkeySpec) -> Bool {
        self == other
    }
}
