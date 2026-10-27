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
