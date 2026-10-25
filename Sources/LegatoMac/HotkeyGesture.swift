import Foundation

/// Turns the trigger key's press/release stream into dictation actions. Pure and `Sendable`;
/// the caller supplies monotonic timestamps (seconds) and acts on the returned `Action`.
///
/// **Start on press.** `.start` fires the instant the trigger goes down, for the lowest latency.
/// Whether the press turns out to be a tap, a hold or the start of a shortcut chord (Right ⌘+C)
/// is only known later; a chord emits `.cancel`, which the caller must treat as "abort the run
/// and discard everything it produced" (nothing inserted, nothing saved).
///
/// **Stop on release.** Stopping a latched run happens when the stopping tap is released, not
/// when it goes down, so a chord pressed during that tap (Right ⌘+C while dictating) leaves the
/// run alone.
///
/// - `hybrid` (default): a press shorter than `tapThreshold` latches the run on, the next tap
///   stops it; a press held at least `tapThreshold` is push-to-talk and stops on release.
/// - `toggle`: every first press starts and latches, the next tap stops, whatever the duration.
/// - `hold`: push-to-talk only; release stops, however short.
///
/// Call `runEnded()` only when a run ended *without* this gesture asking for it (engine abort,
/// start failure): it drops a latch and makes the release of a press in progress inert.
public struct HotkeyGesture: Sendable, Equatable {
    public enum Mode: String, Sendable, Codable, CaseIterable { case hybrid, toggle, hold }
    public enum Action: Sendable, Equatable { case start, stop, cancel }

    public static let defaultTapThreshold: TimeInterval = 0.35

    public let mode: Mode
    public let tapThreshold: TimeInterval

    private enum Phase: Sendable, Equatable {
        /// No run owned by the gesture, trigger up.
        case idle
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

    public init(mode: Mode = .hybrid, tapThreshold: TimeInterval = HotkeyGesture.defaultTapThreshold) {
        self.mode = mode
        self.tapThreshold = tapThreshold
    }

    /// The trigger went down. Repeat presses (key auto-repeat) while it is already down are ignored.
    public mutating func pressed(at time: TimeInterval) -> Action? {
        switch phase {
        case .idle:
            phase = .holding(since: time)
            return .start
        case .latched:
            phase = .stopping(chorded: false)
            return nil
        case .holding, .stopping, .spent:
            return nil
        }
    }

    /// The trigger went up.
    public mutating func released(at time: TimeInterval) -> Action? {
        switch phase {
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
        case .holding, .stopping, .spent:
            phase = .spent
        }
    }
}
