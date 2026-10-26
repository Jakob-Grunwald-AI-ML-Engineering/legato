import Foundation

public enum KeyboardPage: Sendable, Equatable, CaseIterable { case letters, numbers, symbols }

public enum KeyAction: Sendable, Equatable {
    case character(String)
    case shift, delete, space, returnKey
    case modeSwitch(KeyboardPage)
    case globe, mic
    /// Placeholder; not placed in any layout yet.
    case emoji
}

public struct Key: Sendable, Equatable, Identifiable {
    public let id: String
    public let action: KeyAction
    public let label: String
    /// Width relative to a letter key (1.0).
    public let width: Double

    public var alternates: [String] {
        if case .character(let c) = action { Alternates.for(c) } else { [] }
    }

    public static func character(_ c: String, width: Double = 1) -> Key {
        Key(id: "char:\(c)", action: .character(c), label: c, width: width)
    }

    public static func special(_ action: KeyAction, width: Double) -> Key {
        switch action {
        case .character(let c): .character(c, width: width)
        case .shift: Key(id: "shift", action: action, label: "⇧", width: width)
        case .delete: Key(id: "delete", action: action, label: "⌫", width: width)
        case .space: Key(id: "space", action: action, label: "space", width: width)
        case .returnKey: Key(id: "return", action: action, label: "return", width: width)
        case .modeSwitch(let p):
            Key(id: "mode:\(p)", action: action, label: p == .letters ? "abc" : p == .numbers ? "123" : "#+=", width: width)
        case .globe: Key(id: "globe", action: action, label: "🌐", width: width)
        case .mic: Key(id: "mic", action: action, label: "🎤", width: width)
        case .emoji: Key(id: "emoji", action: action, label: "☺", width: width)
        }
    }

    /// The text this key types, uppercased when `uppercase` (letters only).
    public func output(uppercase: Bool) -> String? {
        guard case .character(let c) = action else { return nil }
        return uppercase ? c.uppercased() : c
    }
}

public struct KeyboardRow: Sendable, Equatable {
    public let keys: [Key]
    /// Empty space on each side, in key widths.
    public let inset: Double

    public var totalWidth: Double { keys.reduce(0) { $0 + $1.width } + 2 * inset }
}

public struct KeyboardLayout: Sendable, Equatable {
    public let rows: [KeyboardRow]

    private static func chars(_ s: String, width: Double = 1) -> [Key] { s.map { .character(String($0), width: width) } }

    private static func bottom(_ switchTo: KeyboardPage) -> KeyboardRow {
        KeyboardRow(keys: [
            .special(.modeSwitch(switchTo), width: 1.25), .special(.globe, width: 1), .special(.mic, width: 1),
            .special(.space, width: 4.25), .special(.returnKey, width: 2.5),
        ], inset: 0)
    }

    private static func punctuationRow(leading: KeyAction) -> KeyboardRow {
        KeyboardRow(
            keys: [.special(leading, width: 1.5)] + chars(".,?!'", width: 1.4) + [.special(.delete, width: 1.5)], inset: 0)
    }

    public static func page(_ page: KeyboardPage) -> KeyboardLayout {
        switch page {
        case .letters:
            KeyboardLayout(rows: [
                KeyboardRow(keys: chars("qwertyuiop"), inset: 0),
                KeyboardRow(keys: chars("asdfghjkl"), inset: 0.5),
                KeyboardRow(keys: [.special(.shift, width: 1.5)] + chars("zxcvbnm") + [.special(.delete, width: 1.5)], inset: 0),
                bottom(.numbers),
            ])
        case .numbers:
            KeyboardLayout(rows: [
                KeyboardRow(keys: chars("1234567890"), inset: 0),
                KeyboardRow(keys: chars("-/:;()$&@\""), inset: 0),
                punctuationRow(leading: .modeSwitch(.symbols)),
                bottom(.letters),
            ])
        case .symbols:
            KeyboardLayout(rows: [
                KeyboardRow(keys: chars("[]{}#%^*+="), inset: 0),
                KeyboardRow(keys: chars("_\\|~<>€£¥•"), inset: 0),
                punctuationRow(leading: .modeSwitch(.numbers)),
                bottom(.letters),
            ])
        }
    }

    /// Key frames for hit testing: rows share the height equally, widths follow the relative widths.
    /// `spacing` shrinks each frame by half of it on every side.
    public func frames(in bounds: KeyRect, spacing: Double) -> [KeyFrame] {
        let rowHeight = bounds.height / Double(rows.count)
        var out: [KeyFrame] = []
        for (r, row) in rows.enumerated() {
            let unit = bounds.width / row.totalWidth
            var x = bounds.x + row.inset * unit
            for key in row.keys {
                let w = key.width * unit
                let rect = KeyRect(x: x + spacing / 2, y: bounds.y + Double(r) * rowHeight + spacing / 2,
                                   width: w - spacing, height: rowHeight - spacing)
                out.append(KeyFrame(id: key.id, row: r, rect: rect))
                x += w
            }
        }
        return out
    }
}
