import AppKit

/// Brings one of Legato's own windows (Settings, Meetings, onboarding) in front of the app the user is in.
///
/// Legato is a menu-bar app (`LSUIElement`). Its menu-bar window takes the keyboard without making Legato the active
/// app, and since macOS 14 `NSApp.activate()` is cooperative: with another app frontmost the request is usually
/// declined. SwiftUI then opens or reuses the window at normal level behind the frontmost app's windows, so a click on
/// Settings or Meetings seemed to do nothing. This asks for activation the forceful way, opens the window and then
/// orders it front regardless of activation, on the current Space.
@MainActor enum WindowPresenter {
    enum Target {
        case settings, window(id: String)

        func matches(_ window: NSWindow) -> Bool {
            let id = window.identifier?.rawValue ?? ""
            switch self {
            // SwiftUI's Settings scene window is `com_apple_SwiftUI_Settings_window`.
            case .settings: return id.hasPrefix("com_apple_SwiftUI_Settings")
            // SwiftUI names a `Window(id:)` scene's window after its id (sometimes with a suffix).
            case .window(let scene): return id == scene || id.hasPrefix(scene + "-")
            }
        }
    }

    static func present(_ target: Target, open: () -> Void) {
        forceActivate()
        open()
        bringForward(target, attempts: 20)
    }

    /// `activate(ignoringOtherApps:)` still takes the foreground for an accessory app where the cooperative
    /// `activate()` is declined; called through the protocol to keep its deprecation out of the build log.
    static func forceActivate() {
        (NSApp as any LegacyActivation).activate(ignoringOtherApps: true)
        NSApp.activate()
    }

    /// SwiftUI creates the window on a later turn of the run loop: look for it a few times.
    private static func bringForward(_ target: Target, attempts: Int) {
        if let window = NSApp.windows.first(where: target.matches) {
            window.collectionBehavior.insert(.moveToActiveSpace)
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
            forceActivate()
            return
        }
        guard attempts > 0 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { bringForward(target, attempts: attempts - 1) }
    }
}

/// The pre-macOS 14 activation call, without its deprecation warning at the call site.
@MainActor private protocol LegacyActivation { func activate(ignoringOtherApps flag: Bool) }
extension NSApplication: LegacyActivation {}
