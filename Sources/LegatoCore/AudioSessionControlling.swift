import Foundation

/// Platform audio-session control (AVAudioSession on iOS; none on macOS).
public protocol AudioSessionControlling: Sendable {
    /// Policies this platform can honor. Empty on macOS.
    var supportedPolicies: Set<AudioPolicy> { get }

    /// Applies `config` and activates the session. Must complete before the source starts.
    func activate(_ config: SessionConfig) throws

    /// Deactivates the session, notifying others so they can resume. Never throws.
    func deactivate()
}
