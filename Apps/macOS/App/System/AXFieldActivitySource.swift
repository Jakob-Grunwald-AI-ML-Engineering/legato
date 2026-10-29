import ApplicationServices
import Foundation
import LegatoMac
import os

/// Value-changed and selected-text-changed notifications of one element, for `TypingGuard`. Notifications arrive
/// on the main run loop. If the observer cannot be set up, `start` logs why and returns false: the guard then
/// never sees activity (writes are not held, which `TypingGuard.isWatching` shows); every write is still checked
/// by readback.
///
/// The observer's refcon is a retained box with a weak reference back, released in `stop` (and on deinit), so a
/// notification that arrives late never reaches a freed object.
@MainActor
final class AXFieldActivitySource: FieldActivitySource {
    private static let log = Logger(subsystem: "de.gruenwald.legato", category: "typing-guard")
    private static let notifications = [kAXValueChangedNotification, kAXSelectedTextChangedNotification]

    /// What the observer's refcon points at (main-actor bound, like the callback that reads it).
    @MainActor private final class Box {
        weak var source: AXFieldActivitySource?
        init(_ source: AXFieldActivitySource) { self.source = source }
    }

    private let element: AXUIElement
    private let appElement: AXUIElement
    private var observer: AXObserver?
    private var box: Unmanaged<Box>?
    private var registered: [String] = []
    private var handler: (@MainActor () -> Void)?

    init(element: AXUIElement, appElement: AXUIElement) {
        self.element = element
        self.appElement = appElement
    }

    isolated deinit { stop() }

    @discardableResult
    func start(_ handler: @escaping @MainActor () -> Void) -> Bool {
        stop()
        var pid: pid_t = 0
        let pidError = AXUIElementGetPid(appElement, &pid)
        guard pidError == .success else {
            Self.log.error("Typing guard off: no pid for the field's app (AXError \(pidError.rawValue)).")
            return false
        }
        var created: AXObserver?
        let createError = AXObserverCreate(pid, Self.callback, &created)
        guard createError == .success, let created else {
            Self.log.error("Typing guard off: AXObserverCreate failed (AXError \(createError.rawValue)).")
            return false
        }
        let box = Unmanaged.passRetained(Box(self))
        var added: [String] = []
        for name in Self.notifications {
            let error = AXObserverAddNotification(created, element, name as CFString, box.toOpaque())
            if error == .success {
                added.append(name)
            } else {
                Self.log.error("Typing guard: cannot observe \(name, privacy: .public) (AXError \(error.rawValue)).")
            }
        }
        guard !added.isEmpty else {
            box.release()
            Self.log.error("Typing guard off: no notification of the field could be observed.")
            return false
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(created), .commonModes)
        observer = created
        self.box = box
        registered = added
        self.handler = handler
        return true
    }

    func stop() {
        if let observer {
            for name in registered { AXObserverRemoveNotification(observer, element, name as CFString) }
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        }
        box?.release()
        box = nil
        observer = nil
        registered = []
        handler = nil
    }

    private static let callback: AXObserverCallback = { _, _, _, refcon in
        guard let refcon else { return }
        let box = Unmanaged<Box>.fromOpaque(refcon).takeUnretainedValue()
        MainActor.assumeIsolated { box.source?.handler?() }
    }
}
