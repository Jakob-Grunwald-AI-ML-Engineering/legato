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

    /// Foreground copies ignore the debug override; the DEBUG simulator can refuse an activity Copy.
    @discardableResult
    func forceWrite(_ text: String, source: String = "user") -> Bool {
        #if DEBUG
        // The simulator can exercise a dropped background Copy without changing foreground copy-last.
        if source == "activity-copy", Settings.debugForceTapToCopy {
            E2E.log("clipboard.write source=activity-copy changed=false forced=tapToCopy")
            return false
        }
        #endif
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
