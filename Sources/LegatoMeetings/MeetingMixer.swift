import Foundation
import LegatoCore

/// Sums the audio of a meeting's sources into the one signal the live engine hears.
///
/// Pure and clock-driven: the caller feeds what each source delivered, stamped with the time it arrived
/// (``append(_:from:at:)``), and asks for the mix up to a point in time (``advance(to:)``), which cuts it into
/// frames of 100 ms. The mixer never waits: a frame takes whatever each source has delivered for it, and a
/// source that is late, missing or rebuilding is silence for that frame (audio that turns up after its frame
/// went out is dropped). Each chunk is placed on the meeting's timeline by its arrival time, so a source that
/// starts late or comes back after a gap lines up with the others; small jitter is absorbed by treating
/// consecutive chunks as contiguous.
///
/// - Mute and pause are applied to a source's samples before they are summed, by time: a frame is silent for
///   a source if that source was muted (or the meeting paused) at **any** instant of the frame, and audio that
///   belongs to a silenced frame is dropped, never played later. Both are timed with the `at:` the caller
///   gives, so a mute takes effect at the moment it was pressed even though the caller runs the mix behind
///   the clock to let late chunks arrive.
/// - The sum is scaled down just enough to stay within ±1 when it would clip, frame by frame; quiet mixes
///   are never touched.
/// - A source may hold at most ``maxBacklog`` seconds of audio not yet mixed; beyond that its oldest is dropped.
/// - The mix is exactly as long as the meeting: ``flush(to:)`` adds the last partial frame.
public struct MeetingMixer: Sendable {
    /// Length of a frame.
    public static let frameSeconds: TimeInterval = 0.1

    public let sampleRate: Double
    /// Samples per frame.
    public let frameSamples: Int
    /// How much unmixed audio a source may hold, in seconds.
    public let maxBacklog: TimeInterval
    /// How many samples of the mix have been handed out so far.
    public private(set) var emittedSamples = 0

    /// One source's audio on the meeting's timeline: `samples[i]` belongs at sample `base + i`.
    private struct Track {
        var base = 0
        var samples: [Float] = []
        /// Where the next contiguous chunk starts.
        var end = 0
    }

    private var tracks: [TranscriptEvent.Stream: Track] = [:]
    private var mutes: [TranscriptEvent.Stream: [Hold]] = [:]
    private var pauses: [Hold] = []

    private struct Hold {
        var start: TimeInterval
        var end: TimeInterval?

        func touches(_ lower: TimeInterval, _ upper: TimeInterval) -> Bool {
            start < upper && (end.map { $0 > lower } ?? true)
        }
    }

    public init(sampleRate: Double = 16_000, maxBacklog: TimeInterval = 1) {
        self.sampleRate = sampleRate
        self.frameSamples = max(1, Int((sampleRate * Self.frameSeconds).rounded()))
        self.maxBacklog = maxBacklog
    }

    /// Queues what `source` delivered (mono, in the mixer's sample rate) when it arrived at `time`, seconds on
    /// the meeting's timeline. The chunk is taken to end at `time`; if it starts within
    /// ``MeetingSilence/tolerance`` of where the source's last chunk ended it continues that chunk, and
    /// otherwise the gap before it stays silent.
    public mutating func append(_ samples: [Float], from source: TranscriptEvent.Stream, at time: TimeInterval) {
        guard !samples.isEmpty else { return }
        var track = tracks[source] ?? Track()
        let tolerance = Int(MeetingSilence.tolerance * sampleRate)
        let stamped = max(0, Int((time * sampleRate).rounded()) - samples.count)
        let start = stamped > track.end + tolerance ? stamped : track.end
        if track.samples.isEmpty {
            track.base = start
        } else if start > track.base + track.samples.count {
            track.samples += [Float](repeating: 0, count: start - (track.base + track.samples.count))
        }
        track.samples += samples
        track.end = start + samples.count
        let cap = Int(maxBacklog * sampleRate)
        if track.samples.count > cap {
            track.base += track.samples.count - cap
            track.samples.removeFirst(track.samples.count - cap)
        }
        tracks[source] = track
    }

    /// `source` is silenced from `time` on (seconds on the meeting's timeline).
    public mutating func mute(_ source: TranscriptEvent.Stream, at time: TimeInterval) {
        if let last = mutes[source]?.last, last.end == nil { return }  // already muted
        mutes[source, default: []].append(Hold(start: time, end: nil))
    }

    public mutating func unmute(_ source: TranscriptEvent.Stream, at time: TimeInterval) {
        guard var holds = mutes[source], let last = holds.indices.last, holds[last].end == nil else { return }
        holds[last].end = time
        mutes[source] = holds
    }

    /// Every source is silenced from `time` on.
    public mutating func pause(at time: TimeInterval) {
        if let last = pauses.last, last.end == nil { return }  // already paused
        pauses.append(Hold(start: time, end: nil))
    }

    public mutating func resume(at time: TimeInterval) {
        guard let last = pauses.indices.last, pauses[last].end == nil else { return }
        pauses[last].end = time
    }

    /// The whole frames of the mix up to `time`; a frame is handed out only once, and only when it is complete.
    public mutating func advance(to time: TimeInterval) -> [[Float]] {
        let frames = Int((time / Self.frameSeconds + 1e-9).rounded(.down)) - emittedSamples / frameSamples
        guard frames > 0 else { return [] }
        return emit(samples: frames * frameSamples)
    }

    /// Everything up to `time`, the last partial frame included: after this the mix is exactly `time` long.
    public mutating func flush(to time: TimeInterval) -> [[Float]] {
        let missing = Int((time * sampleRate).rounded()) - emittedSamples
        guard missing > 0 else { return [] }
        return emit(samples: missing)
    }

    private mutating func emit(samples count: Int) -> [[Float]] {
        var frames: [[Float]] = []
        var left = count
        while left > 0 {
            let n = min(frameSamples, left)
            let lower = Double(emittedSamples) / sampleRate
            let upper = Double(emittedSamples + n) / sampleRate
            frames.append(mixFrame(count: n, lower: lower, upper: upper))
            emittedSamples += n
            left -= n
        }
        prune(before: Double(emittedSamples) / sampleRate)
        return frames
    }

    private mutating func mixFrame(count n: Int, lower: TimeInterval, upper: TimeInterval) -> [Float] {
        var frame = [Float](repeating: 0, count: n)
        let first = emittedSamples
        let paused = pauses.contains { $0.touches(lower, upper) }
        for source in tracks.keys.sorted(by: { $0.rawValue < $1.rawValue }) {
            guard var track = tracks[source] else { continue }
            // Audio for frames that already went out is too late.
            if track.base < first {
                let stale = min(first - track.base, track.samples.count)
                track.samples.removeFirst(stale)
                track.base = first
            }
            if !track.samples.isEmpty, track.base < first + n {
                let count = min(first + n - track.base, track.samples.count)
                let silenced = paused || (mutes[source] ?? []).contains { $0.touches(lower, upper) }
                if !silenced {
                    let offset = track.base - first
                    for i in 0..<count { frame[offset + i] += track.samples[i] }
                }
                track.samples.removeFirst(count)
                track.base += count
            }
            tracks[source] = track
        }
        let peak = frame.reduce(Float(0)) { max($0, abs($1)) }
        if peak > 1 {
            let scale = 1 / peak
            for i in frame.indices { frame[i] *= scale }
        }
        return frame
    }

    /// Forgets holds that ended before `time`.
    private mutating func prune(before time: TimeInterval) {
        pauses.removeAll { ($0.end ?? .infinity) <= time }
        for source in mutes.keys { mutes[source]?.removeAll { ($0.end ?? .infinity) <= time } }
    }
}
