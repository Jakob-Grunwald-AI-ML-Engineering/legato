import Foundation
import LegatoCore

/// Tells a dead microphone from a working one by its first seconds. Pure: chunks in, verdict out.
///
/// A dead input is not digital silence: an unused AirPods mic gave a noise floor of RMS ~0.0012 (peaks up to
/// 0.013) and a 0.1 spike when it switched to the headset mode, and a broken voice-processing unit gave
/// near-silence (peak 0.007). So single peaks say nothing; the guard looks at the loudness of 100 ms frames.
///
/// - The first `grace` seconds after a start are ignored (the switch spike, the engine settling).
/// - The next `window` seconds are judged frame by frame: a frame is loud when its RMS reaches `floor`.
/// - More than `loudShare` of the window's frames loud is `working` (decided as soon as it is reached);
///   a whole window with no more than that is `silent`.
///
/// The default floor, 0.003 RMS (-50 dBFS), is 2.5 times (8 dB above) the dead AirPods floor, whose 100 ms
/// frames vary by about 2 % and never come near it, and about 10 dB below quiet speech (-40 dBFS and up).
/// The 5 % share lets half a second of clicks or spikes pass in a 10 s window without counting as a voice.
/// The cost: a working mic in a very quiet room whose user says nothing for the first ten seconds reads as
/// silent too, which only shows a notice (and follows the call app's device, when that differs).
public struct MicSilenceGuard: Sendable {
    public enum Verdict: Sendable, Equatable {
        /// Not enough audio heard yet to say.
        case undecided
        /// Enough loud frames.
        case working
        /// A whole window passed without them.
        case silent
    }

    /// The length of one judged frame.
    static let frameSeconds = 0.1

    private let grace: TimeInterval
    private let window: TimeInterval
    private let floor: Float
    private let loudShare: Double
    /// Samples (all channels) seen so far, counting the grace period.
    private var seenSamples = 0
    private var frameSumSquares = 0.0
    private var frameSamples = 0
    private var frames = 0
    private var loudFrames = 0
    private var verdict = Verdict.undecided

    /// - Parameters:
    ///   - window: seconds of audio judged after the grace period; the verdict comes `grace + window` after a start.
    ///   - grace: seconds after a start that are not judged.
    ///   - floor: the 100 ms frame RMS that counts as sound.
    ///   - loudShare: the share of the window's frames that may be loud in a dead mic.
    public init(window: TimeInterval = 8, grace: TimeInterval = 2, floor: Float = 0.003, loudShare: Double = 0.05) {
        self.window = window
        self.grace = grace
        self.floor = floor
        self.loudShare = loudShare
    }

    /// The verdict after this chunk. Once it is not `undecided` it stays.
    public mutating func observe(_ chunk: AudioChunk) -> Verdict {
        guard verdict == .undecided else { return verdict }
        let channels = max(1, chunk.format.channelCount)
        let rate = chunk.format.sampleRate
        let graceSamples = Int((grace * rate).rounded()) * channels
        let frameLength = max(1, Int((Self.frameSeconds * rate).rounded()) * channels)
        let windowFrames = max(1, Int((window / Self.frameSeconds).rounded()))
        let allowedLoud = Int(Double(windowFrames) * loudShare)
        let threshold = Double(floor) * Double(floor)

        var index = max(0, min(chunk.samples.count, graceSamples - seenSamples))
        seenSamples += chunk.samples.count
        while index < chunk.samples.count {
            let take = min(frameLength - frameSamples, chunk.samples.count - index)
            for i in index..<(index + take) {
                let v = Double(chunk.samples[i])
                frameSumSquares += v * v
            }
            frameSamples += take
            index += take
            guard frameSamples == frameLength else { continue }
            frames += 1
            if frameSumSquares / Double(frameLength) >= threshold { loudFrames += 1 }
            frameSumSquares = 0
            frameSamples = 0
            if loudFrames > allowedLoud {
                verdict = .working
                return verdict
            }
            if frames >= windowFrames {
                verdict = .silent
                return verdict
            }
        }
        return verdict
    }
}
