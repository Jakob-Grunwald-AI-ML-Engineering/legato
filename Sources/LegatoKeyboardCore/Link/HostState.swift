import Foundation

public enum HostPhase: String, Codable, Sendable, Equatable {
    /// No run in progress. With a `runID` this is the final state of the run that just ended.
    case idle
    case starting
    case listening
    case finishing
}

/// A durable answer for every Start accepted into one admission, including duplicate presses.
/// Cancellation is a successful settlement: it never requires reopening the app.
public struct HostStartCompletion: Codable, Sendable, Equatable {
    public var requestIDs: [String]
    public var needsForeground: Bool

    public init(requestIDs: [String], needsForeground: Bool) {
        self.requestIDs = requestIDs
        self.needsForeground = needsForeground
    }
}

/// Host liveness and capture admission. Dictation text has its own channels.
public struct HostState: Codable, Sendable, Equatable {
    public static let version = 2
    public var v = Self.version
    public var phase: HostPhase
    public var seq: Int
    public var beatAt: Date
    public var leaseUntil: Date?
    public var acceptsRemoteStart: Bool
    public var meetingRecording: Bool?
    public var preparingRequestID: String?
    public var startCompletion: HostStartCompletion?
    public init(phase: HostPhase = .idle, seq: Int = 0, beatAt: Date, leaseUntil: Date? = nil, acceptsRemoteStart: Bool = false) {
        self.phase = phase; self.seq = seq; self.beatAt = beatAt
        self.leaseUntil = leaseUntil; self.acceptsRemoteStart = acceptsRemoteStart
    }
    public func isLive(now: Date) -> Bool { now.timeIntervalSince(beatAt) < LinkChannel.beatFreshness }
    public func meetingNotice(now: Date) -> String? {
        guard meetingRecording == true, isLive(now: now) else { return nil }
        return "Meeting recording"
    }
}
