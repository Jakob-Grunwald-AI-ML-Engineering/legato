import Foundation
import LegatoCore

/// Plans the windows the post-pass transcribes: each at most ``maxWindow`` long, cut where the
/// recording is quietest so no word is split.
public enum AudioWindowing {
    /// Longest window, in seconds.
    public static let maxWindow: TimeInterval = 600
    /// How far before the limit a cut may be placed, in seconds.
    public static let searchSpan: TimeInterval = 30
    /// Energy is measured over frames of this length, in seconds.
    public static let frameLength: TimeInterval = 0.1

    /// Where to cut `samples` (which start `offset` seconds into the recording): the middle of the
    /// lowest-RMS frame. Ties go to the latest frame, which keeps windows long.
    public static func quietestPoint(in samples: [Float], offset: TimeInterval) -> TimeInterval {
        let rate = BatchAudio.sampleRate
        let frame = max(1, Int(frameLength * rate))
        var best = (energy: Double.infinity, start: 0)
        samples.withUnsafeBufferPointer { buf in
            var start = 0
            while start + frame <= buf.count {
                var sum = 0.0
                for i in start..<(start + frame) { sum += Double(buf[i]) * Double(buf[i]) }
                if sum <= best.energy { best = (sum, start) }
                start += frame
            }
        }
        guard best.energy.isFinite else { return offset + Double(samples.count) / rate }
        return offset + (Double(best.start) + Double(frame) / 2) / rate
    }

    /// The next window's end, starting at `start`: the recording's end when it fits, else the quietest
    /// point in the last ``searchSpan`` seconds before the limit.
    /// - Parameter window: the longest window; ``maxWindow`` in the app, shorter in tests so they scan less audio.
    public static func nextCut(
        from start: TimeInterval, duration: TimeInterval, stream: TranscriptEvent.Stream, reader: any AudioSampleReader,
        window: TimeInterval = maxWindow
    ) async throws -> TimeInterval {
        let limit = start + window
        guard limit < duration else { return duration }
        let from = limit - searchSpan
        let tail = try await reader.samples(of: stream, in: from..<limit)
        let cut = quietestPoint(in: tail, offset: from)
        return min(max(cut, start + 1), limit)
    }
}
