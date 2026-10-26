import Foundation

/// Turns the trigger key's press/release stream into dictation actions. Pure and `Sendable`;
/// the caller supplies monotonic timestamps (seconds) and acts on the returned `Action`.
///
/// **Start is debounced.** Pressing the trigger does not start anything: a press may turn out
/// to be the first half of a shortcut chord (Right ⌘+C), and a chord must never start dictation.
/// The run starts (`.start`) when the trigger has been down alone for `armDelay` (the caller
/// asks `armDeadline`, sleeps until then and calls `tick(at:)`), or, for a tap released before
/// that, on its release (hybrid and toggle; a hold-mode tap shorter than `armDelay` does
/// nothing). Another key going down before the run starts drops the press silently. A chord
/// after the start emits `.cancel`, which the caller must treat as "abort the run and discard
/// everything it produced".
///
/// The caller should call `tick(at:)` with each event's time before feeding the event, so a
/// timer that fired late cannot reorder things.
///
/// **Stop on release.** Stopping a latched run happens when the stopping tap is released, not
/// when it goes down, so a chord pressed during that tap (Right ⌘+C while dictating) leaves the
/// run alone.
///
/// - `hybrid` (default): a press released before `tapThreshold` latches the run on, the next
///   tap stops it; a press held at least `tapThreshold` is push-to-talk and stops on release.
/// - `toggle`: the first press starts and latches, the next tap stops, whatever the duration.
/// - `hold`: push-to-talk only; release stops, however short.
///
/// Call `runEnded()` only when a run ended *without* this gesture asking for it (engine abort,
/// start failure): it drops a latch and makes the release of a press in progress inert.
/// Call `reset()` when events may have been lost (the event tap was restarted).
public struct HotkeyGesture: Sendable, Equatable {
    public enum Mode: String, Sendable, Codable, CaseIterable { case hybrid, toggle, hold }
    public enum Action: Sendable, Equatable { case start, stop, cancel }

    public static let defaultTapThreshold: TimeInterval = 0.35
    public static let defaultArmDelay: TimeInterval = 0.2

    public let mode: Mode
    public let tapThreshold: TimeInterval
    public let armDelay: TimeInterval

    private enum Phase: Sendable, Equatable {
        /// No run owned by the gesture, trigger up.
        case idle
        /// Trigger down since `since`, nothing started yet (waiting out `armDelay`).
        case pending(since: TimeInterval)
        /// Trigger down, this press started the run.
        case holding(since: TimeInterval)
        /// Run continues after the trigger was released; the next tap stops it.
        case latched
        /// Trigger down on a latched run; its release stops, unless a chord spoiled the tap.
        case stopping(chorded: Bool)
        /// Trigger down, but the press owns no run (cancelled or ended); its release does nothing.
        case spent
    }
    private var phase = Phase.idle

    public init(
        mode: Mode = .hybrid,
        tapThreshold: TimeInterval = HotkeyGesture.defaultTapThreshold,
        armDelay: TimeInterval = HotkeyGesture.defaultArmDelay
    ) {
        self.mode = mode
        self.tapThreshold = tapThreshold
        self.armDelay = armDelay
    }

    /// When the caller should call `tick(at:)` next; nil when no press is waiting to start.
    public var armDeadline: TimeInterval? {
        if case .pending(let since) = phase { return since + armDelay }
        return nil
    }

    /// Whether the trigger is currently held, as far as this gesture knows.
    public var isTriggerDown: Bool {
        switch phase {
        case .idle, .latched: false
        case .pending, .holding, .stopping, .spent: true
        }
    }

    /// Time passed: a press held alone for `armDelay` starts the run.
    public mutating func tick(at time: TimeInterval) -> Action? {
        // Timers fire a hair early now and then; a microsecond of slack keeps the start from being lost.
        guard case .pending(let since) = phase, time - since >= armDelay - 1e-6 else { return nil }
        phase = .holding(since: since)
        return .start
    }

    /// Forget everything: events were lost, so a held trigger or a latch can no longer be trusted.
    public mutating func reset() {
        phase = .idle
    }

    /// The trigger went down. Repeat presses (key auto-repeat) while it is already down are ignored.
    public mutating func pressed(at time: TimeInterval) -> Action? {
        switch phase {
        case .idle:
            phase = .pending(since: time)
            return nil
        case .latched:
            phase = .stopping(chorded: false)
            return nil
        case .pending, .holding, .stopping, .spent:
            return nil
        }
    }

    /// The trigger went up.
    public mutating func released(at time: TimeInterval) -> Action? {
        switch phase {
        case .pending(let since):
            // Released before the timer started the run (or the timer is late).
            switch mode {
            case .hold:
                phase = .idle
                return nil
            case .toggle:
                phase = .latched
                return .start
            case .hybrid:
                if time - since < tapThreshold {
                    phase = .latched
                    return .start
                }
                phase = .idle
                return nil
            }
        case .holding(let since):
            switch mode {
            case .hold:
                phase = .idle
                return .stop
            case .toggle:
                phase = .latched
                return nil
            case .hybrid:
                if time - since < tapThreshold {
                    phase = .latched
                    return nil
                }
                phase = .idle
                return .stop
            }
        case .stopping(let chorded):
            if chorded {
                phase = .latched
                return nil
            }
            phase = .idle
            return .stop
        case .spent:
            phase = .idle
            return nil
        case .idle, .latched:
            return nil
        }
    }

    /// Any other key went down. While the trigger is held this is a chord: a run this press
    /// started is cancelled; a stopping tap is spoiled and the run keeps going.
    public mutating func otherKeyDown() -> Action? {
        switch phase {
        case .pending:
            phase = .spent // never started: nothing to cancel
            return nil
        case .holding:
            phase = .spent
            return .cancel
        case .stopping:
            phase = .stopping(chorded: true)
            return nil
        case .idle, .latched, .spent:
            return nil
        }
    }

    /// The run ended without the gesture asking for it.
    public mutating func runEnded() {
        switch phase {
        case .idle, .latched:
            phase = .idle
        case .pending:
            break
        case .holding, .stopping, .spent:
            phase = .spent
        }
    }
}
