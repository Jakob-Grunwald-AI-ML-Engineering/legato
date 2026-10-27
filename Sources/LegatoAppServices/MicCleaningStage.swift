import Foundation
import LegatoCore
import Synchronization

/// Puts a ``MicEnhancer`` (LocalVQE) between the meeting's microphone and its session.
///
/// ``mic(_:)`` wraps the microphone source: what the session reads from it is the cleaned mic. ``reference(_:)``
/// wraps the system-audio source: the session still gets its audio unchanged, and a copy goes to the enhancer
/// as the echo reference (leave it out on the phone, which denoises only).
///
/// - The enhancer is fed from one task, in order, so its answers come back in order and a call that is
///   still in the model never meets another. Whatever it answers is passed on; at the stop the rest is flushed,
///   so the cleaned mic is as long as the mic.
/// - The mic and the reference are two streams that start at different moments. The mic starts first; the
///   first reference chunk is placed by how much later it began (silence in front of it), so both sides of
///   the enhancer line up in time. Until the reference starts, the enhancer hears the mic against silence.
/// - If the enhancer falls back to the raw mic (too slow, or failed), ``notices`` says so, once.
/// - Only 16 kHz mono can be cleaned. Any other format passes the mic through untouched, with a notice.
///
/// The session never knows: it reads an `AudioSource` like any other. Sources are not re-routed in a meeting
/// (`route()` and `detach()` go to the real source untouched).
public final class MicCleaningStage: Sendable {
    /// Things the user should hear about, e.g. that the raw microphone is in use now. Ends with the microphone.
    public let notices: AsyncStream<String>

    private static let format = AudioFormatSpec(sampleRate: 16_000, channelCount: 1)

    fileprivate enum Input: Sendable {
        case mic([Float])
        /// Reference audio; `startOffset` (samples after the mic began) is set on the first chunk.
        case reference([Float], startOffset: Int?)
        case micEnded
    }

    private struct State {
        var feed: AsyncStream<Input>.Continuation?
        var enabled = true
        var hasReference = false
        var micOrigin: TimeInterval?
        var referenceStarted = false
    }

    private let enhancer: any MicEnhancer
    private let clock: @Sendable () -> TimeInterval
    private let noticeSink: AsyncStream<String>.Continuation
    private let state = Mutex(State())

    /// - Parameter clock: seconds on any origin; the first mic chunk and the first reference chunk are placed by it.
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

    // MARK: Mic

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
                state.withLock { s in
                    if s.micOrigin == nil { s.micOrigin = clock() - Double(chunk.samples.count) / Self.format.sampleRate }
                }
                feed.yield(.mic(chunk.samples))
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

    private func work(_ inputs: AsyncStream<Input>, output: AsyncStream<AudioChunk>.Continuation, hasReference: Bool) async {
        var referencePosition = 0  // samples of reference the enhancer has been given, silence included
        var referenceStarted = false
        var reportedFallback = false
        func emit(_ samples: [Float]) {
            if !samples.isEmpty { output.yield(AudioChunk(samples: samples, format: Self.format)) }
        }
        for await input in inputs {
            switch input {
            case .mic(let samples):
                let reference: [Float]? = hasReference && referenceStarted ? [] : nil
                if reference == nil { referencePosition += samples.count }
                emit(await enhancer.enhance(mic: samples, reference: reference))
            case .reference(var samples, let startOffset):
                if !referenceStarted {
                    referenceStarted = true
                    let start = startOffset ?? referencePosition
                    if referencePosition < start {
                        samples.insert(contentsOf: [Float](repeating: 0, count: start - referencePosition), at: 0)
                    } else if referencePosition > start {
                        samples.removeFirst(min(samples.count, referencePosition - start))
                    }
                }
                referencePosition += samples.count
                if !samples.isEmpty { emit(await enhancer.enhance(mic: [], reference: samples)) }
            case .micEnded:
                emit(await enhancer.flush())
                output.finish()
                noticeSink.finish()
                return
            }
            if !reportedFallback, case .fellBack(let reason) = await enhancer.state() {
                reportedFallback = true
                noticeSink.yield(Self.notice(reason))
            }
        }
        output.finish()
        noticeSink.finish()
    }

    private static func notice(_ reason: MicEnhancerFallback) -> String {
        switch reason {
        case .lagging: "Echo and noise cancellation fell behind, so the raw microphone is used."
        case .failed: "Echo and noise cancellation stopped working, so the raw microphone is used."
        }
    }

    // MARK: Reference

    fileprivate func pushReference(_ chunk: AudioChunk, first: Bool) {
        let (feed, micOrigin, enabled) = state.withLock { ($0.feed, $0.micOrigin, $0.enabled) }
        guard enabled, let feed else { return }
        var offset: Int?
        if first {
            let origin = clock() - Double(chunk.samples.count) / Self.format.sampleRate
            offset = micOrigin.map { max(0, Int(((origin - $0) * Self.format.sampleRate).rounded())) } ?? 0
        }
        feed.yield(.reference(chunk.samples, startOffset: offset))
    }
}

// MARK: - Sources

private final class CleanedMic: ResumableAudioSource {
    let inner: any AudioSource
    let stage: MicCleaningStage

    init(inner: any AudioSource, stage: MicCleaningStage) {
        self.inner = inner
        self.stage = stage
    }

    var resumptions: AsyncStream<Void> {
        (inner as? any ResumableAudioSource)?.resumptions ?? AsyncStream { $0.finish() }
    }

    func start(format: AudioFormatSpec) async throws -> AsyncStream<AudioChunk> {
        stage.beginMic(try await inner.start(format: format), format: format)
    }

    func route() async throws -> AsyncStream<AudioChunk> { try await inner.route() }
    func detach() async { await inner.detach() }
    func stop() async { await inner.stop() }
}

private final class ReferenceTap: ResumableAudioSource {
    let inner: any AudioSource
    let stage: MicCleaningStage

    init(inner: any AudioSource, stage: MicCleaningStage) {
        self.inner = inner
        self.stage = stage
    }

    var resumptions: AsyncStream<Void> {
        (inner as? any ResumableAudioSource)?.resumptions ?? AsyncStream { $0.finish() }
    }

    func start(format: AudioFormatSpec) async throws -> AsyncStream<AudioChunk> {
        let chunks = try await inner.start(format: format)
        let (out, output) = AsyncStream<AudioChunk>.makeStream()
        let stage = self.stage
        let relay = Task {
            var first = true
            for await chunk in chunks {
                stage.pushReference(chunk, first: first)
                first = false
                output.yield(chunk)
            }
            output.finish()
        }
        output.onTermination = { _ in relay.cancel() }
        return out
    }

    func route() async throws -> AsyncStream<AudioChunk> { try await inner.route() }
    func detach() async { await inner.detach() }
    func stop() async { await inner.stop() }
}
