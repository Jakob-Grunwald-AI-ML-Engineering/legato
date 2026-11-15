import Foundation

// Ports the app implements for `DictationCoordinator` (ActivityKit, the pasteboard, system checks).

public enum DictationPhase: String, Sendable, Equatable, Codable, CaseIterable {
    case starting, listening, finishing
    /// No take runs; the app only holds the microphone in the background (`HoldActivityPlanner`).
    case held
    /// Capture is being restored; retain the background activity without claiming readiness.
    case recovering

}

/// What the Live Activity shows.
public struct DictationActivityContent: Sendable, Equatable, Codable {
    public var startedAt: Date
    /// The end of the text, sized for the activity (`LiveTranscript.tail`).
    public var tail: String
    public var phase: DictationPhase

    public init(startedAt: Date, tail: String, phase: DictationPhase) {
        self.startedAt = startedAt
        self.tail = tail
        self.phase = phase
    }
}

/// The Live Activity of one dictation: requested first, updated while it runs, ended once.
@MainActor
public protocol ActivityClient: AnyObject {
    /// Starts the activity. Throws when the system refuses (e.g. Live Activities are off).
    func request(_ content: DictationActivityContent) async throws
    /// `staleDate`: when the system may treat the content as stale if no newer update arrived.
    func update(_ content: DictationActivityContent, staleDate: Date?) async
    func end(_ content: DictationActivityContent) async
    /// Removes the activity at once, with no final state: the run never began (its start is being
    /// retried in the foreground), so nothing may linger on the Lock Screen.
    func dismiss() async
}

/// Why a start requires foreground setup.
public enum ReadinessIssue: Sendable, Equatable, CaseIterable { case micPermission, liveActivitiesDisabled, assetsMissing }
public enum ForegroundReason: String, Sendable, Equatable { case backgroundStartRefused }
