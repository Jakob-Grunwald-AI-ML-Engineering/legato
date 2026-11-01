import Foundation
import LegatoCore

/// Signal measurements, not a claim that speech was recognized or one microphone sounds best.
public struct InputSignalQuality: Sendable, Codable {
    public var seconds: Double = 0
    public var rms: Double = 0
    public var peak: Double = 0
    public var clippedFraction: Double = 0
    public var activityVariation: Double = 0
    public var buffers = 0
    public var state: String { seconds == 0 ? "checking" : (clippedFraction >= 0.15 ? "clipping" : (rms == 0 ? "quiet" : "signal")) }
    public init() {}
}

struct InputQualityMeter {
    var frames = 0, samples = 0, clipped = 0, buffers = 0
    var sum = 0.0, peak = 0.0, smallestRMS = Double.infinity, largestRMS = 0.0
    mutating func observe(_ chunk: AudioChunk) -> InputSignalQuality {
        var chunkSum = 0.0
        for sample in chunk.samples {
            let value = Double(sample), magnitude = abs(value)
            chunkSum += value * value; peak = max(peak, magnitude)
            if magnitude >= 0.995 { clipped += 1 }
        }
        samples += chunk.samples.count; frames += chunk.samples.count / max(1, chunk.format.channelCount); buffers += 1
        sum += chunkSum
        let rms = sqrt(chunkSum / Double(max(1, chunk.samples.count)))
        smallestRMS = min(smallestRMS, rms); largestRMS = max(largestRMS, rms)
        var result = InputSignalQuality()
        result.seconds = Double(frames) / chunk.format.sampleRate; result.rms = sqrt(sum / Double(max(1, samples)))
        result.peak = peak; result.clippedFraction = Double(clipped) / Double(max(1, samples))
        result.activityVariation = largestRMS / max(0.000_001, smallestRMS); result.buffers = buffers
        return result
    }
}
