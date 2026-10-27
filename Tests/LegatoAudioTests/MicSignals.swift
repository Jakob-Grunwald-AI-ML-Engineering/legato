import Foundation
import LegatoCore

/// Test signals for the dead-mic guard, at 16 kHz mono, built from a seeded generator so every run is the same.
enum MicSignals {
    static let sampleRate = 16_000
    static let spec = AudioFormatSpec(sampleRate: 16_000, channelCount: 1)

    /// SplitMix64: small, seedable, good enough for test noise.
    struct Seeded: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    /// Gaussian noise with the given RMS (Box-Muller).
    static func noise(seconds: Double, rms: Float, seed: UInt64) -> [Float] {
        var rng = Seeded(state: seed)
        let count = Int(Double(sampleRate) * seconds)
        return (0..<count).map { _ in
            let u1 = Double.random(in: Double.ulpOfOne..<1, using: &rng)
            let u2 = Double.random(in: 0..<1, using: &rng)
            return rms * Float((-2 * log(u1)).squareRoot() * cos(2 * .pi * u2))
        }
    }

    static func zeros(seconds: Double) -> [Float] { Array(repeating: 0, count: Int(Double(sampleRate) * seconds)) }

    /// A 1 kHz tone with the given peak.
    static func tone(seconds: Double, peak: Float) -> [Float] {
        (0..<Int(Double(sampleRate) * seconds)).map { peak * Float(sin(2 * .pi * 1_000 * Double($0) / Double(sampleRate))) }
    }

    /// The field recording of the unused AirPods mic: 1 s of zeros, the 50 ms burst of the switch to HFP
    /// (peak 0.1), then 10 s of its noise floor (RMS 0.0012).
    static func deadAirPods() -> [Float] {
        zeros(seconds: 1) + tone(seconds: 0.05, peak: 0.1) + noise(seconds: 10, rms: 0.0012, seed: 7)
    }

    /// Someone talking: 200 ms syllables at RMS 0.02 (quiet speech, about -34 dBFS) and 300 ms pauses at the
    /// room's floor, repeated for `seconds`.
    static func speech(seconds: Double) -> [Float] {
        var out: [Float] = []
        var seed: UInt64 = 11
        while Double(out.count) < Double(sampleRate) * seconds {
            out += noise(seconds: 0.2, rms: 0.02, seed: seed) + noise(seconds: 0.3, rms: 0.0012, seed: seed + 1)
            seed += 2
        }
        return out
    }

    /// Cuts samples into 0.1 s chunks.
    static func chunks(_ samples: [Float]) -> [AudioChunk] {
        stride(from: 0, to: samples.count, by: sampleRate / 10).map {
            AudioChunk(samples: Array(samples[$0..<min($0 + sampleRate / 10, samples.count)]), format: spec)
        }
    }
}
