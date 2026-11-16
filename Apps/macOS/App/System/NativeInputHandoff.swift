import ApplicationServices
import CoreGraphics
import Foundation
import LegatoMac
import LegatoKeyboardCore

/// The field queue's temporary native selection owns this process-scoped keyboard handoff.
/// Other processes and idle fields always pass through. Original events, including key-up,
/// repeat and modifier state, resume only after the queue confirms the user's caret.
final class NativeInputHandoff: @unchecked Sendable {
    static let shared = NativeInputHandoff()
    // User responsiveness requirement, split between native work and the reserved return home.
    static let budget = FieldEditCoordinator.inputResponseTargetMs / 1000
    private static let replayTag: Int64 = 0x4c454741544f4846
    private struct Held {
        let event: CGEvent
        let userData: Int64
    }
    private let lock = NSLock()
    private var lease = NativeInputLease()
    private var phase: NativeInputLease.Phase { lease.phase }
    private var fieldID: AnyHashable?
    private var pid: pid_t = 0
    private var port: CFMachPort?
    private var thread: TapLoop?
    private var held: [Held] = []
    private var posted: [Held] = []
    private var started = 0.0
    private var homing = false
    private var lastDuration = 0.0
    private var captured = 0
    private var replayed = 0
    private var failures = 0

    private init() {}

    @MainActor func begin(pid: pid_t, fieldID: AnyHashable) -> Bool {
        guard lock.withLock({ phase == .idle }) else { return false }
        if self.pid != pid || port == nil {
            if let port { CGEvent.tapEnable(tap: port, enable: false); CFMachPortInvalidate(port) }
            thread?.stop(); thread = nil; port = nil
            let mask = [CGEventType.keyDown, .keyUp, .flagsChanged].reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
            guard let port = CGEvent.tapCreateForPid(pid: pid, place: .headInsertEventTap, options: .defaultTap,
                eventsOfInterest: mask, callback: nativeInputCallback,
                userInfo: Unmanaged.passUnretained(self).toOpaque()),
                  let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0) else { return false }
            self.pid = pid; self.port = port
            let loop = TapLoop(source: source, context: self)
            let worker = Thread { loop.run() }
            worker.name = "de.gruenwald.legato.native-input"
            worker.qualityOfService = .userInteractive
            worker.start(); thread = loop
        }
        guard let port, CGEvent.tapIsEnabled(tap: port) else { return false }
        return lock.withLock {
            guard phase == .idle else { return false }
            started = ProcessInfo.processInfo.systemUptime; homing = false; self.fieldID = fieldID
            _ = lease.begin()
            return true
        }
    }

    /// A new dictation run: an earlier run's failure with nothing retained no longer blocks native edits.
    func beginRun() { lock.withLock { lease.beginRun(hasPendingEvents: !held.isEmpty || !posted.isEmpty) } }

    var protected: Bool { lock.withLock { phase == .borrowed } }
    func prepareHome() { lock.withLock { homing = true } }

    /// Cap each AX request by this unit's remaining work/return budget. No deadline
    /// expiration ever releases an event at an unverified temporary selection.
    func prepare(_ element: AXUIElement) throws {
        let remaining: Double? = lock.withLock {
            guard phase == .borrowed else { return nil }
            return started + (homing ? Self.budget : Self.budget / 2) - ProcessInfo.processInfo.systemUptime
        }
        if let remaining, remaining <= 0 { throw Deadline.expired }
        AXUIElementSetMessagingTimeout(element, Float(min(remaining ?? 0.25, 0.25)))
    }

    func finish(homeVerified: Bool) -> Bool {
        lock.withLock {
            guard phase == .borrowed else { return false }
            lastDuration = ProcessInfo.processInfo.systemUptime - started
            guard homeVerified else {
                failures += 1; lease.finish(homeVerified: false, hasPendingEvents: !held.isEmpty || !posted.isEmpty)
                return false // retained events and a failed unit; never a responsiveness pass
            }
            if lastDuration > Self.budget { failures += 1 }
            lease.finish(homeVerified: true, hasPendingEvents: !held.isEmpty || !posted.isEmpty)
            postHeld()
            return lastDuration <= Self.budget
        }
    }

    private func postHeld() {
        guard phase == .replaying, posted.isEmpty else { return }
        posted = held; held = []
        if posted.isEmpty { lease.drained(); return }
        for item in posted { item.event.postToPid(pid) }
    }

    /// Called on the event thread; never waits on Accessibility or the main actor.
    fileprivate func intercept(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        if SyntheticEvent.isLegato(event.getIntegerValueField(.eventSourceUserData)) { return Unmanaged.passUnretained(event) }
        return lock.withLock {
            if event.getIntegerValueField(.eventSourceUserData) == Self.replayTag, !posted.isEmpty {
                let original = posted.removeFirst()
                event.setIntegerValueField(.eventSourceUserData, value: original.userData)
                replayed += 1
                if posted.isEmpty, phase == .replaying { postHeld() }
                return Unmanaged.passUnretained(event)
            }
            guard lease.capturesInput else { return Unmanaged.passUnretained(event) }
            let copy = event.copy() ?? event // Held retains the original if copying is unavailable.
            let data = copy.getIntegerValueField(.eventSourceUserData)
            copy.setIntegerValueField(.eventSourceUserData, value: Self.replayTag)
            held.append(Held(event: copy, userData: data)); captured += 1
            return nil
        }
    }

    fileprivate func disabled() { lock.withLock { failures += 1; lease.disable(hasPendingEvents: !held.isEmpty || !posted.isEmpty) } }
    /// An explicit click can recover held-but-never-posted events. Unacknowledged
    /// posted events are uncertain and are never replayed a second time.
    @MainActor func recover(pid: pid_t, fieldID: AnyHashable, verifiedClick: Bool) -> Bool {
        guard let port else { return false }
        if !CGEvent.tapIsEnabled(tap: port) { CGEvent.tapEnable(tap: port, enable: true) }
        guard CGEvent.tapIsEnabled(tap: port) else { return false }
        return lock.withLock {
            guard self.pid == pid, self.fieldID == fieldID, posted.isEmpty,
                  lease.recover(verifiedClick: verifiedClick, hasPendingEvents: !held.isEmpty) else { return false }
            postHeld()
            return true
        }
    }

    var failureNotice: String? {
        lock.withLock {
            guard phase == .blocked else { return nil }
            return held.isEmpty && posted.isEmpty
                ? "Native edits stopped because the cursor could not be restored."
                : posted.isEmpty
                    ? "Cleanup paused. Pending keys are kept. Click the same field to restore them."
                    : "Cleanup paused. Pending key delivery could not be confirmed; keys will not be replayed automatically."
        }
    }
    var diagnostics: [String: Any] {
        lock.withLock {
            ["state": String(describing: phase), "captured": captured, "replayed": replayed,
             "held": held.count + posted.count, "failures": failures, "lastUnitMs": lastDuration * 1000]
        }
    }
    enum Deadline: Error { case expired }
}

private func nativeInputCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent,
                                 userInfo: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let owner = Unmanaged<NativeInputHandoff>.fromOpaque(userInfo).takeUnretainedValue()
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        owner.disabled(); return Unmanaged.passUnretained(event)
    }
    return owner.intercept(event)
}
