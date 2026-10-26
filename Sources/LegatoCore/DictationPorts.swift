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
    /// Whether `error` says the microphone had no input yet (e.g. a 0 Hz input format right after the
    /// session was activated). Such a start is worth one retry with a fresh session, also in the foreground.
    func isInputNotReady(_ error: any Error) -> Bool
}

extension StartEnvironment {
    public func isInputNotReady(_ error: any Error) -> Bool { false }
}

/// The default environment: nothing is restricted, no error is a refusal.
@MainActor
public final class UnrestrictedStartEnvironment: StartEnvironment {
    public init() {}
    public func current() -> StartContext { .unrestricted }
    public func isBackgroundRefusal(_ error: any Error) -> Bool { false }
}

/// Builds the session for one dictation attempt under `policy`. `linger` is how long its mic lease stays
/// armed after a run (zero: released at once). Called once per attempt that has no held session to reuse
/// (more than once when a refused background start falls back to the default policy, or a foreground
/// start is retried), so no session or mic outlives its keep-alive.
public typealias DictationSessionFactory = @MainActor (_ policy: AudioPolicy, _ linger: Linger) -> DictationSession

/// Where a run's text goes.
public enum DictationTarget: Sendable, Equatable {
    /// The app's own screen, or only the clipboard: the text is copied when the run ends.
    case app
    /// Streamed into the text field of the keyboard extension; copied only if it didn't land there.
    case keyboard
}

/// One run, for the sink: the id ties its events together.
public struct DictationRun: Sendable, Equatable {
    public let id: UUID
    public let target: DictationTarget

    public init(id: UUID = UUID(), target: DictationTarget) {
        self.id = id
        self.target = target
    }
}

/// How a start treats the Live Activity, the mic lease and the text.
public struct StartOptions: Sendable, Equatable {
    public enum ActivityPolicy: Sendable, Equatable {
        /// iOS stops a recording intent that has no Live Activity: a refusal means onboarding, no run.
        case required
        /// Try for one; run without it when the system refuses (or Live Activities are off).
        case bestEffort
    }

    public var activity: ActivityPolicy
    /// How long the mic stays armed after the run, so the next run starts without re-activating the
    /// audio session. Zero releases it at once.
    public var keepAlive: Linger
    public var target: DictationTarget

    public init(activity: ActivityPolicy = .required, keepAlive: Linger = .off, target: DictationTarget = .app) {
        self.activity = activity
        self.keepAlive = keepAlive
        self.target = target
    }
}

/// Receives a run's text as it happens (the app publishes it to the keyboard). Per run, in order:
/// `runStarted`, `update` (first with empty text once listening, then after every edit), `runFinishing`
/// (a stop began; more `update`s can follow while the engine finalizes), `runEnded`;
/// then `leaseChanged` when a keep-alive lease is held. A run that began always ends, however it ends.
@MainActor
public protocol TranscriptSink: AnyObject {
    /// A run begins; the activity (if required) exists and the session is about to start.
    func runStarted(_ run: DictationRun)
    /// The run's text so far: everything committed, and the tentative tail.
    func update(committed: String, volatile: String)
    /// A stop began: no more speech is taken; the text is being finalized (and post-processed). Not
    /// called for a run that aborted or never started. Optional (the default does nothing).
    func runFinishing(_ run: DictationRun)
    /// The run is over. `committed` is everything committed (as it was streamed), `text` the final
    /// trimmed transcript, nil when nothing final was recognized. Returns whether the final text is
    /// now in the target's field, so the clipboard isn't needed; may wait briefly for the target to
    /// confirm it.
    func runEnded(_ run: DictationRun, committed: String, text: String?) async -> Bool
    /// The mic lease between runs: when it ends, or nil when it is not held (ended or expired).
    func leaseChanged(until: Date?)
}

extension TranscriptSink {
    public func runFinishing(_ run: DictationRun) {}
}
