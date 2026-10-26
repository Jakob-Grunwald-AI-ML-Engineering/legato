#if DEBUG
import OSLog
import UIKit

/// Debug builds only: where the keys really are. The keyboard extension (a separate process) logs one
/// `kbd.geometry` line per layout pass to the app's e2e log category, and the simulator end-to-end run
/// asserts from it that every key row lies inside the visible keyboard. A Release build has none of it.
enum KeyboardGeometryLog {
    private static let logger = Logger(subsystem: "de.gruenwald.legato", category: "e2e")

    @MainActor static func report(grid: KeyGridView) {
        guard grid.bounds.height > 0, let window = grid.window else { return }
        let keys = grid.keyFrames.filter { $0.key != "globe" }.values
        guard let lowest = keys.map(\.maxY).max(), let highest = keys.map(\.minY).min() else { return }
        let inWindow = grid.convert(CGRect(x: 0, y: highest, width: grid.bounds.width, height: lowest - highest), to: window)
        let gridInWindow = grid.convert(grid.bounds, to: window)
        // Visible: the keys' lowest edge is inside the grid, and the grid inside the window (what is on screen).
        let inside = lowest <= grid.bounds.maxY + 0.5 && inWindow.minY >= -0.5 && inWindow.maxY <= window.bounds.height + 0.5
        let message = "kbd.geometry grid=\(format(grid.bounds)) gridInWindow=\(format(gridInWindow)) window=\(format(window.bounds)) "
            + "safe=\(format(grid.safeAreaInsets)) keysMinY=\(Int(highest.rounded())) keysMaxY=\(Int(lowest.rounded())) "
            + "keysInWindowMaxY=\(Int(inWindow.maxY.rounded())) visible=\(inside ? 1 : 0)"
        logger.notice("e2e \(message, privacy: .public)")
    }

    /// The controller's view and the height constraint that was asked for.
    @MainActor static func reportView(_ view: UIView, inputView: UIInputView?, heightConstraint: NSLayoutConstraint?) {
        let message = "kbd.view bounds=\(format(view.bounds)) frame=\(format(view.frame)) safe=\(format(view.safeAreaInsets)) "
            + "window=\(view.window.map { format($0.bounds) } ?? "none") constraint=\(Int(heightConstraint?.constant ?? 0))@\(Int(heightConstraint?.priority.rawValue ?? 0)) "
            + "inputView=\(inputView.map { format($0.frame) } ?? "none") superview=\(view.superview.map { format($0.frame) } ?? "none")"
        logger.notice("e2e \(message, privacy: .public)")
    }

    private static func format(_ r: CGRect) -> String {
        "\(Int(r.minX.rounded())),\(Int(r.minY.rounded())),\(Int(r.width.rounded()))x\(Int(r.height.rounded()))"
    }

    private static func format(_ i: UIEdgeInsets) -> String {
        "\(Int(i.top.rounded())),\(Int(i.left.rounded())),\(Int(i.bottom.rounded())),\(Int(i.right.rounded()))"
    }
}
#endif
