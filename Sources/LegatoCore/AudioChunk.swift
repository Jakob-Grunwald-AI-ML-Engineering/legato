import Foundation

/// Platform-neutral description of PCM audio: sample rate and channel count.
public struct AudioFormatSpec: Sendable, Equatable, Hashable {
    public var sampleRate: Double
    public var channelCount: Int

    public init(sampleRate: Double, channelCount: Int) {
        self.sampleRate = sampleRate
        self.channelCount = channelCount
    }
}

/// A block of Float32 PCM samples (interleaved when `channelCount > 1`).
public struct AudioChunk: Sendable, Equatable {
    public var samples: [Float]
    public var format: AudioFormatSpec

    public init(samples: [Float], format: AudioFormatSpec) {
        self.samples = samples
        self.format = format
    }
}
