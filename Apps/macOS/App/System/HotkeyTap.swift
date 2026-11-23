import ApplicationServices
import CoreGraphics
import Foundation
import IOKit.hidsystem
import LegatoMac
import Synchronization

/// One key event as seen by the tap, with the time it was seen (`ProcessInfo.systemUptime`).
/// `event` is nil for "the tap was disabled and re-enabled": key events may have been lost, so
/// whatever the consumer believes about held keys can no longer be trusted.
struct TapSample: Sendable {
    var event: KeyEvent?
    var composerAction: MacComposerShortcut?
    var isCaptured = false
    var isRecordingBinding = false
    var time: TimeInterval
}

/// Bindings that the activity owns even when an action is temporarily unavailable.
struct ActivityShortcutScope: Sendable {
    var composer: [MacComposerShortcut: HotkeySpec]
    var speech: [HotkeySpec]

    func action(matching event: KeyEvent) -> MacComposerShortcut? {
        guard event.kind == .keyDown else { return nil }
        return MacComposerShortcut.chordActions.first { composer[$0]?.triggerEvent(for: event) == .pressed }
    }
}

/// State shared with the C callback. The callback runs on the tap's own thread and only yields
/// `Sendable` samples; `port` is written once, before the run loop source is installed.
private final class TapContext: @unchecked Sendable {
    let continuation: AsyncStream<TapSample>.Continuation
    var port: CFMachPort?
    let recording: @Sendable () -> Bool
    let scope: @Sendable () -> ActivityShortcutScope?
    var capture = ActivityHotkeyCapture()

    init(continuation: AsyncStream<TapSample>.Continuation, scope: @escaping @Sendable () -> ActivityShortcutScope?,
         recording: @escaping @Sendable () -> Bool) {
        self.continuation = continuation
        self.recording = recording
        self.scope = scope
    }
}

/// The tap's thread: owns the context for as long as the callback can run.
final class TapLoop: @unchecked Sendable {
    private let source: CFRunLoopSource
    private let context: AnyObject
    private let lock = NSLock()
    private var loop: CFRunLoop?
    private var stopped = false

    init(source: CFRunLoopSource, context: AnyObject) {
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

private extension ModifierKey {
    var deviceMask: CGEventFlags {
        let value: Int32
        switch self {
        case .leftCommand: value = NX_DEVICELCMDKEYMASK
        case .rightCommand: value = NX_DEVICERCMDKEYMASK
        case .leftOption: value = NX_DEVICELALTKEYMASK
        case .rightOption: value = NX_DEVICERALTKEYMASK
        case .leftControl: value = NX_DEVICELCTLKEYMASK
        case .rightControl: value = NX_DEVICERCTLKEYMASK
        case .leftShift: value = NX_DEVICELSHIFTKEYMASK
        case .rightShift: value = NX_DEVICERSHIFTKEYMASK
        case .function: value = 0
        }
        return CGEventFlags(rawValue: UInt64(value))
    }

    var aggregateMask: CGEventFlags { CGEventFlags(rawValue: UInt64(flag.rawValue)) }
}

private extension CGEventFlags {
    func isDown(_ key: ModifierKey) -> Bool {
        let sides = ModifierKey.allCases.filter { $0.flag == key.flag }
        if sides.contains(where: { !$0.deviceMask.isEmpty && contains($0.deviceMask) }) {
            return contains(key.deviceMask)
        }
        return contains(key.aggregateMask)
    }

    /// Keep the unowned side of a modifier available and stop a captured modifier from
    /// also becoming an application shortcut (or a modified click).
    func removing(_ captured: Set<ModifierKey>) -> CGEventFlags {
        var flags = self
        for key in captured {
            flags.subtract(key.deviceMask)
            let otherSideIsDown = ModifierKey.allCases.contains {
                $0 != key && $0.flag == key.flag && !$0.deviceMask.isEmpty && flags.contains($0.deviceMask)
            }
            if !otherSideIsDown { flags.subtract(key.aggregateMask) }
        }
        return flags
    }
}

/// C callback: decides consumption synchronously before Quartz forwards the event.
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
        context.capture.reset()
        if let port = context.port { CGEvent.tapEnable(tap: port, enable: true) }
        context.continuation.yield(TapSample(event: nil, time: ProcessInfo.processInfo.systemUptime))
        return Unmanaged.passUnretained(event)
    case .leftMouseDown, .rightMouseDown, .otherMouseDown:
        if !SyntheticEvent.isLegato(event.getIntegerValueField(.eventSourceUserData)) {
            RealInput.shared.bump(at: event.location)
            event.flags = event.flags.removing(context.capture.modifiers)
        }
        return Unmanaged.passUnretained(event)
    case .flagsChanged: kind = .flagsChanged
    case .keyDown: kind = .keyDown
    case .keyUp: kind = .keyUp
    default: return Unmanaged.passUnretained(event)
    }
    // Legato's own synthetic key events (typing, ⌘V) never count as the user's keys or chords.
    guard var keyEvent = HotkeyTapFilter.keyEvent(
        kind: kind, keyCode: UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode)),
        flagsRaw: event.flags.rawValue, userData: event.getIntegerValueField(.eventSourceUserData)
    ) else { return Unmanaged.passUnretained(event) }
    if kind == .flagsChanged, let key = ModifierKey(keyCode: keyEvent.keyCode) {
        keyEvent.modifierIsDown = event.flags.isDown(key)
    }

    let recording = context.recording()
    let scope = recording ? nil : context.scope()
    let hostFlags = event.flags.removing(context.capture.modifiers)
    var keyWithHostModifiers = keyEvent
    keyWithHostModifiers.flags = ModifierFlags(rawValue: UInt(hostFlags.rawValue))
    let speechPress = scope?.speech.contains { $0.triggerEvent(for: keyEvent) == .pressed } ?? false
    let action = speechPress ? nil : (scope?.action(matching: keyEvent) ?? scope?.action(matching: keyWithHostModifiers))
    let isRepeat = kind == .keyDown && event.getIntegerValueField(.keyboardEventAutorepeat) != 0
    let decision = context.capture.route(keyEvent, matches: action != nil || speechPress, isRepeat: isRepeat)
    guard decision != .suppressRepeat else { return nil }
    let captured = decision == .capture
    if !captured, kind == .keyDown { RealInput.shared.bump() }
    context.continuation.yield(TapSample(event: keyEvent, composerAction: captured ? action : nil,
        isCaptured: captured, isRecordingBinding: recording, time: ProcessInfo.processInfo.systemUptime))
    if captured { return nil }
    event.flags = hostFlags
    return Unmanaged.passUnretained(event)
}

/// An active `CGEventTap` for `flagsChanged`, `keyDown` and `keyUp` (and clicks, counted in `RealInput`), on its own thread so a busy
/// main thread (Accessibility calls can block for their timeout) never gets the tap disabled.
/// Samples arrive in order on `samples`.
@MainActor
final class HotkeyTap {
    private let scope = Mutex<ActivityShortcutScope?>(nil)
    nonisolated private func currentScope() -> ActivityShortcutScope? { scope.withLock { $0 } }
    func setScope(_ value: ActivityShortcutScope?) { scope.withLock { $0 = value } }
    private let recording = Mutex(false)
    nonisolated private func isRecording() -> Bool { recording.withLock { $0 } }
    func setRecording(_ active: Bool) { recording.withLock { $0 = active } }
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
        let context = TapContext(continuation: continuation, scope: { [weak self] in self?.currentScope() },
                                 recording: { [weak self] in self?.isRecording() == true })
        // Clicks only count as real input (`RealInput`); they are not samples.
        let mask: CGEventMask = [CGEventType.flagsChanged, .keyDown, .keyUp, .leftMouseDown, .rightMouseDown, .otherMouseDown]
            .reduce(0) { $0 | (1 << $1.rawValue) }
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
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
