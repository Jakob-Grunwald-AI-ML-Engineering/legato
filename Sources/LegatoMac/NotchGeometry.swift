import Foundation

/// AppKit coordinates; safeTop remains valid when the menu bar auto-hides.
public enum NotchGeometry {
    /// Width of the concave flare on each side of an island attached to the notch.
    public static let shoulder: CGFloat = 16
    public static let fallbackNotchWidth: CGFloat = 185

    /// The card below the notch (or below the menu bar without one).
    public static func frame(screen: CGRect, visible: CGRect, safeTop: CGFloat, width requestedWidth: CGFloat = 580, height requestedHeight: CGFloat = 360) -> CGRect {
        let width = min(requestedWidth, screen.width - 24)
        let height = min(requestedHeight, visible.height - 24)
        let top = safeTop > 0 ? screen.maxY - safeTop : min(screen.maxY, visible.maxY) - 8
        return CGRect(x: screen.midX - width / 2, y: top - height, width: width, height: height)
    }

    /// The window of an island: on a notch screen it reaches `screen.maxY` and includes `safeTop` and both shoulders
    /// around a card of `height`; elsewhere it is the plain card.
    public static func island(screen: CGRect, visible: CGRect, safeTop: CGFloat, width requestedWidth: CGFloat = 580, height requestedHeight: CGFloat = 360) -> CGRect {
        guard safeTop > 0 else { return frame(screen: screen, visible: visible, safeTop: 0, width: requestedWidth, height: requestedHeight) }
        let width = min(requestedWidth + 2 * shoulder, screen.width - 24)
        let height = safeTop + min(requestedHeight, visible.height - 24)
        return CGRect(x: screen.midX - width / 2, y: screen.maxY - height, width: width, height: height)
    }

    /// The hardware notch between the two auxiliary menu-bar areas; `fallback` when either is unknown.
    public static func notchWidth(left: CGRect?, right: CGRect?, fallback: CGFloat = fallbackNotchWidth) -> CGFloat {
        guard let left, let right, right.minX > left.maxX else { return fallback }
        return right.minX - left.maxX
    }
}
