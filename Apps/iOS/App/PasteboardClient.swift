import LegatoCore
import UIKit

/// The clipboard port: writes the pasteboard and reports whether it actually changed, by comparing
/// its change count (a write from the background can be silently dropped).
@MainActor
final class PasteboardClient: Clipboard {
    func write(_ text: String) -> Bool {
        if Settings.debugForceTapToCopy { return false }
        return forceWrite(text)
    }

    /// Writes regardless of the debug override. For user-initiated copies in the foreground.
    @discardableResult
    func forceWrite(_ text: String) -> Bool {
        let pasteboard = UIPasteboard.general
        let before = pasteboard.changeCount
        pasteboard.string = text
        return pasteboard.changeCount != before
    }
}
