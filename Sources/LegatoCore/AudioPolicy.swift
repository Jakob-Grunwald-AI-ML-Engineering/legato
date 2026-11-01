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
