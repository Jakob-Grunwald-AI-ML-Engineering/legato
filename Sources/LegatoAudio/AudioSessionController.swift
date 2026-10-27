import LegatoCore
#if os(iOS)
import AVFAudio
#endif

/// Platform audio-session control: AVAudioSession on iOS, no-ops on macOS.
public struct AudioSessionController: AudioSessionControlling {
    /// The AVAudioSession calls the controller makes, for diagnostics.
    public enum Step: String, Sendable {
        case setCategory, setPreferredInput, setActiveTrue, setActiveFalse
    }

    private let observer: (@Sendable (Step, (any Error)?) -> Void)?

    /// - Parameter observer: called with the result of every AVAudioSession call (nil error = success),
    ///   including the `setActive(false)` failure `deactivate()` itself swallows. Diagnostics only.
    public init(observer: (@Sendable (Step, (any Error)?) -> Void)? = nil) {
        self.observer = observer
    }

    #if os(iOS)
    public var supportedPolicies: Set<AudioPolicy> { Set(AudioPolicy.allCases) }

    public func activate(_ config: SessionConfig) throws {
        let d = SessionDescription(config)
        let session = AVAudioSession.sharedInstance()
        // Category and options must be set before setActive(true).
        try observed(.setCategory) { try session.setCategory(d.avCategory, mode: d.avMode, options: d.avOptions) }
        do {
            if d.prefersBuiltInMic, let mic = session.availableInputs?.first(where: { $0.portType == .builtInMic }) {
                try observed(.setPreferredInput) { try session.setPreferredInput(mic) }
            }
        } catch {
            // Best effort: the system picks the input when the built-in mic can't be preferred.
        }
        try observed(.setActiveTrue) { try session.setActive(true) }
    }

    /// Reactivates the session as it is, without setting the category again. For a meeting resuming after an
    /// interruption: changing options on a session from the background fails ('!int'), so a held session is reused.
    public func reactivate() throws {
        try observed(.setActiveTrue) { try AVAudioSession.sharedInstance().setActive(true) }
    }

    public func deactivate() {
        do {
            try observed(.setActiveFalse) {
                try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            }
        } catch {
            // Never throws. Error 560030580 ('!act', AVAudioSessionErrorCodeIsBusy: the session still
            // has running I/O) is expected when the engine is still tearing down; the session is
            // released with the engine.
        }
    }

    private func observed(_ step: Step, _ call: () throws -> Void) throws {
        do {
            try call()
            observer?(step, nil)
        } catch {
            observer?(step, error)
            throw error
        }
    }
    #else
    public var supportedPolicies: Set<AudioPolicy> { [] }
    public func activate(_ config: SessionConfig) throws {}
    public func reactivate() throws {}
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
        if interruptSpokenAudio { o.insert(.interruptSpokenAudioAndMixWithOthers) }
        if allowBluetoothHFP { o.insert(.allowBluetoothHFP) }
        return o
    }
}
#endif
