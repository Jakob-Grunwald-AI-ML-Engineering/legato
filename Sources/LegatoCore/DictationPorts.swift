import Foundation

// Ports the app implements for `DictationCoordinator` (ActivityKit, the pasteboard, system checks).

public enum DictationPhase: String, Sendable, Equatable, Codable {
    case starting, listening, finishing
    /// Terminal: the text is on the clipboard.
    case copied
    /// Terminal: the clipboard write didn't take effect; tapping the activity copies from the app.
    case tapToCopy
    /// Terminal: nothing usable came out of the run.
    case failed
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
}

@MainActor
public protocol Clipboard: AnyObject {
    /// Writes `text`. Returns whether the pasteboard actually changed (its change count moved).
    func write(_ text: String) -> Bool
}

/// Why dictation can't start right now; the app resolves it in the foreground (onboarding).
public enum ReadinessIssue: Sendable, Equatable, CaseIterable {
    case micPermission, liveActivitiesDisabled, assetsMissing
}

@MainActor
public protocol Readiness: AnyObject {
    /// nil when dictation can start, otherwise the first thing that is missing.
    func check() async -> ReadinessIssue?
}

/// Builds the session for one dictation. Called once per start, so no session or mic outlives a run.
public typealias DictationSessionFactory = @MainActor () -> DictationSession
