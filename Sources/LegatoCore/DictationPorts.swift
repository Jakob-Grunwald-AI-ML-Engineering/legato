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
    /// Removes the activity at once, with no final state: the run never began (its start is being
    /// retried in the foreground), so nothing may linger on the Lock Screen.
    func dismiss() async
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

/// Builds the session for one dictation attempt under the given audio policy. Called once per start
/// (twice when a refused background start falls back to the default policy), so no session or mic
/// outlives a run.
public typealias DictationSessionFactory = @MainActor (AudioPolicy) -> DictationSession

/// What the app knows about the moment a start is requested.
public struct StartContext: Sendable, Equatable {
    /// The app is in the background (e.g. an Action Button press with the app not on screen).
    public var inBackground: Bool
    /// Another app's audio is playing. Diagnostics only: it never changes how a start is routed.
    public var otherAudioPlaying: Bool
    /// The audio policy the user selected. When it is not `AudioPolicy.default` and the system refuses a
    /// background start under it, the coordinator retries once with the default.
    public var audioPolicy: AudioPolicy

    public init(inBackground: Bool, otherAudioPlaying: Bool, audioPolicy: AudioPolicy = .default) {
        self.inBackground = inBackground
        self.otherAudioPlaying = otherAudioPlaying
        self.audioPolicy = audioPolicy
    }

    /// Nothing restricts a start.
    public static let unrestricted = StartContext(inBackground: false, otherAudioPlaying: false)
}

/// Why a start has to run in the foreground.
public enum ForegroundReason: String, Sendable, Equatable {
    /// A background start was tried and the system refused it.
    case backgroundStartRefused
}

/// The system facts behind the foreground/background routing of a start. Keeps AVFoundation out of the core.
@MainActor
public protocol StartEnvironment: AnyObject {
    /// A snapshot, taken as the start begins.
    func current() -> StartContext
    /// Whether `error`, thrown by a start that ran in the background, is the system refusing to record
    /// from there (so the same start can succeed in the foreground).
    func isBackgroundRefusal(_ error: any Error) -> Bool
}

/// The default environment: nothing is restricted, no error is a refusal.
@MainActor
public final class UnrestrictedStartEnvironment: StartEnvironment {
    public init() {}
    public func current() -> StartContext { .unrestricted }
    public func isBackgroundRefusal(_ error: any Error) -> Bool { false }
}
