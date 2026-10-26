import Foundation

/// Decides when the system-audio tap has gone silently dead (a denied permission or a macOS fault
/// both deliver only zeros). Pure: time and observations are injected.
///
/// Zeros count only while another process has output running; silence on the call itself never
/// triggers. After `threshold` seconds of that it asks for one rebuild, and after another
/// `threshold` seconds of the same it reports once. Any real audio, or nobody playing, starts over.
public struct TapWatchdog: Sendable {
    public enum Action: Sendable, Equatable {
        case none
        /// Tear the tap down and build it again.
        case rebuild
        /// A rebuild did not help: report `.systemAudioSilent`.
        case reportSilent
    }

    private let threshold: TimeInterval
    private var zeroSince: TimeInterval?
    private var rebuilt = false
    private var reported = false

    public init(threshold: TimeInterval = 20) {
        self.threshold = threshold
    }

    public mutating func observe(allZero: Bool, otherProcessOutputting: Bool, at now: TimeInterval) -> Action {
        guard allZero, otherProcessOutputting else {
            zeroSince = nil
            rebuilt = false
            reported = false
            return .none
        }
        let since = zeroSince ?? now
        zeroSince = since
        guard now - since >= threshold else { return .none }
        if !rebuilt {
            rebuilt = true
            zeroSince = now
            return .rebuild
        }
        guard !reported else { return .none }
        reported = true
        return .reportSilent
    }
}
