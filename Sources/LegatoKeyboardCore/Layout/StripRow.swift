import Foundation

/// What the strip's row holds, left to right in this order (the globe only when iOS asks for it; undo and
/// redo only when there is room).
public enum StripSlot: Sendable, Equatable, Hashable {
    case expand, globe, magic, mic, undo, redo, delete, returnKey
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

/// The compact strip's single row for a keyboard width: chevron · globe? · magic · mic · undo · redo · delete · return.
/// The keys share the width between the side margins, `gap` apart; the mic key is a little wider
/// (``micWeight``) and a text return caption ("search") has a fixed width. When the share would fall
/// below ``minKeyWidth`` the row gives up redo first, then undo (``showsRedo``, ``showsUndo``); the
/// chevron, globe, magic, mic, delete and return always stay, so the mic and return remain easy to hit.
/// Only below the phone sizes (under 320 pt) do the keys shrink past the floor. The touch areas tile the
/// whole width (each gap is split in the middle; the chevron and the return key reach the screen edges).
public struct StripRow: Sendable, Equatable {
    public static let margin = 6.33
    public static let gap = 6.0
    /// The smallest a key gets while there is anything left to give up (every phone width from 320 pt).
    public static let minKeyWidth = 36.0
    /// The mic key's share of the row against a standard key's 1.
    public static let micWeight = 1.5
    public static let textReturnWidth = 60.0

    public let cells: [StripCell]
    /// Whether the row has room for undo and redo (they are left out on the narrowest rows, redo first).
    public let showsUndo: Bool
    public let showsRedo: Bool

    public static func make(width: Double, showsGlobe: Bool, returnStyle: StripReturnStyle) -> StripRow {
        let textReturn = returnStyle == .text

        func slots(undo: Bool, redo: Bool) -> [StripSlot] {
            var slots: [StripSlot] = [.expand]
            if showsGlobe { slots.append(.globe) }
            slots += [.magic, .mic]
            if undo { slots.append(.undo) }
            if redo { slots.append(.redo) }
            return slots + [.delete, .returnKey]
        }
        func weight(_ slot: StripSlot) -> Double {
            switch slot {
            case .mic: micWeight
            case .returnKey where textReturn: 0
            default: 1
            }
        }
        /// The width of a standard key for these slots.
        func share(_ slots: [StripSlot]) -> Double {
            let fixed = 2 * margin + Double(slots.count - 1) * gap + (textReturn ? textReturnWidth : 0)
            return max(width - fixed, 0) / slots.reduce(0) { $0 + weight($1) }
        }

        var showsUndo = true, showsRedo = true
        var row = slots(undo: true, redo: true)
        if share(row) < minKeyWidth {
            showsRedo = false
            row = slots(undo: true, redo: false)
        }
        if share(row) < minKeyWidth {
            showsUndo = false
            row = slots(undo: false, redo: false)
        }
        let key = share(row)

        var frames: [(slot: StripSlot, x: Double, width: Double)] = []
        var x = margin
        for slot in row {
            let w = slot == .returnKey && textReturn ? textReturnWidth : key * weight(slot)
            frames.append((slot, x, w))
            x += w + gap
        }
        let cells = frames.enumerated().map { index, f in
            let hitX = index == 0 ? 0 : f.x - gap / 2
            let hitMaxX = index == frames.count - 1 ? width : f.x + f.width + gap / 2
            return StripCell(slot: f.slot, x: f.x, width: f.width, hitX: hitX, hitWidth: hitMaxX - hitX)
        }
        return StripRow(cells: cells, showsUndo: showsUndo, showsRedo: showsRedo)
    }
}
