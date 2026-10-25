import LegatoCore

/// Platform-neutral, plain description of the audio-session settings a `SessionConfig` asks for.
/// The iOS-only `AudioSessionController` turns this into AVAudioSession categories and options;
/// keeping it separate lets the mapping be tested on macOS.
struct SessionDescription: Equatable {
    enum Category: Equatable { case playAndRecord }
    enum Mode: Equatable { case `default` }

    var category: Category
    var mode: Mode
    var mixWithOthers: Bool
    var duckOthers: Bool
    var allowBluetoothA2DP: Bool
    var defaultToSpeaker: Bool

    init(_ config: SessionConfig) {
        switch config.category { case .playAndRecord: category = .playAndRecord }
        switch config.mode { case .default: mode = .default }
        mixWithOthers = config.options.contains(.mixWithOthers)
        duckOthers = config.options.contains(.duckOthers)
        allowBluetoothA2DP = config.options.contains(.allowBluetoothA2DP)
        defaultToSpeaker = config.options.contains(.defaultToSpeaker)
    }
}
