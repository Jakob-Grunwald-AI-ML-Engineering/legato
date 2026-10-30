import Foundation

/// AppKit coordinates; safeTop remains valid when the menu bar auto-hides.
public enum NotchGeometry {
    public static func frame(screen: CGRect, visible: CGRect, safeTop: CGFloat) -> CGRect {
        let width = min(580, screen.width - 24)
        let height = min(360, visible.height - 24)
        let top = safeTop > 0 ? screen.maxY - safeTop : min(screen.maxY, visible.maxY) - 8
        return CGRect(x: screen.midX - width / 2, y: top - height, width: width, height: height)
    }
}
