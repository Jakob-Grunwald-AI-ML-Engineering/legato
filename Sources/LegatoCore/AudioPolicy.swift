import Foundation

/// How dictation shares the audio session with other apps' audio.
public enum AudioPolicy: String, Sendable, CaseIterable, Codable {
    /// Lower other audio while dictating (default).
    case duckOthers
    /// Leave other audio untouched ("ducking off").
    case mixWithOthers
    /// Non-mixable session: other audio pauses, resumes on deactivate. Unverified on device.
    case pauseOthers
    /// Experiment: ducks music, pauses spoken audio (podcasts, audiobooks), which resumes on deactivate.
    /// An old spike saw no mic signal (route none / 0 Hz) with this combination; unverified.
    case duckMusicPauseSpoken

    public static let `default`: AudioPolicy = .duckOthers

    /// Policies the UI may offer. `pauseOthers` stays hidden until verified on device.
    public static let offeredPolicies: [AudioPolicy] = [.duckOthers, .mixWithOthers]

    /// Policies hidden from the UI unless a debug switch offers them.
    public static let experimentalPolicies: [AudioPolicy] = [.pauseOthers, .duckMusicPauseSpoken]

    /// `pauseOthers` is `.playAndRecord` with neither mix nor duck: non-mixable, so other audio pauses.
    public var sessionConfig: SessionConfig {
        let common: SessionConfig.Options = [.allowBluetoothA2DP, .defaultToSpeaker]
        switch self {
        case .duckOthers: return SessionConfig(options: common.union(.duckOthers))
        case .mixWithOthers: return SessionConfig(options: common.union(.mixWithOthers))
        case .pauseOthers: return SessionConfig(options: common)
        case .duckMusicPauseSpoken: return SessionConfig(options: common.union([.duckOthers, .interruptSpokenAudio]))
        }
    }
}

/// Platform-neutral audio session description; `LegatoAudio` maps it to AVAudioSession.
public struct SessionConfig: Sendable, Equatable {
    public enum Category: Sendable, Equatable { case playAndRecord }
    public enum Mode: Sendable, Equatable { case `default` }

    public struct Options: OptionSet, Sendable, Hashable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let duckOthers = Options(rawValue: 1 << 0)
        public static let mixWithOthers = Options(rawValue: 1 << 1)
        public static let allowBluetoothA2DP = Options(rawValue: 1 << 2)
        public static let defaultToSpeaker = Options(rawValue: 1 << 3)
        /// `.interruptSpokenAudioAndMixWithOthers`: spoken audio pauses, other audio mixes.
        public static let interruptSpokenAudio = Options(rawValue: 1 << 4)
        /// `.allowBluetoothHFP`: a Bluetooth headset's microphone can be the input (AirPods in a meeting).
        public static let allowBluetoothHFP = Options(rawValue: 1 << 5)
    }

    public var category: Category
    public var options: Options
    public var mode: Mode

    public init(category: Category = .playAndRecord, options: Options = [], mode: Mode = .default) {
        self.category = category
        self.options = options
        self.mode = mode
    }
}

extension SessionConfig {
    /// The meeting session: it records next to other audio without lowering it, and a Bluetooth headset can be the mic.
    public static let meeting = SessionConfig(options: [.mixWithOthers, .allowBluetoothHFP])
}

// MARK: Meetings

/// Why a meeting cannot start now.
public enum MeetingStartRefusal: Sendable, Equatable {
    case alreadyRecording
    /// iOS refuses a recording session that starts in the background next to other audio ('!pla').
    case inBackground
    case dictationRunning

    public var message: String {
        switch self {
        case .alreadyRecording: "A meeting is already recording."
        case .inBackground: "Open Legato to start a meeting."
        case .dictationRunning: "Stop the dictation first."
        }
    }
}

/// Who may hold the microphone: a meeting and a dictation never run together on the phone.
public enum MeetingArbitration {
    /// What a refused dictation start says (the keyboard, the Action Button, the app's button).
    public static let dictationNotice = "Meeting recording"

    /// The notice for a dictation start that arrives while a meeting records; nil when it may go ahead.
    public static func dictationRefusal(meetingActive: Bool) -> String? {
        meetingActive ? dictationNotice : nil
    }

    /// Why a meeting may not start now; nil when it may.
    public static func meetingRefusal(inBackground: Bool, dictationActive: Bool, meetingActive: Bool) -> MeetingStartRefusal? {
        if meetingActive { return .alreadyRecording }
        if inBackground { return .inBackground }
        if dictationActive { return .dictationRunning }
        return nil
    }
}

/// Bookkeeping for a call or Siri taking the microphone away from a recording meeting.
///
/// `began` opens a gap (the meeting mutes: silence and a marked range). `ended` says whether to try the
/// resume now; when the resume fails, or the system says not to, the gap stays open and the app tries again
/// the next time it is in the foreground. A successful `resumed` closes the gap.
public struct MeetingInterruptions: Sendable, Equatable {
    /// Seconds into the meeting at which the open gap began.
    public private(set) var openSince: TimeInterval?
    /// A gap is open: the meeting is not capturing and has to resume.
    public private(set) var needsResume = false

    public init() {}

    /// True when this opens a new gap, so the caller mutes; false inside a gap that is already open.
    public mutating func began(at time: TimeInterval) -> Bool {
        needsResume = true
        guard openSince == nil else { return false }
        openSince = time
        return true
    }

    /// Whether to try to resume right now (the system said it should, and a gap is open).
    public mutating func ended(shouldResume: Bool) -> Bool {
        needsResume && shouldResume
    }

    /// The meeting captures again: closes the gap and returns its range, nil without an open gap.
    public mutating func resumed(at time: TimeInterval) -> ClosedRange<TimeInterval>? {
        defer { openSince = nil; needsResume = false }
        guard let start = openSince else { return nil }
        return start...max(start, time)
    }

    /// The resume attempt failed; the gap stays open.
    public mutating func resumeFailed() {}

    /// The app came to the foreground: resume now if a gap is still open.
    public var shouldResumeWhenForegrounded: Bool { needsResume }
}

/// A meeting's recording must stay on the wall-clock timeline, so audio the microphone did not deliver
/// (an interruption stops the engine) is filled with silence.
public enum MeetingSilence {
    /// Shorter shortfalls are buffer jitter, not a gap.
    public static let tolerance: TimeInterval = 0.25

    /// Seconds of silence to add so `delivered` seconds of audio cover `elapsed` seconds of meeting.
    public static func deficit(elapsed: TimeInterval, delivered: TimeInterval) -> TimeInterval {
        let missing = elapsed - delivered
        return missing > tolerance ? missing : 0
    }
}

/// Bookkeeping for an alarm, call or Siri taking the microphone away from dictation's hold (the keep-ready
/// lease, or the lease behind a run).
///
/// `began` remembers whether a hold was lost. `ended` says whether to try to retake it now: every end
/// tries once when a hold was lost, with or without the system's `shouldResume`. A failed retake (in the
/// background iOS may refuse activation) keeps the flag, so the next foreground (or keyboard activity
/// that arms again) retakes it. Only the hold is retaken, never a dictation that was running.
public struct HoldInterruptions: Sendable, Equatable {
    /// How a retake ended.
    public enum Outcome: Sendable, Equatable {
        /// The lease is held again.
        case held
        /// The session could not be activated (iOS may refuse in the background); the foreground retries.
        case failed
        /// A run owns the microphone: the hold is not ours to retake.
        case busy
    }

    /// A hold was lost to an interruption and has not been retaken.
    public private(set) var needsResume = false
    /// Between a `began` and its `ended`.
    public private(set) var inInterruption = false
    /// Counts interruptions; a retake that started in an older one is stale.
    public private(set) var generation = 0
    /// A retake is scheduled or running.
    public private(set) var retaking = false
    /// An `ended` arrived while a retake was in flight; it runs again once that one finishes.
    public private(set) var pendingRetake = false

    public init() {}

    /// Whether the interruption took a hold: a held lease, or a run that keeps the mic ready afterwards
    /// (a run without keep-ready leaves nothing to retake).
    public static func wasHolding(leaseHeld: Bool, dictating: Bool, keepsLeaseAfterRun: Bool) -> Bool {
        leaseHeld || (dictating && keepsLeaseAfterRun)
    }

    /// The background task covering the gap should exist: from losing the hold until a retake settles
    /// outside an interruption.
    public var backgroundTaskWanted: Bool { needsResume && (inInterruption || retaking) }

    /// An interruption began. A began while the flag is already set (a second interruption before the
    /// first hold came back, even mid-retake) keeps it.
    public mutating func began(wasHolding: Bool) {
        inInterruption = true
        generation += 1
        if wasHolding { needsResume = true }
    }

    /// Whether to try to retake the hold right now (with or without the system's `shouldResume`). When true a retake is scheduled and the caller runs
    /// it, then reports `finishRetake`. During an in-flight retake the end is remembered instead.
    public mutating func ended(keepReady: Bool = true) -> Bool {
        inInterruption = false
        return scheduleRetake(keepReady: keepReady, deferringWhileRetaking: true)
    }

    /// The app came to the foreground: whether to retake now.
    public mutating func foregrounded(keepReady: Bool = true) -> Bool {
        guard !inInterruption else { return false }
        return scheduleRetake(keepReady: keepReady, deferringWhileRetaking: false)
    }

    private mutating func scheduleRetake(keepReady: Bool, deferringWhileRetaking: Bool) -> Bool {
        guard keepReady else { needsResume = false; pendingRetake = false; return false }
        guard needsResume else { return false }
        if retaking {
            if deferringWhileRetaking { pendingRetake = true }
            return false
        }
        retaking = true
        return true
    }

    /// A lease was published by some other path (a keyboard arm, a run's end). It only settles the lost
    /// hold outside an interruption and outside a retake, which report their own outcome.
    public mutating func leaseObserved() {
        if !inInterruption && !retaking { needsResume = false }
    }

    /// The retake that started in `generation` ended. Returns whether to run another one (an `ended`
    /// arrived meanwhile and the hold is still lost).
    public mutating func finishRetake(_ outcome: Outcome, generation started: Int) -> Bool {
        retaking = false
        switch outcome {
        case .held where started == generation && !inInterruption: needsResume = false
        case .busy where started == generation && !inInterruption: needsResume = false
        default: break
        }
        guard pendingRetake else { return false }
        pendingRetake = false
        guard needsResume, !inInterruption else { return false }
        retaking = true
        return true
    }

    /// The retake was dropped (a meeting owns the microphone); the flag stays for the foreground.
    public mutating func abandonRetake() {
        retaking = false
        pendingRetake = false
    }

    /// The app came to the foreground: retake now if a hold is still lost.
    public var shouldResumeWhenForegrounded: Bool { needsResume && !retaking && !inInterruption }
}
