import Foundation

/// How many word slots fit the transcript area, which ranked suggestion each one shows, and the area's text insets.
public enum WordRowLayout {
    /// The horizontal inset of the transcript's content (status, preview) on the dictation key's side, in points: the key is
    /// half a gap away, so the text starts about 11 pt from its face.
    public static let contentInset = 8.0

    /// The radius of the keyboard's rounded top corners, in points. An estimate of the system keyboard container's corner on
    /// current iPhones, not measured; the preview's first line sits right under it.
    public static let keyboardCornerRadius = 20.0

    /// The inset on the far side, at the keyboard's edge: clear of the rounded top corner (0.8 of the radius is enough for a
    /// line 8 pt below the top edge), never less than ``contentInset``.
    public static let previewInset = max(contentInset, 0.8 * keyboardCornerRadius)

    /// The transcript's leading and trailing text insets: the corner's on the far side, the key's on the dictation key's side.
    public static func insets(keySide: DictationKeySide) -> (leading: Double, trailing: Double) {
        keySide == .right ? (previewInset, contentInset) : (contentInset, previewInset)
    }

    /// The narrowest a slot may be and still show a common word at 17 pt without shrinking it much: an ESTIMATE.
    public static let minSlotWidth = 110.0

    /// Three slots when they fit, else two, else only the best word (the transcript beside the dictation key: two on phones in
    /// portrait).
    public static func visibleSlots(width: Double) -> Int {
        width >= 3 * minSlotWidth ? 3 : width >= 2 * minSlotWidth ? 2 : 1
    }

    /// The rank (0 is the best) each slot shows, left to right: "2 | 1 | 3", "1 | 2", or just the best.
    public static func ranks(visibleSlots: Int) -> [Int] {
        switch visibleSlots {
        case 3...: [1, 0, 2]
        case 2: [0, 1]
        default: [0]
        }
    }
}
