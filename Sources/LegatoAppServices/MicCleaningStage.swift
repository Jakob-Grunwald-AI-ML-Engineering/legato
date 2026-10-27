import Foundation
import LegatoCore
import Synchronization

/// Puts a ``MicEnhancer`` (LocalVQE) between the meeting's microphone and its session.
///
/// ``mic(_:)`` wraps the microphone source: what the session reads from it is the cleaned mic. ``reference(_:)``
/// wraps the system-audio source: the session still gets its audio unchanged, and a copy goes to the enhancer
/// as the echo reference (leave it out on the phone, which denoises only).
///
/// - **Ready first.** The enhancer's model is loaded (``MicEnhancer/prepare()``) before the mic starts, so no
///   audio queues up behind the load.
/// - The enhancer is fed from one task, in order, so its answers come back in order and a call that is
///   still in the model never meets another. Whatever it answers is passed on; at the stop the rest is flushed,
///   so the cleaned mic is as long as the mic.
/// - **One timeline.** Each chunk is placed by `clock` when it arrives: the mic's first sample is time zero, and
///   each source then counts its own samples. A source that comes back after a gap (it reports
///   ``ResumableAudioSource/resumptions``: a mic restart, a system-tap rebuild) is placed by the clock again,
///   so mic and reference stay lined up: a reference gap is silence for the enhancer, and the reference of a
///   time the mic was away is skipped. Until the reference starts the enhancer hears the mic against silence;
///   a reference that stalls for more than half a second is silence too, so the enhancer never waits on it.
///   The reference is given to the enhancer at most a quarter second ahead of the mic.
/// - **Falling behind.** If more than a second of mic audio waits for the enhancer, the stage stops feeding it:
///   what the enhancer holds is flushed and the raw mic passes from there on, with no gap and no repeat. The
///   queue is bounded that way: past the second, each chunk is passed on at the cost of a copy.
/// - If the enhancer falls back to the raw mic (too slow, or failed), ``notices`` says so, once.
/// - Only 16 kHz mono can be cleaned. Any other format passes the mic through untouched, with a notice.
///
/// The session never knows: it reads an `AudioSource` like any other. Sources are not re-routed in a meeting
/// (`route()` and `detach()` go to the real source untouched).
public final class MicCleaningStage: Sendable {
    /// Things the user should hear about, e.g. that the raw microphone is in use now. Ends with the microphone.
    public let notices: AsyncStream<String>

    private static let format = AudioFormatSpec(sampleRate: 16_000, channelCount: 1)
    private static let rate = 16_000.0
    /// Mic audio waiting for the enhancer beyond which it is bypassed: one second.
    static let queueLimit = 16_000
    /// How far the reference may run ahead of the mic into the enhancer: a quarter second.
    static let referenceLead = 4_000
    /// How far the reference may fall behind the mic before its absence counts as silence: half a second.
    static let referenceLag = 8_000
    /// Shorter differences between a source's own count and the clock are jitter, not a gap.
    private static let tolerance = Int(MeetingSilence.tolerance * rate)

    fileprivate enum Input: Sendable {
        /// Mic audio; `at` is where its first sample is on the timeline (samples since the mic began).
        case mic([Float], at: Int)
        /// Reference audio, placed the same way.
        case reference([Float], at: Int)
        case micEnded
    }

    private struct State {
        var feed: AsyncStream<Input>.Continuation?
        var enabled = true
        var hasReference = false
        /// The clock at the mic's first sample: the timeline's zero.
        var micOrigin: TimeInterval?
        /// Where each source's next sample goes on the timeline.
        var micNext = 0
        var referenceNext: Int?
        /// The source came back after a gap: its next chunk is placed by the clock.
        var micResumed = false
        var referenceResumed = false
        /// Mic samples handed to the worker and not yet taken.
        var queuedMic = 0
    }

    private let enhancer: any MicEnhancer
    private let clock: @Sendable () -> TimeInterval
    private let noticeSink: AsyncStream<String>.Continuation
    private let state = Mutex(State())

    /// - Parameter clock: seconds on any origin; chunks are placed by it when they arrive (see the type's notes).
    public init(enhancer: any MicEnhancer, clock: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.enhancer = enhancer
        self.clock = clock
        (notices, noticeSink) = AsyncStream.makeStream(of: String.self)
    }

    /// The microphone with its audio cleaned.
    public func mic(_ source: any AudioSource) -> any AudioSource { CleanedMic(inner: source, stage: self) }

    /// The system audio, unchanged for the session and copied to the enhancer as its echo reference.
    public func reference(_ source: any AudioSource) -> any AudioSource {
        state.withLock { $0.hasReference = true }
        return ReferenceTap(inner: source, stage: self)
    }

    // MARK: Timeline

    /// Where a chunk of `count` samples that arrived just now begins, by the clock.
    private func clockPosition(count: Int, origin: TimeInterval) -> Int {
        Int(((clock() - origin) * Self.rate).rounded()) - count
    }

    fileprivate func micResumed() { state.withLock { $0.micResumed = true } }
    fileprivate func referenceResumed() { state.withLock { $0.referenceResumed = true } }

    // MARK: Mic

    fileprivate func prepare() async { await enhancer.prepare() }

    fileprivate func beginMic(_ chunks: AsyncStream<AudioChunk>, format: AudioFormatSpec) -> AsyncStream<AudioChunk> {
        let (out, output) = AsyncStream<AudioChunk>.makeStream()
        guard format == Self.format else {
            state.withLock { $0.enabled = false }
            noticeSink.yield("The microphone is not cleaned in this audio format, so the raw microphone is used.")
            let relay = Task {
                for await chunk in chunks { output.yield(chunk) }
                output.finish()
                noticeSink.finish()
            }
            output.onTermination = { _ in relay.cancel() }
            return out
        }
        let (inputs, feed) = AsyncStream<Input>.makeStream()
        let hasReference = state.withLock { s -> Bool in
            s.feed = feed
            s.enabled = true
            return s.hasReference
        }
        let pump = Task {
            for await chunk in chunks {
                let count = chunk.samples.count
                let at = state.withLock { s -> Int in
                    if s.micOrigin == nil {
                        s.micOrigin = clock() - Double(count) / Self.rate
                    } else if s.micResumed, let origin = s.micOrigin {
                        s.micResumed = false
                        let byClock = clockPosition(count: count, origin: origin)
                        if byClock > s.micNext + Self.tolerance { s.micNext = byClock }
                    }
                    defer { s.micNext += count }
                    s.queuedMic += count
                    return s.micNext
                }
                feed.yield(.mic(chunk.samples, at: at))
            }
            feed.yield(.micEnded)
            feed.finish()
        }
        let worker = Task { await work(inputs, output: output, hasReference: hasReference) }
        output.onTermination = { _ in
            pump.cancel()
            worker.cancel()
        }
        return out
    }

    /// What the worker knows about where the enhancer stands.
    private struct Feed {
        /// Mic and reference samples given to the enhancer so far (silence included): sample `i` of each pairs.
        var micFed = 0
        var referenceFed = 0
        /// Timeline position of the enhancer's mic sample 0, as of the newest mic chunk: it grows by the time
        /// the mic was away.
        var offset = 0
        /// Reference not given yet: `held[0]` is at timeline position `heldAt`.
        var held: [Float] = []
        var heldAt = 0
        var referenceStarted = false
    }

    private func work(_ inputs: AsyncStream<Input>, output: AsyncStream<AudioChunk>.Continuation, hasReference: Bool) async {
        var feed = Feed()
        var bypassed = false
        var reportedFallback = false
        func emit(_ samples: [Float]) {
            if !samples.isEmpty { output.yield(AudioChunk(samples: samples, format: Self.format)) }
        }
        func notify(_ reason: MicEnhancerFallback) {
            guard !reportedFallback else { return }
            reportedFallback = true
            noticeSink.yield(Self.notice(reason))
        }
        for await input in inputs {
            switch input {
            case .mic(let samples, let at):
                let waiting = state.withLock { s -> Int in
                    s.queuedMic -= samples.count
                    return s.queuedMic
                }
                if bypassed {
                    emit(samples)
                    continue
                }
                if waiting > Self.queueLimit {
                    // More than a second waits behind this chunk: the enhancer cannot keep up.
                    bypassed = true
                    emit(await enhancer.flush())
                    emit(samples)
                    notify(.lagging)
                    continue
                }
                feed.offset = at - feed.micFed
                let reference: [Float]? = hasReference && feed.referenceStarted ? [] : nil
                if reference == nil { feed.referenceFed += samples.count }
                feed.micFed += samples.count
                emit(await enhancer.enhance(mic: samples, reference: reference))
                if feed.referenceStarted, let pending = Self.takeReference(&feed, limit: feed.micFed + Self.referenceLead, padStall: true) {
                    emit(await enhancer.enhance(mic: [], reference: pending))
                }
            case .reference(let samples, let at):
                guard !bypassed else { continue }
                Self.hold(samples, at: at, in: &feed)
                if let pending = Self.takeReference(&feed, limit: feed.micFed + Self.referenceLead, padStall: false) {
                    emit(await enhancer.enhance(mic: [], reference: pending))
                }
            case .micEnded:
                if !bypassed {
                    // The rest of the reference, so the enhancer has all it can pair before the flush.
                    if let pending = Self.takeReference(&feed, limit: .max, padStall: false) {
                        emit(await enhancer.enhance(mic: [], reference: pending))
                    }
                    emit(await enhancer.flush())
                }
                output.finish()
                noticeSink.finish()
                return
            }
            if !bypassed, case .fellBack(let reason) = await enhancer.state() { notify(reason) }
        }
        output.finish()
        noticeSink.finish()
    }

    /// Adds reference audio at timeline position `at` to what is held: a gap before it is silence, and what
    /// overlaps audio already held is dropped.
    private static func hold(_ samples: [Float], at: Int, in feed: inout Feed) {
        var samples = samples
        if !feed.referenceStarted {
            feed.referenceStarted = true
            feed.heldAt = at
        } else if feed.held.isEmpty, at > feed.heldAt {
            feed.heldAt = at
        }
        let end = feed.heldAt + feed.held.count
        if at > end {
            feed.held += [Float](repeating: 0, count: at - end)
        } else if at < end {
            samples.removeFirst(min(samples.count, end - at))
        }
        feed.held += samples
    }

    /// The reference to give the enhancer now, lined up with its mic: held audio placed by its timeline
    /// position, silence where there is none, up to `limit` (an enhancer sample index). Held audio for a time
    /// the enhancer has already passed is dropped. With `padStall`, a reference more than ``referenceLag``
    /// behind the mic is padded with silence up to that lag. Nil when there is nothing to give.
    private static func takeReference(_ feed: inout Feed, limit: Int, padStall: Bool) -> [Float]? {
        var out: [Float] = []
        while feed.referenceFed < limit, !feed.held.isEmpty {
            let index = feed.heldAt - feed.offset  // where the first held sample pairs, in the enhancer
            if index < feed.referenceFed {
                let drop = min(feed.referenceFed - index, feed.held.count)
                feed.held.removeFirst(drop)
                feed.heldAt += drop
            } else if index > feed.referenceFed {
                let pad = min(index - feed.referenceFed, limit - feed.referenceFed)
                out += [Float](repeating: 0, count: pad)
                feed.referenceFed += pad
            } else {
                let take = min(feed.held.count, limit - feed.referenceFed)
                out += feed.held.prefix(take)
                feed.held.removeFirst(take)
                feed.heldAt += take
                feed.referenceFed += take
            }
        }
        if padStall, feed.micFed - feed.referenceFed > referenceLag {
            let pad = feed.micFed - referenceLag - feed.referenceFed
            out += [Float](repeating: 0, count: pad)
            feed.referenceFed += pad
        }
        return out.isEmpty ? nil : out
    }

    private static func notice(_ reason: MicEnhancerFallback) -> String {
        switch reason {
        case .lagging: "Echo and noise cancellation fell behind, so the raw microphone is used."
        case .failed: "Echo and noise cancellation stopped working, so the raw microphone is used."
        }
    }

    // MARK: Reference

    fileprivate func pushReference(_ chunk: AudioChunk) {
        let count = chunk.samples.count
        let placed = state.withLock { s -> (AsyncStream<Input>.Continuation, Int)? in
            guard s.enabled, let feed = s.feed else { return nil }
            var at = s.referenceNext ?? 0
            if s.referenceNext == nil || s.referenceResumed {
                s.referenceResumed = false
                let byClock = s.micOrigin.map { max(0, clockPosition(count: count, origin: $0)) } ?? 0
                if s.referenceNext == nil || byClock > at + Self.tolerance { at = byClock }
            }
            s.referenceNext = at + count
            return (feed, at)
        }
        guard let (feed, at) = placed else { return }
        feed.yield(.reference(chunk.samples, at: at))
    }
}

// MARK: - Sources

/// Passes a source's resumptions on to the session and tells the stage first, so the stage places the next
/// chunk by the clock.
private final class ResumptionRelay: Sendable {
    let stream: AsyncStream<Void>
    private let sink: AsyncStream<Void>.Continuation
    private let task = Mutex<Task<Void, Never>?>(nil)

    init() { (stream, sink) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1)) }

    func start(from source: any AudioSource, onResume: @escaping @Sendable () -> Void) {
        guard let resumable = source as? any ResumableAudioSource else { return sink.finish() }
        let inner = resumable.resumptions
        let sink = self.sink
        task.withLock {
            $0?.cancel()
            $0 = Task {
                for await _ in inner {
                    onResume()
                    sink.yield()
                }
                sink.finish()
            }
        }
    }

    func stop() {
        task.withLock { $0?.cancel() }
        sink.finish()
    }
}

private final class CleanedMic: ResumableAudioSource {
    let inner: any AudioSource
    let stage: MicCleaningStage
    private let relay = ResumptionRelay()

    init(inner: any AudioSource, stage: MicCleaningStage) {
        self.inner = inner
        self.stage = stage
    }

    var resumptions: AsyncStream<Void> { relay.stream }

    func start(format: AudioFormatSpec) async throws -> AsyncStream<AudioChunk> {
        await stage.prepare()  // the model is ready before the first sample
        let chunks = try await inner.start(format: format)
        let stage = self.stage
        relay.start(from: inner) { stage.micResumed() }
        return stage.beginMic(chunks, format: format)
    }

    func route() async throws -> AsyncStream<AudioChunk> { try await inner.route() }
    func detach() async { await inner.detach() }
    func stop() async {
        await inner.stop()
        relay.stop()
    }
}

private final class ReferenceTap: ResumableAudioSource {
    let inner: any AudioSource
    let stage: MicCleaningStage
    private let relay = ResumptionRelay()

    init(inner: any AudioSource, stage: MicCleaningStage) {
        self.inner = inner
        self.stage = stage
    }

    var resumptions: AsyncStream<Void> { relay.stream }

    func start(format: AudioFormatSpec) async throws -> AsyncStream<AudioChunk> {
        let chunks = try await inner.start(format: format)
        let (out, output) = AsyncStream<AudioChunk>.makeStream()
        let stage = self.stage
        relay.start(from: inner) { stage.referenceResumed() }
        let copy = Task {
            for await chunk in chunks {
                stage.pushReference(chunk)
                output.yield(chunk)
            }
            output.finish()
        }
        output.onTermination = { _ in copy.cancel() }
        return out
    }

    func route() async throws -> AsyncStream<AudioChunk> { try await inner.route() }
    func detach() async { await inner.detach() }
    func stop() async {
        await inner.stop()
        relay.stop()
    }
}
