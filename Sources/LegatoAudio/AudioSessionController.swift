import LegatoCore
#if os(iOS)
import AVFAudio
#endif

/// Platform audio-session control: AVAudioSession on iOS, no-ops on macOS.
public struct AudioSessionController: AudioSessionControlling {
    public init() {}

    #if os(iOS)
    public var supportedPolicies: Set<AudioPolicy> { Set(AudioPolicy.allCases) }

    public func activate(_ config: SessionConfig) throws {
        let d = SessionDescription(config)
        let session = AVAudioSession.sharedInstance()
        // Category and options must be set before setActive(true).
        try session.setCategory(d.avCategory, mode: d.avMode, options: d.avOptions)
        do {
            if let mic = session.availableInputs?.first(where: { $0.portType == .builtInMic }) {
                try session.setPreferredInput(mic)
            }
        } catch {
            // Best effort: the system picks the input when the built-in mic can't be preferred.
        }
        try session.setActive(true)
    }

    public func deactivate() {
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        } catch {
            // Never throws. Error 560030580 ('!pri'/session still has running I/O) is expected
            // when the engine is still tearing down; the session is released with the engine.
        }
    }
    #else
    public var supportedPolicies: Set<AudioPolicy> { [] }
    public func activate(_ config: SessionConfig) throws {}
    public func deactivate() {}
    #endif
}

#if os(iOS)
extension SessionDescription {
    var avCategory: AVAudioSession.Category {
        switch category { case .playAndRecord: .playAndRecord }
    }

    var avMode: AVAudioSession.Mode {
        switch mode { case .default: .default }
    }

    var avOptions: AVAudioSession.CategoryOptions {
        var o: AVAudioSession.CategoryOptions = []
        if mixWithOthers { o.insert(.mixWithOthers) }
        if duckOthers { o.insert(.duckOthers) }
        if allowBluetoothA2DP { o.insert(.allowBluetoothA2DP) }
        if defaultToSpeaker { o.insert(.defaultToSpeaker) }
        return o
    }
}
#endif
