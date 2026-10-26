import Foundation

public enum HostPhase: String, Codable, Sendable, Equatable {
    /// No run in progress. With a `runID` this is the final state of the run that just ended.
    case idle
    case starting
    case listening
    case finishing
}

/// Where a run's text goes.
public enum HostTarget: String, Codable, Sendable, Equatable {
    /// The app's own screen (hop view or home): nothing is typed into a field.
    case app
    /// Streamed into the field of the keyboard that is on screen.
    case keyboard
}

/// What the app publishes to the keyboard (`link.host`): the run's text so far and whether the app
/// is alive and can be asked to start or stop without opening it.
public struct HostState: Codable, Sendable, Equatable {
    public static let version = 1

    public var v: Int
    /// Identifies the run; nil when the app has never run one (or after a restart).
    public var runID: String?
    public var phase: HostPhase
    public var target: HostTarget
    /// Everything committed in this run so far.
    public var committed: String
    /// The tentative text after `committed`.
    public var volatile: String
    /// Increments on every publish.
    public var seq: Int
    /// Refreshed every `LinkChannel.beatInterval`, only while a run or a lease exists.
    public var beatAt: Date
    /// While the mic is held between runs: when the lease ends.
    public var leaseUntil: Date?
    /// The app can start a run from where it is, without being opened (a lease is held).
    public var acceptsRemoteStart: Bool

    public init(
        runID: String?, phase: HostPhase, target: HostTarget, committed: String, volatile: String, seq: Int,
        beatAt: Date, leaseUntil: Date?, acceptsRemoteStart: Bool
    ) {
        self.v = Self.version
        self.runID = runID
        self.phase = phase
        self.target = target
        self.committed = committed
        self.volatile = volatile
        self.seq = seq
        self.beatAt = beatAt
        self.leaseUntil = leaseUntil
        self.acceptsRemoteStart = acceptsRemoteStart
    }

    /// The run is over and this is its last state.
    public var isFinal: Bool { runID != nil && phase == .idle }

    /// Whether a keyboard may follow this state. A state that says a run is going on is only believable
    /// while the app keeps beating: an app that died mid-run leaves its last "listening" state (with the
    /// run's text) behind, and that must never be typed into a field later. An idle state is the final
    /// state of a finished run (the beat stops with the run), so its age says nothing.
    public func isLive(now: Date) -> Bool {
        phase == .idle || now.timeIntervalSince(beatAt) < LinkChannel.beatFreshness
    }
}
