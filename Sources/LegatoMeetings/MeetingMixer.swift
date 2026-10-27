import Foundation
import LegatoCore

/// Sums the audio of a meeting's sources into the one signal the live engine hears.
///
/// Pure and clock-driven: the caller feeds what each source delivered (``append(_:from:at:)``) and asks for the
/// mix up to a point in time (``advance(to:)``), which cuts it into frames of 100 ms. The mixer never waits: a
/// frame takes whatever each source has delivered for it, and a source that is late, missing or rebuilding is
/// silence for that frame (audio that turns up after its frame went out is dropped).
///
/// - **Placement by count.** A source starts where ``begin(_:at:)`` puts it (its start on the meeting's
///   timeline) and then counts its own samples: chunk after chunk follows on, however late or bunched up they
///   arrive. A backlog delivered at once (audio queued while another source started, or behind a model load)
///   so lands where it was heard, not where it arrived. Gaps are told, not guessed: ``skip(_:until:)`` (the
///   session calls it when a source resumes after a restart) and ``skip(_:seconds:)`` leave silence. A source
///   nobody began is placed by its first chunk's arrival.
/// - **The clock keeps the count honest.** The arrival time (`at:`) only corrects a count that has gone wrong:
///   a source cannot deliver audio before it was heard, so a chunk that would end more than ``maxLead`` after
///   its arrival is pulled back to end there (newer audio replaces what it overlaps).
/// - **Nothing is lost to lateness.** A chunk whose count puts it behind what the mix already handed out (a
///   device clock slower than the host's, a restart or other time the source lost without saying) is placed by
///   the clock again at once: it ends where it arrived, never before the first sample not yet handed out, and
///   the source counts on from there. The frames that already went out had silence for it, and none of its
///   audio is cut; a slow drift so costs a short silence now and then, never a run of clipped chunks. Only audio
///   that arrives after its frame went out *and* could not have been heard that late (it would end more than
///   ``maxLead`` after its arrival) is dropped.
/// - Mute and pause are applied to a source's samples before they are summed, by time: a frame is silent for
///   a source if that source was muted (or the meeting paused) at **any** instant of the frame, and audio that
///   belongs to a silenced frame is dropped, never played later. Both are timed with the `at:` the caller
///   gives, so a mute takes effect at the moment it was pressed even though the caller runs the mix behind
///   the clock to let late chunks arrive.
/// - The sum is scaled down just enough to stay within ±1 when it would clip, frame by frame; quiet mixes
///   are never touched.
/// - The mix is exactly as long as the meeting: ``flush(to:)`` adds the last partial frame.
public struct MeetingMixer: Sendable {
    /// Length of a frame.
    public static let frameSeconds: TimeInterval = 0.1

    public let sampleRate: Double
    /// Samples per frame.
    public let frameSamples: Int
    /// How far a source's count may run ahead of the clock, in seconds.
    public let maxLead: TimeInterval
    /// How many samples of the mix have been handed out so far.
    public private(set) var emittedSamples = 0

    /// One source's audio on the meeting's timeline: `samples[i]` belongs at sample `base + i`.
    private struct Track {
        var base = 0
        var samples: [Float] = []
        /// Where the source's next sample goes, by its own count.
        var end = 0
        /// The source has a place on the timeline (``begin(_:at:)`` or its first chunk).
        var placed = false
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

    public init(sampleRate: Double = 16_000, maxLead: TimeInterval = 0.5) {
        self.sampleRate = sampleRate
        self.frameSamples = max(1, Int((sampleRate * Self.frameSeconds).rounded()))
        self.maxLead = maxLead
    }

    /// `source`'s first sample is at `time`, seconds on the meeting's timeline.
    public mutating func begin(_ source: TranscriptEvent.Stream, at time: TimeInterval) {
        var track = Track()
        track.end = max(0, Int((time * sampleRate).rounded()))
        track.placed = true
        tracks[source] = track
    }

    /// `source` delivered nothing for `seconds` (it says so, e.g. it resumed after a restart): that stretch is
    /// silence and its next sample comes after it.
    public mutating func skip(_ source: TranscriptEvent.Stream, seconds: TimeInterval) {
        guard seconds > 0, var track = tracks[source] else { return }
        track.end += Int((seconds * sampleRate).rounded())
        tracks[source] = track
    }

    /// `source` delivered nothing before `time` (seconds on the meeting's timeline; it restarted and is back
    /// now): its next sample comes no earlier than `time`, however short the gap.
    public mutating func skip(_ source: TranscriptEvent.Stream, until time: TimeInterval) {
        guard var track = tracks[source] else { return }
        track.end = max(track.end, Int((time * sampleRate).rounded()))
        tracks[source] = track
    }

    /// Queues what `source` delivered (mono, in the mixer's sample rate); it arrived at `time`, seconds on the
    /// meeting's timeline. It follows on from the source's previous audio (see the type's notes).
    public mutating func append(_ samples: [Float], from source: TranscriptEvent.Stream, at time: TimeInterval) {
        guard !samples.isEmpty else { return }
        var track = tracks[source] ?? Track()
        let count = samples.count
        let arrival = Int((time * sampleRate).rounded())
        if !track.placed {
            track.end = max(0, arrival - count)
            track.placed = true
        }
        var start = track.end
        if start < emittedSamples {
            start = max(emittedSamples, arrival - count)  // fallen behind the mix: placed by the clock, nothing cut
        }
        if start + count > arrival + Int(maxLead * sampleRate) {
            start = arrival - count  // heard no later than it arrived
        }
        let queuedEnd = track.base + track.samples.count
        if track.samples.isEmpty {
            track.base = start
        } else if start >= queuedEnd {
            track.samples += [Float](repeating: 0, count: start - queuedEnd)
        } else if start <= track.base {
            track.samples = []
            track.base = start
        } else {
            track.samples.removeLast(queuedEnd - start)  // newer audio replaces what it overlaps
        }
        track.samples += samples
        track.end = start + count
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
