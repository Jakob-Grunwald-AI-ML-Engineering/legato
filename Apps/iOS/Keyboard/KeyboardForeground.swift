import Foundation
import os
import UIKit

/// Keeps SwiftUI's custom drawing alive across the keyboard's shows. RenderBox, which draws a `TextRenderer` (the dictation
/// preview's text, `PreviewRenderer`) and the preview's other effects, stops drawing when UIKit posts
/// `didEnterBackgroundNotification` and starts again only at `willEnterForegroundNotification`. A keyboard extension gets the first
/// at some hides but, measured on the iOS 26 simulator, often not the second at the next show: from then on that drawing stays
/// blank for the rest of the process, every host included, while plain text, the keys and gestures work (#342). A keyboard that
/// appears is in the foreground, so it says so when UIKit did not.
/// In every build; extension only (the app compiles `KeyboardUI` for its harness, never this).
@MainActor
enum KeyboardForeground {
    private static let log = Logger(subsystem: "de.gruenwald.legato", category: "keyboard-process")
    private static var observers: [any NSObjectProtocol] = []
    /// UIKit's last word was that the process entered the background.
    private static var inBackground = false

    /// The first keyboard view to load calls it.
    static func start() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: nil) { _ in
                onMain { inBackground = true }
            },
            center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: nil) { _ in
                onMain { inBackground = false }
            },
        ]
    }

    /// A keyboard is about to show (`viewWillAppear`, before its first frame): a background UIKit never ended ends now.
    static func keyboardWillAppear() {
        guard inBackground else { return }
        log.notice("foreground restored: no willEnterForeground since the last didEnterBackground")
        #if DEBUG || LEGATO_INTERNAL
        PreviewDiagnostics.keyboard.record(.foregroundRestored, census: true)
        #endif
        // The observer above clears `inBackground`.
        NotificationCenter.default.post(name: UIApplication.willEnterForegroundNotification, object: nil)
    }

    /// UIKit posts these on the main thread; the hop is only a fallback.
    private nonisolated static func onMain(_ body: @escaping @MainActor () -> Void) {
        if Thread.isMainThread { MainActor.assumeIsolated(body) } else { DispatchQueue.main.async(execute: body) }
    }
}
