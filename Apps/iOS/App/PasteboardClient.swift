import LegatoCore
import UIKit

/// The clipboard port: writes the pasteboard and reports whether it actually changed, by comparing
/// its change count (a write from the background can be silently dropped).
@MainActor
final class PasteboardClient: Clipboard {
    func write(_ text: String) -> Bool {
        if Settings.debugForceTapToCopy {
            #if DEBUG
            E2E.log("clipboard.write source=coordinator changed=false forced=tapToCopy")
            #endif
            return false
        }
        return forceWrite(text, source: "coordinator")
    }

    /// Writes regardless of the debug override. For user-initiated copies in the foreground.
    @discardableResult
    func forceWrite(_ text: String, source: String = "user") -> Bool {
        let pasteboard = UIPasteboard.general
        let before = pasteboard.changeCount
        pasteboard.string = text
        let changed = pasteboard.changeCount != before
        #if DEBUG
        E2E.log("clipboard.write source=\(source) changed=\(changed) text=\(E2E.quote(text))")
        #endif
        return changed
    }
}
