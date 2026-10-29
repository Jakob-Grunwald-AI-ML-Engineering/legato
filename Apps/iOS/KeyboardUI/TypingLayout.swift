import LegatoKeyboardCore
import UIKit

/// What kind of field the keyboard types into, as far as the key layout is concerned.
enum KeyboardField: Equatable {
    case standard, email, url, numberPad, phonePad, decimalPad

    init(_ type: UIKeyboardType) {
        switch type {
        case .emailAddress: self = .email
        case .URL, .webSearch: self = .url
        case .numberPad, .asciiCapableNumberPad: self = .numberPad
        case .phonePad: self = .phonePad
        case .decimalPad: self = .decimalPad
        default: self = .standard
        }
    }

    var isNumpad: Bool { self == .numberPad || self == .phonePad || self == .decimalPad }
}

struct LayoutRow: Equatable {
    enum Kind: Equatable {
        /// Equal keys from the margin (or half a pitch in, for the second letter row).
        case letters(indent: Bool)
        /// A function key, centered keys, a function key.
        case third
        case bottom
        /// Three wide columns.
        case numpad
    }

    var keys: [Key]
    var kind: Kind
}

/// The rows of the page being shown, laid out like the system keyboard (see `KeyboardMetrics.swift`).
/// `LegatoKeyboardCore.KeyboardLayout` provides the keys of the three upper rows; the bottom row, the
/// extra keys of email and URL fields and the numpad are built here (the core's bottom row has the mic
/// key, which lives in the top bar now, and its widths are not the system's).
struct TypingLayout: Equatable {
    var rows: [LayoutRow]

    static func make(page: KeyboardPage, field: KeyboardField, showsGlobe: Bool) -> TypingLayout {
        if field.isNumpad { return numpad(field) }
        let base = KeyboardLayout.page(page).rows
        var rows = base.dropLast().enumerated().map { index, row in
            LayoutRow(keys: row.keys, kind: index == 2 ? .third : .letters(indent: row.inset > 0))
        }
        rows.append(LayoutRow(keys: bottomKeys(page: page, field: field, showsGlobe: showsGlobe), kind: .bottom))
        return TypingLayout(rows: rows)
    }

    private static func bottomKeys(page: KeyboardPage, field: KeyboardField, showsGlobe: Bool) -> [Key] {
        var keys: [Key] = [.special(.modeSwitch(page == .letters ? .numbers : .letters), width: 1)]
        if showsGlobe { keys.append(.special(.globe, width: 1)) }
        if page == .letters { keys.append(.special(.emoji, width: 1)) }
        switch (page, field) {
        case (.letters, .email): keys.append(.special(.space, width: 1)); keys += [.character("@"), .character(".")]
        case (.letters, .url): keys.append(.special(.space, width: 1)); keys += [.character("/"), .character(".")]
        default: keys.append(.special(.space, width: 1))
        }
        keys.append(.special(.returnKey, width: 1))
        return keys
    }

    /// Digits in three columns; the bottom row holds zero, delete, and the field's extra key.
    private static func numpad(_ field: KeyboardField) -> TypingLayout {
        let digit: (String) -> LayoutRow = { s in LayoutRow(keys: s.map { Key.character(String($0)) }, kind: .numpad) }
        let left: Key =
            switch field {
            case .decimalPad: .character(".")
            case .phonePad: .character("+")
            default: .special(.emoji, width: 1)  // replaced below: a blank slot
            }
        var last = [left, .character("0"), .special(.delete, width: 1)]
        if field == .numberPad { last.removeFirst() }
        return TypingLayout(rows: [digit("123"), digit("456"), digit("789"), LayoutRow(keys: last, kind: .numpad)])
    }

    /// The letters under a digit on the phone keypad.
    static func sublabel(_ digit: String) -> String? {
        ["2": "ABC", "3": "DEF", "4": "GHI", "5": "JKL", "6": "MNO", "7": "PQRS", "8": "TUV", "9": "WXYZ"][digit]
    }

    /// Key frames inside a keyboard view of `size`.
    func frames(in size: CGSize, landscapeScreenWidth: CGFloat? = nil) -> [KeyFrame] {
        let g = KeyGeometry(size: size, landscapeScreenWidth: landscapeScreenWidth)
        var out: [KeyFrame] = []
        func add(_ key: Key, row: Int, x: CGFloat, w: CGFloat, y: CGFloat, h: CGFloat) {
            out.append(KeyFrame(id: key.id, row: row, rect: KeyRect(x: x, y: y, width: w, height: h)))
        }
        for (r, row) in rows.enumerated() {
            let y = g.firstRowTop + CGFloat(r) * g.rowPitch
            let k = g.keyWidth
            switch row.kind {
            case .letters(let indent):
                var x = g.marginX + (indent ? (k + g.gap) / 2 : 0)
                for key in row.keys {
                    add(key, row: r, x: x, w: k, y: y, h: g.keyHeight)
                    x += k + g.gap
                }
            case .third:
                let f = g.functionWidth
                let middle = Array(row.keys.dropFirst().dropLast())
                let mw = middle.count == 5 ? g.punctuationWidth : k
                let span = CGFloat(middle.count) * mw + CGFloat(middle.count - 1) * g.gap
                var x = (size.width - span) / 2
                if let first = row.keys.first { add(first, row: r, x: g.marginX, w: f, y: y, h: g.keyHeight) }
                for key in middle {
                    add(key, row: r, x: x, w: mw, y: y, h: g.keyHeight)
                    x += mw + g.gap
                }
                if let last = row.keys.last { add(last, row: r, x: size.width - g.marginX - f, w: f, y: y, h: g.keyHeight) }
            case .bottom:
                func width(_ key: Key) -> CGFloat? {
                    switch key.action {
                    case .modeSwitch(let target): target == .letters ? g.wideKeyWidth : g.modeKeyWidth
                    case .returnKey: g.wideKeyWidth
                    case .space: nil
                    default: g.smallKeyWidth
                    }
                }
                let fixed = row.keys.compactMap(width).reduce(0, +)
                let rest = size.width - 2 * g.marginX - fixed - CGFloat(row.keys.count - 1) * g.gap
                var x = g.marginX
                for key in row.keys {
                    let w = width(key) ?? rest
                    add(key, row: r, x: x, w: w, y: y, h: g.keyHeight)
                    x += w + g.gap
                }
            case .numpad:
                // Three columns, or two keys of a column when the left slot is blank (number pad).
                let margin: CGFloat = 4.67
                let w = (size.width - 2 * margin - 2 * g.gap) / 3
                let blank = row.keys.count == 2
                var x = margin + (blank ? w + g.gap : 0)
                for key in row.keys {
                    add(key, row: r, x: x, w: w, y: y, h: g.numpadKeyHeight)
                    x += w + g.gap
                }
            }
        }
        return out
    }
}

extension KeyFrame {
    var cgRect: CGRect { CGRect(x: rect.x, y: rect.y, width: rect.width, height: rect.height) }
}
