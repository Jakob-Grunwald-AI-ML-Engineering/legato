import Foundation

/// How many word slots fit the room given to them, and which ranked suggestion each one shows.
public enum WordRowLayout {
    /// The horizontal inset of the word row's content (status, kept text, preview), in points.
    public static let contentInset = 8.0

    /// The radius of the keyboard's rounded top corners, in points. An estimate of the system keyboard container's corner on
    /// current iPhones, not measured; the preview's first line sits right under it.
    public static let keyboardCornerRadius = 20.0

    /// The horizontal inset of the dictation preview: clear of the rounded top corners (0.8 of the radius is enough for a line
    /// 8 pt below the top edge), never less than ``contentInset``.
    public static let previewInset = max(contentInset, 0.8 * keyboardCornerRadius)

    /// The narrowest a slot may be and still show a word.
    public static let minSlotWidth = 70.0

    /// Three slots, or only the best word when three would be narrower than ``minSlotWidth``.
    public static func visibleSlots(width: Double) -> Int { width >= 3 * minSlotWidth ? 3 : 1 }

    /// The rank (0 is the best) each slot shows, left to right: "2 | 1 | 3", or just the best.
    public static func ranks(visibleSlots: Int) -> [Int] { visibleSlots >= 3 ? [1, 0, 2] : [0] }
}
