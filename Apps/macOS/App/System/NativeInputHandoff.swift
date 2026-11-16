import ApplicationServices
import CoreGraphics
import Foundation
import LegatoMac

/// The field queue's temporary native selection owns this process-scoped keyboard handoff.
/// Other processes and idle fields always pass through. Original events, including key-up,
/// repeat and modifier state, resume only after the queue confirms the user's caret.
final class NativeInputHandoff: @unchecked Sendable {
    static let shared = NativeInputHandoff()
    // User responsiveness requirement, split between native work and the reserved return home.
    static let budget = 0.5
    private static let replayTag: Int64 = 0x4c454741544f4846
    private struct Held {
        let event: CGEvent
        let userData: Int64
    }
    private enum Phase { case idle, borrowed, replaying, blocked }
    private let lock = NSLock()
    private var phase = Phase.idle
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

    @MainActor func begin(pid: pid_t) -> Bool {
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
            started = ProcessInfo.processInfo.systemUptime; homing = false; phase = .borrowed
            return true
        }
    }

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
                failures += 1; phase = .blocked
                return false // retained events and a failed unit; never a responsiveness pass
            }
            if lastDuration > Self.budget { failures += 1 }
            phase = .replaying
            postHeld()
            return lastDuration <= Self.budget
        }
    }

    private func postHeld() {
        guard posted.isEmpty else { return }
        posted = held; held = []
        if posted.isEmpty { phase = .idle; return }
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
                if posted.isEmpty { postHeld() }
                return Unmanaged.passUnretained(event)
            }
            guard phase != .idle else { return Unmanaged.passUnretained(event) }
            let copy = event.copy() ?? event // Held retains the original if copying is unavailable.
            let data = copy.getIntegerValueField(.eventSourceUserData)
            copy.setIntegerValueField(.eventSourceUserData, value: Self.replayTag)
            held.append(Held(event: copy, userData: data)); captured += 1
            return nil
        }
    }

    fileprivate func disabled() { lock.withLock { failures += 1; phase = .blocked } }
    var failureNotice: String? {
        lock.withLock {
            guard phase == .blocked else { return nil }
            return held.isEmpty && posted.isEmpty
                ? "Native edits stopped because the cursor could not be restored."
                : "Typing is paused because the cursor could not be restored. Pending key events are retained."
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
