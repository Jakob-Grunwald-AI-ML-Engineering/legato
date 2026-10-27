import Foundation

/// How many word slots fit the room given to them, and which ranked suggestion each one shows.
public enum WordRowLayout {
    /// The narrowest a slot may be and still show a word.
    public static let minSlotWidth = 70.0

    /// Three slots, or only the best word when three would be narrower than ``minSlotWidth``.
    public static func visibleSlots(width: Double) -> Int { width >= 3 * minSlotWidth ? 3 : 1 }

    /// The rank (0 is the best) each slot shows, left to right: "2 | 1 | 3", or just the best.
    public static func ranks(visibleSlots: Int) -> [Int] { visibleSlots >= 3 ? [1, 0, 2] : [0] }
}
