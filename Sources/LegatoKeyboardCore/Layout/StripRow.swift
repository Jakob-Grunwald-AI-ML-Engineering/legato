import Foundation

/// What the strip's row holds, left to right in this order (the globe only when iOS asks for it).
public enum StripSlot: Sendable, Equatable, Hashable {
    case expand, globe, status, delete, returnKey, mic
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

/// The compact strip's single row for a keyboard width: chevron · globe? · status · delete · return · mic.
/// The mic pill keeps its full size and the right margin at every width; the keys give way first, then
/// the status. The touch areas tile the whole width (each gap is split in the middle; the chevron and the
/// mic reach the screen edges), so the mic pill stays easy to hit.
public struct StripRow: Sendable, Equatable {
    public static let margin = 8.0
    public static let gap = 8.0
    public static let keyWidth = 44.0
    /// The smallest a key shrinks to while the status still gets its minimum.
    public static let minKeyWidth = 40.0
    public static let textReturnWidth = 60.0
    public static let pillWidth = 81.0
    /// The narrowest the status text is shown at; narrower, it is hidden.
    public static let minStatusWidth = 56.0

    public let cells: [StripCell]
    /// Whether the status cell is wide enough to show its text.
    public let statusTextVisible: Bool

    public static func make(width: Double, showsGlobe: Bool, returnStyle: StripReturnStyle) -> StripRow {
        var slots: [StripSlot] = [.expand]
        if showsGlobe { slots.append(.globe) }
        slots += [.status, .delete, .returnKey, .mic]

        let textReturn = returnStyle == .text
        // Slots that give way: the chevron, the globe, delete and a glyph return.
        let flexible = slots.filter { $0 == .expand || $0 == .globe || $0 == .delete || ($0 == .returnKey && !textReturn) }.count
        let fixed = 2 * margin + Double(slots.count - 1) * gap + pillWidth + (textReturn ? textReturnWidth : 0)
        let available = width - fixed
        let count = Double(flexible)

        var key = keyWidth
        if available - count * key < minStatusWidth {
            let shrunk = (available - minStatusWidth) / count
            // Keys shrink only while that buys the status its minimum; otherwise they keep their size and
            // the status hides, down to whatever the width allows.
            key = shrunk >= minKeyWidth ? shrunk : max(min(keyWidth, available / count), 0)
        }
        let status = max(available - count * key, 0)

        func slotWidth(_ slot: StripSlot) -> Double {
            switch slot {
            case .status: status
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
        return StripRow(cells: cells, statusTextVisible: status >= minStatusWidth)
    }
}
