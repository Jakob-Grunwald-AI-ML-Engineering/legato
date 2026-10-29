import Foundation

/// What the strip's row holds, left to right in this order (the globe only when iOS asks for it).
public enum StripSlot: Sendable, Equatable, Hashable {
    case expand, globe, hotkeys, delete, returnKey, mic
}

/// How the return key is captioned: a glyph (return, send) fits a standard key; a word ("search", "go") needs more room.
public enum StripReturnStyle: Sendable, Equatable { case glyph, text }

/// One slot of the row: the drawn key (`x`, `width`) and the touch area around it (`hitX`, `hitWidth`).
public struct StripCell: Sendable, Equatable {
    public let slot: StripSlot
    public let x: Double
    public let width: Double
    public let hitX: Double
    public let hitWidth: Double

    public var maxX: Double { x + width }
    public var hitMaxX: Double { hitX + hitWidth }
    /// Distance from the touch area's edges to the drawn key.
    public var leadingInset: Double { x - hitX }
    public var trailingInset: Double { hitMaxX - maxX }
}

/// The compact strip's single row for a keyboard width: chevron · globe? · hotkeys · delete · return · mic.
/// The hotkeys cell holds undo, redo and an icon-only Refine. The mic pill keeps its full size and the
/// right margin at every width. When space is short the keys shrink first, down to `minKeyWidth`; then redo
/// goes (``showsRedo``) and the keys get what that frees; only below the phone sizes do the keys shrink
/// further. The touch areas tile the whole width (each gap is split in the middle; the chevron and the
/// mic reach the screen edges), so the mic pill stays easy to hit.
public struct StripRow: Sendable, Equatable {
    public static let margin = 6.33
    public static let gap = 6.0
    public static let keyWidth = 44.0
    /// The smallest a key gets on a phone-sized width (375 pt and up), globe and text return included.
    public static let minKeyWidth = 36.0
    public static let textReturnWidth = 60.0
    public static let pillWidth = 81.0
    /// One hotkey button (undo, redo, Refine).
    public static let hotkeyButtonWidth = 30.0
    /// Three 30 pt key faces with the same 6 pt gaps as the key grid.
    public static let minHotkeysWidth = 3 * hotkeyButtonWidth + 2 * gap
    /// Two 30 pt key faces and their 6 pt gap when redo does not fit.
    public static let minCompactHotkeysWidth = 2 * hotkeyButtonWidth + gap

    public let cells: [StripCell]
    /// Whether the hotkeys cell has room for redo (it is left out on the narrowest rows).
    public let showsRedo: Bool

    public static func make(width: Double, showsGlobe: Bool, returnStyle: StripReturnStyle) -> StripRow {
        var slots: [StripSlot] = [.expand]
        if showsGlobe { slots.append(.globe) }
        slots += [.hotkeys, .delete, .returnKey, .mic]

        let textReturn = returnStyle == .text
        // Slots that give way: the chevron, the globe, delete and a glyph return.
        let flexible = slots.filter { $0 == .expand || $0 == .globe || $0 == .delete || ($0 == .returnKey && !textReturn) }.count
        let fixed = 2 * margin + Double(slots.count - 1) * gap + pillWidth + (textReturn ? textReturnWidth : 0)
        let available = width - fixed
        let count = Double(flexible)

        var key = keyWidth
        var showsRedo = true
        if available - count * key < minHotkeysWidth {
            key = (available - minHotkeysWidth) / count
            if key < minKeyWidth {
                // Three buttons would squeeze the keys below their floor: redo goes, the keys get its room.
                showsRedo = false
                key = min(max((available - minCompactHotkeysWidth) / count, 0), keyWidth)
            }
        }
        let hotkeys = max(available - count * key, 0)

        func slotWidth(_ slot: StripSlot) -> Double {
            switch slot {
            case .hotkeys: hotkeys
            case .mic: pillWidth
            case .returnKey: textReturn ? textReturnWidth : key
            case .expand, .globe, .delete: key
            }
        }

        var frames: [(slot: StripSlot, x: Double, width: Double)] = []
        var x = margin
        for slot in slots {
            let w = slotWidth(slot)
            frames.append((slot, x, w))
            x += w + gap
        }
        let cells = frames.enumerated().map { index, f in
            let hitX = index == 0 ? 0 : f.x - gap / 2
            let hitMaxX = index == frames.count - 1 ? width : f.x + f.width + gap / 2
            return StripCell(slot: f.slot, x: f.x, width: f.width, hitX: hitX, hitWidth: hitMaxX - hitX)
        }
        return StripRow(cells: cells, showsRedo: showsRedo)
    }
}
