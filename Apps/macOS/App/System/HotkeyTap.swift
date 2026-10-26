import ApplicationServices
import CoreGraphics
import Foundation
import LegatoMac

/// One key event as seen by the tap, with the time it was seen (`ProcessInfo.systemUptime`).
/// `event` is nil for "the tap was disabled and re-enabled": key events may have been lost, so
/// whatever the consumer believes about held keys can no longer be trusted.
struct TapSample: Sendable {
    var event: KeyEvent?
    var time: TimeInterval
}

/// State shared with the C callback. The callback runs on the tap's own thread and only yields
/// `Sendable` samples; `port` is written once, before the run loop source is installed.
private final class TapContext: @unchecked Sendable {
    let continuation: AsyncStream<TapSample>.Continuation
    var port: CFMachPort?
    init(continuation: AsyncStream<TapSample>.Continuation) { self.continuation = continuation }
}

/// The tap's thread: owns the context for as long as the callback can run.
private final class TapLoop: @unchecked Sendable {
    private let source: CFRunLoopSource
    private let context: TapContext
    private let lock = NSLock()
    private var loop: CFRunLoop?
    private var stopped = false

    init(source: CFRunLoopSource, context: TapContext) {
        self.source = source
        self.context = context
    }

    func run() {
        let current = CFRunLoopGetCurrent()
        lock.lock()
        loop = current
        let done = stopped
        lock.unlock()
        guard !done else { return }
        CFRunLoopAddSource(current, source, .commonModes)
        // Poll the flag with a timeout so a stop that raced the start still ends the thread.
        while true {
            lock.lock()
            let done = stopped
            lock.unlock()
            if done { break }
            CFRunLoopRunInMode(.defaultMode, 1, false)
        }
        CFRunLoopRemoveSource(current, source, .commonModes)
    }

    func stop() {
        lock.lock()
        stopped = true
        let current = loop
        lock.unlock()
        if let current { CFRunLoopStop(current) }
    }
}

/// C callback: nonisolated, touches only the `Sendable` continuation.
private func hotkeyTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let context = Unmanaged<TapContext>.fromOpaque(userInfo).takeUnretainedValue()
    let kind: KeyEvent.Kind
    switch type {
    case .tapDisabledByTimeout, .tapDisabledByUserInput:
        if let port = context.port { CGEvent.tapEnable(tap: port, enable: true) }
        context.continuation.yield(TapSample(event: nil, time: ProcessInfo.processInfo.systemUptime))
        return Unmanaged.passUnretained(event)
    case .flagsChanged: kind = .flagsChanged
    case .keyDown: kind = .keyDown
    case .keyUp: kind = .keyUp
    default: return Unmanaged.passUnretained(event)
    }
    // Device-independent modifier bits only; the low 16 bits are per-side hardware flags.
    let flags = ModifierFlags(rawValue: UInt(truncatingIfNeeded: event.flags.rawValue) & 0xFFFF_0000)
    let keyCode = UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode))
    let sample = TapSample(event: KeyEvent(kind: kind, keyCode: keyCode, flags: flags), time: ProcessInfo.processInfo.systemUptime)
    context.continuation.yield(sample)
    return Unmanaged.passUnretained(event)
}

/// A listen-only `CGEventTap` for `flagsChanged`, `keyDown` and `keyUp`, on its own thread so a busy
/// main thread (Accessibility calls can block for their timeout) never gets the tap disabled.
/// Samples arrive in order on `samples`.
@MainActor
final class HotkeyTap {
    let samples: AsyncStream<TapSample>
    private let continuation: AsyncStream<TapSample>.Continuation
    private var port: CFMachPort?
    private var loop: TapLoop?

    var isActive: Bool { port != nil }

    init() {
        (samples, continuation) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
    }

    /// Creates the tap; false when macOS refuses (Accessibility or Input Monitoring is missing).
    @discardableResult
    func start() -> Bool {
        guard port == nil else { return true }
        let context = TapContext(continuation: continuation)
        let mask: CGEventMask = [CGEventType.flagsChanged, .keyDown, .keyUp].reduce(0) { $0 | (1 << $1.rawValue) }
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: hotkeyTapCallback,
            userInfo: Unmanaged.passUnretained(context).toOpaque()
        ), let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0) else {
            return false
        }
        context.port = port
        let loop = TapLoop(source: source, context: context)
        let thread = Thread { loop.run() }
        thread.name = "de.gruenwald.legato.hotkey-tap"
        thread.qualityOfService = .userInteractive
        thread.start()
        self.port = port
        self.loop = loop
        return true
    }

    func stop() {
        guard let port else { return }
        CGEvent.tapEnable(tap: port, enable: false)
        CFMachPortInvalidate(port)
        loop?.stop()
        self.port = nil
        loop = nil
    }

    /// Whether macOS still delivers events to the tap (false after it was revoked or disabled).
    var isEnabled: Bool {
        guard let port else { return false }
        return CGEvent.tapIsEnabled(tap: port)
    }
}
