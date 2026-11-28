import Foundation

/// The loudness of one recorded track over time: mean power per 20 ms frame (the same frames as ``SpeakerTimeline``).
/// The Mac records the microphone and the system audio apart, so comparing the two says which side a word came from.
public struct TrackEnergy: Sendable, Equatable {
    public static let frame: TimeInterval = SpeakerTimeline.frame

    /// Mean squared sample per frame.
    public private(set) var power: [Float]
    private var pendingSum: Float = 0
    private var pendingCount = 0
    private let samplesPerFrame: Int

    public init(sampleRate: Double = 16_000, power: [Float] = []) {
        samplesPerFrame = max(1, Int((sampleRate * Self.frame).rounded()))
        self.power = power
    }

    /// Adds the next samples of the track (in order, from the meeting's start).
    public mutating func append(_ samples: [Float]) {
        for sample in samples {
            pendingSum += sample * sample
            pendingCount += 1
            if pendingCount == samplesPerFrame {
                power.append(pendingSum / Float(samplesPerFrame))
                pendingSum = 0
                pendingCount = 0
            }
        }
    }

    /// Mean power from `start` to `end` (at least the frame of its middle); 0 outside the track.
    public func meanPower(from start: TimeInterval, to end: TimeInterval) -> Float {
        guard !power.isEmpty else { return 0 }
        var first = Int((min(start, end) / Self.frame).rounded(.down)), last = Int((max(start, end) / Self.frame).rounded(.up)) - 1
        if last < first {
            first = Int(((start + end) / 2 / Self.frame).rounded(.down))
            last = first
        }
        first = max(0, first)
        last = min(power.count - 1, last)
        guard first <= last else { return 0 }
        return power[first...last].reduce(0, +) / Float(last - first + 1)
    }
}

/// Finds the user among a meeting's voices: on the Mac from which track a voice is loud on and the voice profile, on the
/// iPhone (one microphone) from the profile alone. Only the user who records is ever recognised.
public enum MeetingSelf {
    /// Which recorded track a word is clearly louder on.
    public enum Side: Sendable, Equatable { case mic, system }

    /// One track must be this many dB louder than the other for a word to count as its side. An estimate: echo that
    /// leaks from the speakers into the microphone is quieter than this, the user's own voice far louder.
    public static let dominanceDB: Float = 10
    /// The louder track must reach this level (dBFS) for the word to count at all. An estimate.
    public static let floorDB: Float = -55
    /// A voice is the microphone's when at least this share of its decided words are. An estimate.
    public static let micShare: Double = 0.8
    /// …and when it has at least this many of them. An estimate.
    public static let minimumWords = 5
    /// A voice matches the user's profile at this cosine similarity (best of the user's profiles). An estimate, the
    /// level dictation accepts the user's voice at; meetings give longer, cleaner stretches.
    public static let profileThreshold: Float = 0.45

    /// Which track the word is clearly louder on, from the mean power of each over the word; nil when neither is.
    public static func side(micPower: Float, systemPower: Float) -> Side? {
        let mic = decibels(micPower), system = decibels(systemPower)
        guard max(mic, system) >= floorDB else { return nil }
        if mic - system >= dominanceDB { return .mic }
        if system - mic >= dominanceDB { return .system }
        return nil
    }

    /// The voice's decided words are mostly the microphone's.
    public static func isMicDominant(_ sides: [Side]) -> Bool {
        let mic = sides.filter { $0 == .mic }.count
        return mic >= minimumWords && Double(mic) >= micShare * Double(sides.count)
    }

    /// Which voice is the user, if any.
    /// - Parameters:
    ///   - micDominant: per voice, whether it is the microphone's (``isMicDominant(_:)``); nil when the meeting has one
    ///     track only (the iPhone).
    ///   - similarity: per voice, its similarity to the user's voice profile; nil without a profile.
    /// - Returns: with two tracks, a microphone voice that also matches the profile (the best match), or without a profile
    ///   the only microphone voice; with one track, the best profile match. Nil when nothing qualifies.
    public static func user(micDominant: [Int: Bool]?, similarity: [Int: Float]?) -> Int? {
        let matching = similarity.map { $0.filter { $0.value >= profileThreshold } }
        if let micDominant {
            let candidates = Set(micDominant.filter(\.value).keys)
            guard let matching else { return candidates.count == 1 ? candidates.first : nil }
            return matching.filter { candidates.contains($0.key) }.max { ($0.value, -$0.key) < ($1.value, -$1.key) }?.key
        }
        return matching?.max { ($0.value, -$0.key) < ($1.value, -$1.key) }?.key
    }

    public static func decibels(_ power: Float) -> Float { 10 * log10(max(power, 1e-12)) }
}
