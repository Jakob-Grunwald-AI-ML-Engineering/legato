import Foundation

/// The scrollable dictation preview's rules (`TopRowLayout.preview`). Every number is an ESTIMATE to tune on the phone.
public enum PreviewScroll {
    /// Within this many points of the end the preview counts as scrolled to the bottom.
    public static let bottomTolerance = 4.0
    /// After the person scrolls up into older text and stops, the preview follows the newest words again after this long.
    public static let idleResumeSeconds = 3.0
    /// Above the first line, under the keyboard's rounded corner (`WordRowLayout.previewInset` clears it sideways).
    public static let topPadding = 4.0
    /// The soft fade at the top edge while older text is above.
    public static let topFadeHeight = 8.0
    /// The undo chip's height; the text keeps clear of it while it shows.
    public static let undoChipHeight = 28.0
    /// The least travel, in points, that is a swipe.
    public static let swipeDistance = 20.0

    public enum Swipe: Sendable, Equatable {
        /// Up, at the bottom: send what is said as spoken (no cleanup).
        case sendRaw
        /// Left: clear what is still in the preview.
        case clear
    }

    /// What a drag that has travelled (`dx`, `dy`) means, if anything. Up sends raw only when the drag began scrolled to the
    /// bottom (scrolled up, an upward drag scrolls); left must be horizontal-dominant (`|dx| > 2|dy|`). Other drags scroll.
    public static func swipe(dx: Double, dy: Double, startedAtBottom: Bool) -> Swipe? {
        if dy <= -swipeDistance, abs(dy) > 2 * abs(dx) { return startedAtBottom ? .sendRaw : nil }
        if dx <= -swipeDistance, abs(dx) > 2 * abs(dy) { return .clear }
        return nil
    }
}

/// Whether the preview follows its newest words as the text grows: it stops when the person scrolls up and resumes when they
/// come back to the bottom (`scrolled`) or after `PreviewScroll.idleResumeSeconds` without scrolling (`idleElapsed`).
public struct PreviewFollow: Sendable, Equatable {
    public private(set) var follows = true

    public init() {}

    public static func isAtBottom(distance: Double) -> Bool { distance <= PreviewScroll.bottomTolerance }

    /// The person scrolled and the end is now `distanceFromBottom` points away.
    public mutating func scrolled(distanceFromBottom: Double) { follows = Self.isAtBottom(distance: distanceFromBottom) }

    public mutating func idleElapsed() { follows = true }
}
