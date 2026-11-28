import Foundation
import os
import UIKit

/// Keeps SwiftUI's custom drawing alive across the keyboard's shows. RenderBox, which draws a `TextRenderer` (the dictation
/// preview's text, `PreviewRenderer`) and the preview's other effects, stops drawing when UIKit posts
/// `didEnterBackgroundNotification` and starts again only at `willEnterForegroundNotification`. A keyboard extension gets the first
/// at some hides but, measured on the iOS 26 simulator, often not the second at the next show: from then on that drawing stays
/// blank for the rest of the process, every host included, while plain text, the keys and gestures work (#342). A keyboard on
/// screen is in the foreground, so it says so when UIKit did not: as it appears, and when the background arrives while it is shown.
/// That happens on a direct switch between apps: one process serves both, the next app's keyboard appears first and the last
/// app's hide brings the background some 0.75 s later, with the new keyboard on screen (measured on the iOS 26 simulator).
/// In every build; extension only (the app compiles `KeyboardUI` for its harness, never this).
@MainActor
enum KeyboardForeground {
    private static let log = Logger(subsystem: "de.gruenwald.legato", category: "keyboard-process")
    private static var observers: [any NSObjectProtocol] = []
    /// UIKit's last word was that the process entered the background.
    private static var inBackground = false
    private struct WeakHost { weak var value: UIViewController? }
    /// Keyboards between `viewWillAppear` and `viewWillDisappear`: the ones on screen, a hiding one excluded.
    private static var shown: [WeakHost] = []

    /// The first keyboard view to load calls it.
    static func start() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: nil) { _ in
                onMain {
                    inBackground = true
                    log.notice("entered background shown=\(shownCount)")
                    // On the next turn: RenderBox stops at its own observer of this notification, which can run after this
                    // one. A foreground posted from here comes first and is lost (measured: the preview stayed blank, noInk).
                    Task { @MainActor in restore(reason: "background arrived with a keyboard on screen") }
                }
            },
            center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: nil) { _ in
                onMain { inBackground = false }
            },
        ]
    }

    /// A keyboard is about to show (`viewWillAppear`, before its first frame): a background UIKit never ended ends now.
    static func keyboardWillAppear(_ host: UIViewController) {
        shown.removeAll { $0.value == nil || $0.value === host }
        shown.append(.init(value: host))
        restore(reason: "no willEnterForeground since the last didEnterBackground")
    }

    /// A keyboard is about to hide (`viewWillDisappear`): it no longer holds the process in the foreground.
    static func keyboardWillDisappear(_ host: UIViewController) {
        shown.removeAll { $0.value == nil || $0.value === host }
    }

    private static var shownCount: Int {
        shown.removeAll { $0.value == nil }
        return shown.count
    }

    /// Ends a background UIKit reported while a keyboard is on screen.
    private static func restore(reason: String) {
        guard inBackground, shownCount > 0 else { return }
        log.notice("foreground restored: \(reason, privacy: .public)")
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
