import Foundation
import LegatoCore

/// Tells a dead voice-processing microphone from a working one by its first seconds. Pure: chunks in, verdict out.
///
/// On some Bluetooth headsets the voice-processing unit fails to configure and the input then delivers
/// digital near-silence (a field run: peak 0.007 over 60 s). Real input, even of an empty room, rises above
/// `peakThreshold` within moments, so a whole `window` of audio below it means the input is dead.
public struct MicSilenceGuard: Sendable {
    public enum Verdict: Sendable, Equatable {
        /// Not enough audio heard yet to say.
        case undecided
        /// Some sample reached the threshold.
        case working
        /// A whole window passed without one.
        case silent
    }

    private let window: TimeInterval
    private let peakThreshold: Float
    /// Frames heard so far; counted in frames so that ten 0.1 s chunks are exactly one second.
    private var heardFrames = 0.0
    private var verdict = Verdict.undecided

    /// - Parameters:
    ///   - window: seconds of audio that must stay quiet before the verdict is `silent`.
    ///   - peakThreshold: the absolute sample value that counts as signal.
    public init(window: TimeInterval = 5, peakThreshold: Float = 0.01) {
        self.window = window
        self.peakThreshold = peakThreshold
    }

    /// The verdict after this chunk. Once it is not `undecided` it stays.
    public mutating func observe(_ chunk: AudioChunk) -> Verdict {
        guard verdict == .undecided else { return verdict }
        if chunk.samples.contains(where: { abs($0) >= peakThreshold }) {
            verdict = .working
            return verdict
        }
        heardFrames += Double(chunk.samples.count) / Double(max(1, chunk.format.channelCount))
        if heardFrames >= window * chunk.format.sampleRate { verdict = .silent }
        return verdict
    }
}
