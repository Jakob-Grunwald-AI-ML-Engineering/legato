import LegatoCore
import Foundation
import Synchronization
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
    private static let dualAdmissionFailure = Mutex<String?>(nil)
    /// The stage and native error from the last rejected dual-route admission, if any.
    /// Metadata only; remains available after falling back to built-in capture.
    public static var lastDualAdmissionFailure: String? { dualAdmissionFailure.withLock { $0 } }

    /// Dictation admission only. Called in the foreground before arming a held microphone.
    /// dualRoute supplies the built-in and compatible headset microphones in one clocked input.
    /// Older devices and rejected configurations retain the built-in capture fallback.
    public static func configureMicrophoneCapture(combineInputs: Bool = true) throws {
        let session = AVAudioSession.sharedInstance()
        dualAdmissionFailure.withLock { $0 = nil }
        if #available(iOS 26.2, *), combineInputs {
            var stage = "setCategory"
            do {
                // mixWithOthers and duckOthers are only valid for multiRoute in default
                // mode. dualRoute requires HFP alone; combining it with mixing is rejected.
                try session.setCategory(.multiRoute, mode: .dualRoute, options: [.allowBluetoothHFP])
                stage = "setActive"
                try session.setActive(true)
                // MicSource sets the complete client format and explicit input channel map.
                // A best-effort session channel preference must not reject valid admission.
                return
            } catch {
                let native = error as NSError
                dualAdmissionFailure.withLock {
                    $0 = "\(stage): \(native.domain) \(native.code): \(native.localizedDescription)"
                }
                // Admission may fail for this OS/device combination. Restore the established
                // single-input configuration; never leave a partially configured dual session.
            }
        }
        try configureSingleMicrophoneCapture()
    }

    /// Called once when dual-route admission succeeds but its engine cannot deliver PCM.
    /// Background category rejection is allowed to throw, so the host can request foreground
    /// admission instead of claiming that a microphone was successfully repaired.
    static func fallbackFromCombinedCapture(reason: String) throws {
        dualAdmissionFailure.withLock { $0 = "capture: " + reason }
        try configureSingleMicrophoneCapture()
    }

    private static func configureSingleMicrophoneCapture() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default,
            options: [.mixWithOthers, .allowBluetoothA2DP, .defaultToSpeaker])
        if let mic = session.availableInputs?.first(where: { $0.portType == .builtInMic }) {
            try? session.setPreferredInput(mic)
        }
        try session.setActive(true)
    }

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
