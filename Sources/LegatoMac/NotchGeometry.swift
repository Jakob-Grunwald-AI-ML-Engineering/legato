import Foundation

/// AppKit coordinates; safeTop remains valid when the menu bar auto-hides.
public enum NotchGeometry {
    public static func frame(screen: CGRect, visible: CGRect, safeTop: CGFloat, height requestedHeight: CGFloat = 360) -> CGRect {
        let width = min(580, screen.width - 24)
        let height = min(requestedHeight, visible.height - 24)
        let top = safeTop > 0 ? screen.maxY - safeTop : min(screen.maxY, visible.maxY) - 8
        return CGRect(x: screen.midX - width / 2, y: top - height, width: width, height: height)
    }
}
