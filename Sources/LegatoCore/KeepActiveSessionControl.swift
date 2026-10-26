import Foundation
import Synchronization

/// An `AudioSessionControlling` that can leave the platform audio session active between runs, so the
/// next run does not have to activate it again. Wraps the real controller.
///
/// Why it exists: iOS refuses to change the category or options of an *active* session from the
/// background (`'!int'`), even to the same values, and a background start has no other way to begin.
/// So a held session is reused as is: while it is held and still has a live input, `activate` re-runs
/// nothing when the requested configuration is the one in place, and when a different one is asked for
/// and the system refuses it, the start carries on under the configuration in place (a refusal there is
/// no reason to open the app). A held session whose input route is gone is dead: it is deactivated for
/// real and activated from scratch.
///
/// While the session is held, other apps' audio stays lowered (or paused) as the last policy left it.
public final class KeepActiveSessionControl: AudioSessionControlling, Sendable {
    /// What `activate` did, for diagnostics.
    public enum Activation: Sendable {
        /// The platform session was activated (nothing was held).
        case activated
        /// The held session already had this configuration: nothing was touched.
        case reused
        /// The held session was reconfigured to this configuration.
        case reconfigured
        /// A reconfigure of the held session was refused (with the error); the start goes on under the
        /// configuration in place.
        case keptCurrent(any Error)
        /// The held session had lost its input: it was deactivated and activated again.
        case reactivated
    }

    public enum Event: Sendable {
        case activate(requested: SessionConfig, wasHeld: Bool, result: Activation)
        case activateFailed(requested: SessionConfig, wasHeld: Bool, error: any Error)
        case deactivateSkipped
        case deactivated
        case released(reason: String, wasHeld: Bool)
    }

    private struct State {
        /// A deactivate was skipped and nothing has activated the session since.
        var held = false
        /// The configuration the platform session has now (nil: not active).
        var current: SessionConfig?
        /// The next deactivate must really happen (a system event ended the run).
        var releaseRequested = false
    }

    private let inner: any AudioSessionControlling
    private let keepActive: @Sendable () -> Bool
    private let hasLiveInput: @Sendable () -> Bool
    private let isRefusal: @Sendable (any Error) -> Bool
    private let observer: (@Sendable (Event) -> Void)?
    private let state = Mutex(State())

    /// - Parameters:
    ///   - keepActive: whether a normal deactivate is skipped right now (read at every deactivate).
    ///   - hasLiveInput: whether the active session still has an input route.
    ///   - isRefusal: whether an activation error is the system refusing to change a session from the
    ///     background.
    public init(
        inner: any AudioSessionControlling,
        keepActive: @escaping @Sendable () -> Bool,
        hasLiveInput: @escaping @Sendable () -> Bool = { true },
        isRefusal: @escaping @Sendable (any Error) -> Bool = { _ in false },
        observer: (@Sendable (Event) -> Void)? = nil
    ) {
        self.inner = inner
        self.keepActive = keepActive
        self.hasLiveInput = hasLiveInput
        self.isRefusal = isRefusal
        self.observer = observer
    }

    /// A normal stop skipped its deactivate and nothing has activated the session since.
    public var isHeld: Bool { state.withLock { $0.held } }

    public var supportedPolicies: Set<AudioPolicy> { inner.supportedPolicies }

    public func activate(_ config: SessionConfig) throws {
        let (wasHeld, current) = state.withLock { s in
            defer { s.held = false; s.releaseRequested = false }
            return (s.held, s.current)
        }
        guard wasHeld, let current else {
            try activateFresh(config, wasHeld: wasHeld, result: .activated)
            return
        }
        // A held session whose input route is gone is dead: start over rather than reuse it.
        guard hasLiveInput() else {
            inner.deactivate()
            state.withLock { $0.current = nil }
            observer?(.deactivated)
            try activateFresh(config, wasHeld: true, result: .reactivated)
            return
        }
        if current == config {
            observer?(.activate(requested: config, wasHeld: true, result: .reused))
            return
        }
        do {
            try inner.activate(config)
            state.withLock { $0.current = config }
            observer?(.activate(requested: config, wasHeld: true, result: .reconfigured))
        } catch {
            guard isRefusal(error) else {
                observer?(.activateFailed(requested: config, wasHeld: true, error: error))
                throw error
            }
            observer?(.activate(requested: config, wasHeld: true, result: .keptCurrent(error)))
        }
    }

    private func activateFresh(_ config: SessionConfig, wasHeld: Bool, result: Activation) throws {
        do {
            try inner.activate(config)
            state.withLock { $0.current = config }
            observer?(.activate(requested: config, wasHeld: wasHeld, result: result))
        } catch {
            observer?(.activateFailed(requested: config, wasHeld: wasHeld, error: error))
            throw error
        }
    }

    public func deactivate() {
        let keep = keepActive()
        let skip = state.withLock { s in
            let skip = keep && !s.releaseRequested
            if skip { s.held = true } else { s.held = false; s.releaseRequested = false }
            return skip
        }
        if skip {
            observer?(.deactivateSkipped)
            return
        }
        inner.deactivate()
        state.withLock { $0.current = nil }
        observer?(.deactivated)
    }

    /// The system took the microphone (interruption, media reset, lost input): make sure the session is
    /// really deactivated. A held session is deactivated now; during a run, the run's stop will.
    public func release(reason: String) {
        let heldNow = state.withLock { s in
            defer { if s.held { s.held = false } else { s.releaseRequested = true } }
            return s.held
        }
        observer?(.released(reason: reason, wasHeld: heldNow))
        if heldNow {
            inner.deactivate()
            state.withLock { $0.current = nil }
        }
    }

    /// The keep-active switch went off while a session was held.
    public func releaseIfHeld() {
        let heldNow = state.withLock { s in
            defer { s.held = false }
            return s.held
        }
        if heldNow {
            inner.deactivate()
            state.withLock { $0.current = nil }
        }
    }
}
