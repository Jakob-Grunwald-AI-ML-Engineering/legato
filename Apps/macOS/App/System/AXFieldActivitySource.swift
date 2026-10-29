import ApplicationServices
import Foundation
import LegatoMac

/// Value-changed and selected-text-changed notifications of one element, for `TypingGuard`. Notifications arrive
/// on the main run loop. If the observer cannot be set up the guard simply never sees activity (writes are not
/// held); every write is still checked by readback.
@MainActor
final class AXFieldActivitySource: FieldActivitySource {
    private let element: AXUIElement
    private let appElement: AXUIElement
    private var observer: AXObserver?
    private var handler: (@MainActor () -> Void)?

    private static let notifications = [kAXValueChangedNotification, kAXSelectedTextChangedNotification]

    init(element: AXUIElement, appElement: AXUIElement) {
        self.element = element
        self.appElement = appElement
    }

    func start(_ handler: @escaping @MainActor () -> Void) {
        stop()
        var pid: pid_t = 0
        guard AXUIElementGetPid(appElement, &pid) == .success else { return }
        var created: AXObserver?
        guard AXObserverCreate(pid, Self.callback, &created) == .success, let created else { return }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for name in Self.notifications { AXObserverAddNotification(created, element, name as CFString, refcon) }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(created), .commonModes)
        observer = created
        self.handler = handler
    }

    func stop() {
        if let observer {
            for name in Self.notifications { AXObserverRemoveNotification(observer, element, name as CFString) }
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        }
        observer = nil
        handler = nil
    }

    private static let callback: AXObserverCallback = { _, _, _, refcon in
        guard let refcon else { return }
        let source = Unmanaged<AXFieldActivitySource>.fromOpaque(refcon).takeUnretainedValue()
        MainActor.assumeIsolated { source.handler?() }
    }
}
